import simd

/// The GPU-side constant block. **This layout must match `Shaders.metal` byte
/// for byte.**
///
/// Swift and Metal agree on `float4` alignment but drift on structs that
/// interleave loose scalars between vectors, and a mismatch produces a garbled
/// ring with no compile error anywhere — the single nastiest bug available in
/// this codebase. The defence is to store *only* 16-byte-aligned vectors (plus
/// one explicitly padded `float2`) and pack the scalars into them, exposing
/// readable names as computed properties. `stride` is asserted at startup.
public struct Uniforms {

    public var resolution: SIMD2<Float>   // offset  0 — drawable size in pixels
    public var pad0: SIMD2<Float>         // offset  8 — .x carries debugMode
    public var windowRect: SIMD4<Float>   // offset 16 — x, y, w, h in pixels
    public var colorA: SIMD4<Float>       // offset 32 — linear RGB in .xyz
    public var colorB: SIMD4<Float>       // offset 48
    public var colorGlow: SIMD4<Float>    // offset 64
    public var params0: SIMD4<Float>      // offset 80 — cornerRadius, bandInner, bandOuter, flowPhase
    public var params1: SIMD4<Float>      // offset 96 — intensity, warpPhase, noiseScale, glowFalloff

    /// Checked against `MemoryLayout<Uniforms>.stride` at renderer startup.
    public static let expectedStride = 112

    public init() {
        resolution = .zero
        pad0 = .zero
        windowRect = .zero
        colorA = .zero
        colorB = .zero
        colorGlow = .zero
        params0 = .zero
        params1 = .zero
    }

    /// 0 = normal. 1 = paint rasterized fragments red. 2 = also replace the ring
    /// geometry with a full-viewport quad. A diagnostic, not a feature.
    public var debugMode: Float {
        get { pad0.x } set { pad0.x = newValue }
    }

    // MARK: - Readable accessors over the packed scalars

    public var cornerRadius: Float {
        get { params0.x } set { params0.x = newValue }
    }
    /// How far the band reaches inside the window edge, in pixels.
    public var bandInner: Float {
        get { params0.y } set { params0.y = newValue }
    }
    /// How far it reaches outside, in pixels.
    public var bandOuter: Float {
        get { params0.z } set { params0.z = newValue }
    }
    /// Accumulated angle the noise has traveled around the ring, in radians.
    /// A phase rather than a timestamp: speed changes (the flare) must not move
    /// the pattern, only change how fast it advances from here.
    public var flowPhase: Float {
        get { params0.w } set { params0.w = newValue }
    }
    /// 0…1, from the animator.
    public var intensity: Float {
        get { params1.x } set { params1.x = newValue }
    }
    /// The turbulence's own accumulated phase, on a slower clock than the flow.
    public var warpPhase: Float {
        get { params1.y } set { params1.y = newValue }
    }
    public var noiseScale: Float {
        get { params1.z } set { params1.z = newValue }
    }
    /// Pixel falloff of the outer bloom.
    public var glowFalloff: Float {
        get { params1.w } set { params1.w = newValue }
    }
}
