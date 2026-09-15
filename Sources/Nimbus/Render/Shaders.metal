#include <metal_stdlib>
using namespace metal;

// Layout must match Uniforms.swift byte for byte. Only 16-byte-aligned vectors
// are stored; loose scalars are packed into params0/params1.
struct Uniforms {
    float2 resolution;    //  0
    float2 _pad0;         //  8  .x carries the debug mode (0 = off)
    float4 windowRect;    // 16  x, y, w, h in pixels, bottom-left origin
    float4 colorA;        // 32  linear RGB in .xyz
    float4 colorB;        // 48
    float4 colorGlow;     // 64
    float4 params0;       // 80  cornerRadius, bandInner, bandOuter, flowPhase
    float4 params1;       // 96  intensity, warpPhase, noiseScale, glowFalloff
};                        // 112

struct VertexOut {
    float4 position [[position]];
    float2 pixel;   // our own pixel space: bottom-left origin, matching AppKit
};

// ---------------------------------------------------------------------------
// Vertex: generate the band as four quads rather than one full-viewport quad.
//
// The spec (§8.1) starts with a full quad and defers this. On integrated
// graphics the interior of a large window is most of the fragments and all of
// them would be shaded and blended only to come out transparent, so the frame
// shape is built up front. Four rects (top, bottom, left, right) tile the band
// with no overlap and no seam.
// ---------------------------------------------------------------------------

vertex VertexOut ring_vertex(uint vid [[vertex_id]],
                             constant Uniforms &u [[buffer(0)]]) {
    // Debug mode 2: one full-viewport quad, to test the window and its
    // compositing in isolation from any of the ring geometry.
    if (u._pad0.x >= 2.0) {
        const float2 dbg[6] = {
            float2(0, 0), float2(1, 0), float2(0, 1),
            float2(0, 1), float2(1, 0), float2(1, 1)
        };
        const float2 o = dbg[min(vid, 5u)];
        VertexOut out;
        out.position = float4(o.x * 2.0 - 1.0, o.y * 2.0 - 1.0, 0.0, 1.0);
        out.pixel = o * u.resolution;
        // Collapse the remaining vertices so they rasterize nothing.
        if (vid >= 6u) { out.position = float4(0.0, 0.0, 0.0, 1.0); }
        return out;
    }

    const float bandInner   = u.params0.y;
    const float bandOuter   = u.params0.z;
    const float glowFalloff = u.params1.w;

    // Past ~5 falloff lengths the bloom is under 1% and invisible; beyond that
    // we would be shading pixels that contribute nothing. The 1.5x allows for
    // the band's outer edge moving outward (the flame tongues) without the
    // strip clipping them into a straight line.
    const float outerExtent = bandOuter * 1.5 + glowFalloff * 5.0;

    const float2 wpos  = u.windowRect.xy;
    const float2 wsize = u.windowRect.zw;

    // Outer bounds, clipped to the drawable.
    float ox0 = max(wpos.x - outerExtent, 0.0);
    float oy0 = max(wpos.y - outerExtent, 0.0);
    float ox1 = min(wpos.x + wsize.x + outerExtent, u.resolution.x);
    float oy1 = min(wpos.y + wsize.y + outerExtent, u.resolution.y);

    // Inner bounds: everything strictly inside this is fully transparent.
    // Band widths are clamped host-side to min(w,h)/4, so this cannot invert.
    float ix0 = clamp(wpos.x + bandInner,           ox0, ox1);
    float iy0 = clamp(wpos.y + bandInner,           oy0, oy1);
    float ix1 = clamp(wpos.x + wsize.x - bandInner, ox0, ox1);
    float iy1 = clamp(wpos.y + wsize.y - bandInner, oy0, oy1);

    const uint quad   = vid / 6u;
    const uint corner = vid % 6u;

    // Two triangles per quad as a triangle list.
    const float2 offsets[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };

    float2 lo, hi;
    if (quad == 0u) {          // top strip, full width
        lo = float2(ox0, iy1); hi = float2(ox1, oy1);
    } else if (quad == 1u) {   // bottom strip, full width
        lo = float2(ox0, oy0); hi = float2(ox1, iy0);
    } else if (quad == 2u) {   // left strip, between the two
        lo = float2(ox0, iy0); hi = float2(ix0, iy1);
    } else {                   // right strip
        lo = float2(ix1, iy0); hi = float2(ox1, iy1);
    }

    const float2 o = offsets[corner];
    const float2 pixel = mix(lo, hi, o);

    VertexOut out;
    // Bottom-left-origin pixels to Metal NDC, which has y up.
    out.position = float4(pixel.x / u.resolution.x * 2.0 - 1.0,
                          pixel.y / u.resolution.y * 2.0 - 1.0,
                          0.0, 1.0);
    out.pixel = pixel;
    return out;
}

// ---------------------------------------------------------------------------
// Noise
// ---------------------------------------------------------------------------

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);          // smoothstep interpolation
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

/// fBm normalized to roughly 0…1. Octaves are per-call: the turbulence layers
/// only need two, and paying for three everywhere is wasted on an iGPU.
static inline float fbm(float2 p, int octaves) {
    float sum = 0.0;
    float amp = 0.5;
    float norm = 0.0;
    for (int i = 0; i < octaves; ++i) {
        sum += amp * valueNoise(p);
        norm += amp;
        p *= 2.0;
        amp *= 0.5;
    }
    return sum / max(norm, 1e-5);
}

// Signed distance to a rounded rectangle. Negative inside the window.
static inline float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// ---------------------------------------------------------------------------
// Fragment
// ---------------------------------------------------------------------------

fragment float4 ring_fragment(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]]) {
    // Debug mode 1+: paint every rasterized fragment opaque blue. Combined with
    // mode 2 this separates "the window is not compositing" from "the ring
    // geometry or shading produces nothing". Blue against the yellow control
    // stroke — never red against green.
    if (u._pad0.x >= 1.0) {
        return float4(0.0, 0.35, 1.0, 1.0);
    }

    const float cornerRadius = u.params0.x;
    const float bandInner    = u.params0.y;
    const float bandOuter    = u.params0.z;
    // Phases, not times. The host integrates speed over elapsed time and sends
    // the accumulated angle, because multiplying an absolute timestamp by a
    // *changing* speed makes the phase leap by hundreds of radians the moment
    // the speed changes — which is what a flare does. Integrating keeps the
    // motion continuous through every speed change.
    const float flowPhase    = u.params0.w;
    const float intensity    = u.params1.x;
    const float warpPhase    = u.params1.y;
    const float noiseScale   = u.params1.z;
    const float glowFalloff  = u.params1.w;

    const float2 halfSize = u.windowRect.zw * 0.5;
    const float2 center = u.windowRect.xy + halfSize;
    const float2 p = in.pixel - center;

    const float d = sdRoundBox(p, halfSize,
                               min(cornerRadius, min(halfSize.x, halfSize.y)));

    // Reject before touching any noise. Everything below costs real ALU.
    if (d > bandOuter * 1.5 + glowFalloff * 5.0 || d < -bandInner * 1.5) {
        discard_fragment();
    }

    // Position around the perimeter. Dividing by the half-extents before
    // finding the direction maps the rectangle onto a circle, so the motion
    // travels at an even rate on a wide window instead of bunching up at the
    // short edges. One extra divide, and it is the difference between a
    // 1920x200 terminal looking right and looking lopsided.
    const float2 scaled = float2(p.x / max(halfSize.x, 1.0), p.y / max(halfSize.y, 1.0));

    // Sampling on a unit circle rather than on a 0…1 coordinate means the noise
    // has no seam where the perimeter wraps. Every term below is either a
    // function of this point or constant in theta, so seamlessness survives.
    // atan2 followed immediately by cos/sin of its own result does nothing but
    // recover the input's unit direction — three transcendental calls to get
    // back what normalize() gets in one, which matters on an iGPU. `d` was
    // already checked above to rule out `scaled` landing exactly on zero.
    const float2 ring = scaled / max(length(scaled), 1e-6);

    // Domain warping: noise used to displace the lookup of more noise. This is
    // what separates fire from a moving highlight — it produces curling,
    // folding structure instead of a rigid pattern sliding past. Drifting the
    // warp on its own clock also means the ring keeps changing everywhere at
    // once, not only where the rotation currently is.
    const float2 q = ring * noiseScale + float2(0.0, warpPhase);
    const float2 warp = float2(fbm(q, 2), fbm(q + float2(5.2, 1.3), 2));

    // Large, slow tongues traveling one way...
    const float tongues = fbm(ring * noiseScale * 1.5
                              + warp * 1.15
                              + float2(flowPhase, -flowPhase * 0.55), 3);
    // ...and finer, faster detail traveling the other, so the eye never
    // resolves it into a single repeating loop.
    const float detail = fbm(ring * noiseScale * 3.5
                             - float2(flowPhase * 1.6, warpPhase * 1.65), 2);

    float n = saturate(0.68 * tongues + 0.42 * detail);
    // Widen the dynamic range. Without this the whole ring sits in a narrow
    // band of brightness and reads as static.
    n = smoothstep(0.12, 0.88, n);

    // The band's outer edge and the bloom's reach both move with the noise.
    // A ring whose *shape* changes reads as alive; one whose brightness alone
    // changes reads as a light with a fault.
    const float outerLocal = bandOuter * (0.45 + 1.05 * n);
    const float glowLocal  = glowFalloff * (0.55 + 0.85 * n);

    // A soft strip straddling the window edge. Both edges are feathered by at
    // least 1.5px (enforced host-side) so there is no aliasing on the ring.
    const float band = smoothstep(outerLocal, 0.0, d) * smoothstep(-bandInner, 0.0, d);
    const float glow = exp(-max(d, 0.0) / max(glowLocal, 0.5));

    if (band <= 0.0005 && glow <= 0.0025) {
        discard_fragment();
    }

    // 0 at the inner edge of the band, 1 at the outer: lets the color cool as
    // it reaches away from the window, the way a flame does.
    const float across = saturate((d + bandInner) / max(bandInner + outerLocal, 1.0));

    const float3 core = mix(u.colorB.rgb, u.colorA.rgb, n);
    const float3 bandColour = mix(core, u.colorGlow.rgb, across * 0.55);

    // Keep a floor under the band so the ring is never fully dark anywhere
    // along its length — dark gaps read as a broken ring rather than as motion.
    const float bandAlpha = band * (0.30 + 0.70 * n);
    const float glowAlpha = glow * 0.32;

    const float alpha = saturate((bandAlpha + glowAlpha) * intensity);

    // Premultiplied output, matching the pipeline's blend state. Letting the
    // color exceed the alpha makes the bloom read as light being added rather
    // than as a gray film over whatever is behind it.
    const float3 premultiplied = bandColour * (bandAlpha * intensity)
                               + u.colorGlow.rgb * (glowAlpha * intensity);

    return float4(premultiplied, alpha);
}
