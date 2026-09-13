// A WebGL port of Nimbus's Metal shader, close enough to show what the app
// looks like without installing it. Not pixel-exact with the real renderer:
// this is a demo, and keeping two shaders byte-identical would cost more than
// the accuracy is worth.

const VERT = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`;

const FRAG = `
precision highp float;

uniform vec2  uResolution;
uniform vec4  uWindowA;      // x, y, w, h  (px, y up)
uniform vec4  uWindowB;
uniform float uFocus;        // 0 = A focused, 1 = B focused
uniform float uCornerRadius;
uniform float uBandInner;
uniform float uBandOuter;
uniform float uFlowPhase;    // integrated, never time * speed
uniform float uWarpPhase;
uniform float uIntensity;
uniform float uNoiseScale;
uniform float uGlowFalloff;
uniform vec3  uColorA;
uniform vec3  uColorB;
uniform vec3  uColorGlow;

float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float valueNoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 w = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Fixed octave counts rather than a loop bound, so this compiles on WebGL 1
// where loop bounds must be constant.
float fbm2(vec2 p) {
    return (0.5 * valueNoise(p) + 0.25 * valueNoise(p * 2.0)) / 0.75;
}
float fbm3(vec2 p) {
    return (0.5 * valueNoise(p) + 0.25 * valueNoise(p * 2.0)
          + 0.125 * valueNoise(p * 4.0)) / 0.875;
}

// The desktop behind the windows: a plain dark ground so the ring reads as
// emitted light.
vec3 desktop(vec2 uv) {
    float v = 1.0 - 0.55 * length(uv - vec2(0.5, 0.55));
    return mix(vec3(0.055, 0.062, 0.090), vec3(0.086, 0.094, 0.133), v);
}

// A window: body, title bar, traffic lights.
vec4 windowLayer(vec2 p, vec4 rect, float focused) {
    vec2 halfSize = rect.zw * 0.5;
    vec2 c = rect.xy + halfSize;
    float d = sdRoundBox(p - c, halfSize, uCornerRadius);
    if (d > 1.0) return vec4(0.0);

    float inside = 1.0 - smoothstep(-1.0, 1.0, d);

    float barH = rect.w * 0.10;
    float inBar = step(rect.y + rect.w - barH, p.y) * step(p.y, rect.y + rect.w);
    vec3 body = mix(vec3(0.043, 0.051, 0.078), vec3(0.094, 0.102, 0.133), inBar);

    // Unfocused windows sit back a little, the way macOS dims them — which is
    // the very cue that is too subtle to rely on, and the reason this app exists.
    body *= mix(0.82, 1.0, focused);

    for (int i = 0; i < 3; i++) {
        vec2 dotp = vec2(rect.x + barH * (0.9 + float(i) * 0.85),
                         rect.y + rect.w - barH * 0.5);
        float dd = length(p - dotp) - barH * 0.16;
        body = mix(body, vec3(0.45), (1.0 - smoothstep(-0.6, 0.6, dd)) * 0.7);
    }

    // Text-like lines, so it reads as a window with content in it.
    for (int i = 0; i < 5; i++) {
        float ly = rect.y + rect.w - barH * 2.2 - float(i) * rect.w * 0.085;
        float lw = rect.z * (0.62 - mod(float(i) * 0.17, 0.34));
        float inLine = step(rect.x + rect.z * 0.08, p.x) * step(p.x, rect.x + rect.z * 0.08 + lw)
                     * step(ly - rect.w * 0.018, p.y) * step(p.y, ly + rect.w * 0.018);
        body = mix(body, vec3(0.22, 0.24, 0.30), inLine * 0.9);
    }

    return vec4(body, inside);
}

// The ring itself — the part ported from Shaders.metal.
vec4 ring(vec2 p, vec4 rect) {
    vec2 halfSize = rect.zw * 0.5;
    vec2 c = rect.xy + halfSize;
    vec2 q = p - c;

    float d = sdRoundBox(q, halfSize, uCornerRadius);
    if (d > uBandOuter * 1.5 + uGlowFalloff * 5.0 || d < -uBandInner * 1.5) {
        return vec4(0.0);
    }

    float theta = atan(q.y / max(halfSize.y, 1.0), q.x / max(halfSize.x, 1.0));
    vec2 r = vec2(cos(theta), sin(theta));

    vec2 wq = r * uNoiseScale + vec2(0.0, uWarpPhase);
    vec2 warp = vec2(fbm2(wq), fbm2(wq + vec2(5.2, 1.3)));

    float tongues = fbm3(r * uNoiseScale * 1.5 + warp * 1.15
                         + vec2(uFlowPhase, -uFlowPhase * 0.55));
    float detail = fbm2(r * uNoiseScale * 3.5
                        - vec2(uFlowPhase * 1.6, uWarpPhase * 1.65));

    float n = clamp(0.68 * tongues + 0.42 * detail, 0.0, 1.0);
    n = smoothstep(0.12, 0.88, n);

    float outerLocal = uBandOuter * (0.45 + 1.05 * n);
    float glowLocal  = uGlowFalloff * (0.55 + 0.85 * n);

    float band = smoothstep(outerLocal, 0.0, d) * smoothstep(-uBandInner, 0.0, d);
    float glow = exp(-max(d, 0.0) / max(glowLocal, 0.5));

    float across = clamp((d + uBandInner) / max(uBandInner + outerLocal, 1.0), 0.0, 1.0);
    vec3 core = mix(uColorB, uColorA, n);
    vec3 colour = mix(core, uColorGlow, across * 0.55);

    float bandAlpha = band * (0.30 + 0.70 * n);
    float glowAlpha = glow * 0.32;
    float alpha = clamp((bandAlpha + glowAlpha) * uIntensity, 0.0, 1.0);

    vec3 premul = colour * (bandAlpha * uIntensity) + uColorGlow * (glowAlpha * uIntensity);
    return vec4(premul, alpha);
}

void main() {
    vec2 p = gl_FragCoord.xy;
    vec3 col = desktop(p / uResolution);

    // Unfocused window first, so the focused one and its ring sit on top.
    vec4 back  = windowLayer(p, uFocus < 0.5 ? uWindowB : uWindowA, 0.0);
    col = mix(col, back.rgb, back.a);
    vec4 front = windowLayer(p, uFocus < 0.5 ? uWindowA : uWindowB, 1.0);
    col = mix(col, front.rgb, front.a);

    vec4 r = ring(p, uFocus < 0.5 ? uWindowA : uWindowB);
    col = col * (1.0 - r.a) + r.rgb;

    gl_FragColor = vec4(col, 1.0);
}
`;

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

const PALETTES = [
  { name: "Ember",       a: 0xFF3D00, b: 0xFFC400, glow: 0xFF6D00 },
  { name: "Plasma",      a: 0x7C4DFF, b: 0x00E5FF, glow: 0x536DFE },
  { name: "Toxic",       a: 0x76FF03, b: 0x00E676, glow: 0xB2FF59 },
  { name: "Magma",       a: 0xD50000, b: 0xFF6E40, glow: 0xFF1744 },
  { name: "Ice",         a: 0x18FFFF, b: 0x82B1FF, glow: 0x40C4FF },
  { name: "Neon Rose",   a: 0xFF4081, b: 0xF50057, glow: 0xFF80AB },
  { name: "Solar",       a: 0xFFD600, b: 0xFFAB00, glow: 0xFFEA00 },
  { name: "Aurora",      a: 0x00E676, b: 0x00B0FF, glow: 0x1DE9B6 },
  { name: "Ultraviolet", a: 0xE040FB, b: 0x651FFF, glow: 0xAA00FF },
  { name: "Copper",      a: 0xFF9100, b: 0xFFD180, glow: 0xFF6D00 },
];

// The app stores palettes in linear RGB, because every operation done to them —
// mixing the two band colours, cross-fading between palettes — is an
// interpolation, and interpolating in gamma space gives muddy mid-tones.
const srgbToLinear = c => c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
const toLinear = hex => [16, 8, 0].map(s => srgbToLinear(((hex >> s) & 0xFF) / 255));

function compile(gl, type, src) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(sh));
  }
  return sh;
}

export function start(canvas, controls) {
  const gl = canvas.getContext("webgl", { antialias: false, alpha: false });
  if (!gl) { throw new Error("WebGL unavailable"); }

  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(prog));
  }
  gl.useProgram(prog);

  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
  const aPos = gl.getAttribLocation(prog, "aPos");
  gl.enableVertexAttribArray(aPos);
  gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

  const u = name => gl.getUniformLocation(prog, name);
  const U = {
    resolution: u("uResolution"), windowA: u("uWindowA"), windowB: u("uWindowB"),
    focus: u("uFocus"), cornerRadius: u("uCornerRadius"),
    bandInner: u("uBandInner"), bandOuter: u("uBandOuter"),
    flowPhase: u("uFlowPhase"), warpPhase: u("uWarpPhase"),
    intensity: u("uIntensity"), noiseScale: u("uNoiseScale"),
    glowFalloff: u("uGlowFalloff"),
    colorA: u("uColorA"), colorB: u("uColorB"), colorGlow: u("uColorGlow"),
  };

  // Phases are integrated, never computed as time * speed. Multiplying a large
  // timestamp by a changing speed — which is what a flare does — makes the
  // pattern leap and spin instead of simply moving faster. This was a real bug
  // in the app before it was a line of commentary here.
  let flowPhase = 0, warpPhase = 0, last = performance.now() / 1000;
  let flareStart = -100;
  let focus = 0;
  let dpr = 1;

  const state = {
    palette: 1,            // Plasma
    idleIntensity: 0.30,
    flareDuration: 2.5,
    bandInner: 6, bandOuter: 18,
    flowSpeed: 0.45, noiseScale: 4.0,
    autoSwitch: true,
  };

  function flare() { flareStart = performance.now() / 1000; }
  function switchFocus() { focus = 1 - focus; flare(); }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
      canvas.width = w * dpr; canvas.height = h * dpr;
      gl.viewport(0, 0, canvas.width, canvas.height);
    }
  }

  let nextSwitch = performance.now() / 1000 + 4;

  function frame() {
    resize();
    const now = performance.now() / 1000;
    const dt = Math.min(now - last, 0.1);
    last = now;

    if (state.autoSwitch && now > nextSwitch) { switchFocus(); nextSwitch = now + 5; }

    // The same decay curve as Animator.swift: brightness, band width and speed
    // all come off one exponential so the ring relaxes as a single thing.
    const t = now - flareStart;
    const p = t >= state.flareDuration || t < 0 ? 0 : Math.exp(-3 * t / state.flareDuration);
    const intensity = state.idleIntensity + (1 - state.idleIntensity) * p;
    const bandScale = 1 + 0.6 * p;
    const speedScale = 1 + 0.8 * p;

    flowPhase += dt * state.flowSpeed * speedScale;
    warpPhase += dt * state.flowSpeed * speedScale * 0.4;

    const W = canvas.width, H = canvas.height;
    const s = Math.min(W, H) / 620;
    const wW = W * 0.40, wH = H * 0.42;
    const A = [W * 0.10, H * 0.30, wW, wH];
    const B = [W * 0.50, H * 0.16, wW, wH];

    gl.uniform2f(U.resolution, W, H);
    gl.uniform4fv(U.windowA, A);
    gl.uniform4fv(U.windowB, B);
    gl.uniform1f(U.focus, focus);
    gl.uniform1f(U.cornerRadius, 11 * s);
    gl.uniform1f(U.bandInner, Math.max(state.bandInner * s, 1.5));
    gl.uniform1f(U.bandOuter, Math.max(state.bandOuter * s * bandScale, 1.5));
    gl.uniform1f(U.glowFalloff, Math.max(state.bandOuter * s * 0.6, 1.0));
    gl.uniform1f(U.flowPhase, flowPhase);
    gl.uniform1f(U.warpPhase, warpPhase);
    gl.uniform1f(U.intensity, intensity);
    gl.uniform1f(U.noiseScale, state.noiseScale);

    const pal = PALETTES[state.palette];
    gl.uniform3fv(U.colorA, toLinear(pal.a));
    gl.uniform3fv(U.colorB, toLinear(pal.b));
    gl.uniform3fv(U.colorGlow, toLinear(pal.glow));

    gl.drawArrays(gl.TRIANGLES, 0, 3);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  return { state, flare, switchFocus, PALETTES };
}
