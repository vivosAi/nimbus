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
uniform vec4  uWin0;         // x, y, w, h  (px, y up)
uniform vec4  uWin1;
uniform vec4  uWin2;
uniform vec4  uWin3;
uniform vec4  uScreen0;      // the two displays
uniform vec4  uScreen1;
uniform float uFocusIndex;   // 0..3
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

// The space the monitors sit in.
vec3 ambient(vec2 uv) {
    float v = 1.0 - 0.7 * length(uv - vec2(0.5, 0.5));
    return mix(vec3(0.012, 0.014, 0.022), vec3(0.028, 0.031, 0.044), v);
}

// Indexed with if/else rather than a uniform array: GLSL ES 1.00 restricts
// dynamic indexing, and a few branches are clearer than fighting it.
vec4 rectFor(float i) {
    if (i < 0.5) return uWin0;
    if (i < 1.5) return uWin1;
    if (i < 2.5) return uWin2;
    return uWin3;
}

// A display: the desktop surface plus a thin bezel edge, so two of them read as
// two monitors rather than as one wide canvas. Multi-monitor is where losing
// track of focus actually hurts, so the demo should look like it.
vec4 screenPanel(vec2 p, vec4 rect) {
    vec2 halfSize = rect.zw * 0.5;
    vec2 c = rect.xy + halfSize;
    float d = sdRoundBox(p - c, halfSize, 6.0);
    if (d > 3.0) return vec4(0.0);

    vec2 uv = (p - rect.xy) / rect.zw;
    float v = 1.0 - 0.5 * length(uv - vec2(0.5, 0.58));
    vec3 col = mix(vec3(0.047, 0.054, 0.078), vec3(0.078, 0.086, 0.121), v);
    // Bezel: a bright hairline at the very edge.
    col = mix(col, vec3(0.20, 0.22, 0.28), smoothstep(-2.0, -0.2, d));
    return vec4(col, 1.0 - smoothstep(-0.5, 1.0, d));
}

// Real macOS windows cast a soft shadow, and its absence is most of why a
// mock-up looks flat. The focused window gets a deeper one, as it does on a
// real desktop.
float windowShadow(vec2 p, vec4 rect, float focused) {
    vec2 halfSize = rect.zw * 0.5;
    vec2 c = rect.xy + halfSize - vec2(0.0, rect.w * 0.015);
    float d = sdRoundBox(p - c, halfSize, uCornerRadius + 3.0);
    float spread = rect.w * (0.045 + 0.035 * focused);
    return exp(-max(d, 0.0) / spread) * (0.45 + 0.25 * focused);
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
    vec3 color = mix(core, uColorGlow, across * 0.55);

    float bandAlpha = band * (0.30 + 0.70 * n);
    float glowAlpha = glow * 0.32;
    float alpha = clamp((bandAlpha + glowAlpha) * uIntensity, 0.0, 1.0);

    vec3 premul = color * (bandAlpha * uIntensity) + uColorGlow * (glowAlpha * uIntensity);
    return vec4(premul, alpha);
}

void main() {
    vec2 p = gl_FragCoord.xy;
    vec3 col = ambient(p / uResolution);

    vec4 s0 = screenPanel(p, uScreen0);
    col = mix(col, s0.rgb, s0.a);
    vec4 s1 = screenPanel(p, uScreen1);
    col = mix(col, s1.rgb, s1.a);

    // Index order is stacking order, back to front. Each window is preceded by
    // its own shadow so it falls on what is behind it, not on itself.
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        if (abs(fi - uFocusIndex) < 0.5) continue;
        vec4 r = rectFor(fi);
        col *= 1.0 - windowShadow(p, r, 0.0);
        vec4 w = windowLayer(p, r, 0.0);
        col = mix(col, w.rgb, w.a);
    }

    vec4 fr = rectFor(uFocusIndex);
    col *= 1.0 - windowShadow(p, fr, 1.0);
    vec4 focused = windowLayer(p, fr, 1.0);
    col = mix(col, focused.rgb, focused.a);

    vec4 r = ring(p, rectFor(uFocusIndex));
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
// mixing the two band colors, cross-fading between palettes — is an
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

export function start(canvas, labels) {
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
    resolution: u("uResolution"),
    win: [u("uWin0"), u("uWin1"), u("uWin2"), u("uWin3")],
    screen: [u("uScreen0"), u("uScreen1")],
    focusIndex: u("uFocusIndex"), cornerRadius: u("uCornerRadius"),
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
  let focusIndex = 1;
  let rects = [];
  let screens = [];
  let labelledAt = "";

  // Palette cross-fade, as in the app: a hard cut reads as a glitch, so one
  // color always dissolves into the next.
  let paletteFrom = 1, paletteTo = 1, fadeStart = -100;
  const FADE = 3.0;
  let lastRotate = performance.now() / 1000;

  const state = {
    idleIntensity: 0.30,
    flareDuration: 2.5,
    bandInner: 6, bandOuter: 18,
    flowSpeed: 0.45, noiseScale: 4.0,
    rotate: true,
    rotateEvery: 9,       // seconds; the app's default is 30 minutes
  };

  function flare() { flareStart = performance.now() / 1000; }

  function focusWindow(i) {
    if (i === focusIndex) { flare(); return; }
    focusIndex = i;
    flare();
  }

  function setPalette(i) {
    const now = performance.now() / 1000;
    paletteFrom = currentPaletteIndexApprox(now);
    paletteTo = i;
    fadeStart = now;
    lastRotate = now;
  }

  function currentPaletteIndexApprox(now) {
    // Mid-fade the visible color is a blend; for the next fade's starting
    // point the nearer end is close enough and keeps this simple.
    return (now - fadeStart) < FADE / 2 ? paletteFrom : paletteTo;
  }

  function nextPalette() {
    let i = paletteTo;
    while (i === paletteTo) i = Math.floor(Math.random() * PALETTES.length);
    setPalette(i);
  }

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      gl.viewport(0, 0, canvas.width, canvas.height);
    }
  }

  // Two displays side by side, because multi-monitor is where losing track of
  // keyboard focus actually costs you something. Windows are laid out inside
  // each display in landscape proportions, and overlap, the way real ones do.
  function layout(W, H) {
    const sw = W * 0.484;
    const sh = sw * (10 / 16);            // a 16:10 display
    const sy = (H - sh) / 2;
    const s0 = [W * 0.008, sy, sw, sh];
    const s1 = [W * 0.508, sy, sw, sh];

    // Placed relative to whichever display they sit on.
    const inset = (s, x, y, w, h) => [s[0] + s[2] * x, s[1] + s[3] * y,
                                      s[2] * w, s[3] * h];
    return {
      screens: [s0, s1],
      // Index order is stacking order: 1 sits over 0, 3 sits over 2.
      windows: [
        inset(s0, 0.05, 0.30, 0.60, 0.44),   // left display, behind
        inset(s0, 0.31, 0.10, 0.62, 0.46),   // left display, on top
        inset(s1, 0.07, 0.44, 0.55, 0.40),   // right display, behind
        inset(s1, 0.34, 0.09, 0.60, 0.45),   // right display, on top
      ],
    };
  }

  function hitTest(clientX, clientY) {
    const r = canvas.getBoundingClientRect();
    const sx = canvas.width / r.width, sy = canvas.height / r.height;
    const x = (clientX - r.left) * sx;
    // Canvas pixels run y-up here, the DOM runs y-down.
    const y = canvas.height - (clientY - r.top) * sy;
    // Front to back, so clicking an overlap hits the window on top — which is
    // what clicking does on a real desktop.
    for (let i = rects.length - 1; i >= 0; i--) {
      const [rx, ry, rw, rh] = rects[i];
      if (x >= rx && x <= rx + rw && y >= ry && y <= ry + rh) return i;
    }
    return -1;
  }

  canvas.addEventListener("click", e => {
    const i = hitTest(e.clientX, e.clientY);
    if (i >= 0) focusWindow(i);
  });
  canvas.addEventListener("mousemove", e => {
    canvas.style.cursor = hitTest(e.clientX, e.clientY) >= 0 ? "pointer" : "default";
  });

  function frame() {
    resize();
    const now = performance.now() / 1000;
    const dt = Math.min(now - last, 0.1);
    last = now;

    if (state.rotate && now - lastRotate > state.rotateEvery) nextPalette();

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
    const scene = layout(W, H);

    // Keep the screen captions under the displays the renderer draws, instead
    // of hard-coded percentages that drift whenever the layout changes. Only
    // touched when the canvas size changes, to avoid per-frame layout work.
    const sizeKey = W + "x" + H;
    if (labels && sizeKey !== labelledAt) {
      labelledAt = sizeKey;
      scene.screens.forEach((r, i) => {
        const el = labels[i];
        if (!el) return;
        el.style.left = ((r[0] + r[2] / 2) / W * 100) + "%";
        el.style.top = ((H - r[1]) / H * 100) + "%";
        el.style.marginTop = "9px";
      });
    }
    // Scale the ring against a simulated display rather than the whole canvas,
    // or the band reads as far thicker than it is in the app.
    const s = scene.screens[0][2] / 700;
    rects = scene.windows;
    screens = scene.screens;

    gl.uniform2f(U.resolution, W, H);
    rects.forEach((r, i) => gl.uniform4fv(U.win[i], r));
    screens.forEach((r, i) => gl.uniform4fv(U.screen[i], r));
    gl.uniform1f(U.focusIndex, focusIndex);
    gl.uniform1f(U.cornerRadius, 11 * s);
    gl.uniform1f(U.bandInner, Math.max(state.bandInner * s, 1.5));
    gl.uniform1f(U.bandOuter, Math.max(state.bandOuter * s * bandScale, 1.5));
    gl.uniform1f(U.glowFalloff, Math.max(state.bandOuter * s * 0.6, 1.0));
    gl.uniform1f(U.flowPhase, flowPhase);
    gl.uniform1f(U.warpPhase, warpPhase);
    gl.uniform1f(U.intensity, intensity);
    gl.uniform1f(U.noiseScale, state.noiseScale);

    // Cross-fade in linear RGB, smoothstepped so the fade has no visible start
    // or stop edge.
    const raw = Math.min(Math.max((now - fadeStart) / FADE, 0), 1);
    const e = raw * raw * (3 - 2 * raw);
    const from = PALETTES[paletteFrom], to = PALETTES[paletteTo];
    const blend = (x, y) => x.map((v, k) => v + (y[k] - v) * e);
    gl.uniform3fv(U.colorA, blend(toLinear(from.a), toLinear(to.a)));
    gl.uniform3fv(U.colorB, blend(toLinear(from.b), toLinear(to.b)));
    gl.uniform3fv(U.colorGlow, blend(toLinear(from.glow), toLinear(to.glow)));

    gl.drawArrays(gl.TRIANGLES, 0, 3);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  return {
    state, flare, setPalette, nextPalette, PALETTES,
    get palette() { return paletteTo; },
    focusWindow,
  };
}
