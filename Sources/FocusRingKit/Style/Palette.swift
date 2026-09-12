import simd

/// A ring colour scheme. Stored as sRGB hex for legibility, converted to linear
/// RGB before it reaches the shader — mixing and cross-fading colours in gamma
/// space produces muddy mid-tones, which on a two-colour ring is very visible.
public struct Palette: Equatable {
    public let name: String
    public let hexA: UInt32
    public let hexB: UInt32
    public let hexGlow: UInt32

    public init(name: String, a: UInt32, b: UInt32, glow: UInt32) {
        self.name = name
        self.hexA = a
        self.hexB = b
        self.hexGlow = glow
    }

    public var colorA: SIMD3<Float> { Palette.linear(from: hexA) }
    public var colorB: SIMD3<Float> { Palette.linear(from: hexB) }
    public var colorGlow: SIMD3<Float> { Palette.linear(from: hexGlow) }

    /// All high-chroma and bright: the ring has to win against arbitrary window
    /// content, including a white document and a dark terminal.
    public static let all: [Palette] = [
        Palette(name: "Ember",       a: 0xFF3D00, b: 0xFFC400, glow: 0xFF6D00),
        Palette(name: "Plasma",      a: 0x7C4DFF, b: 0x00E5FF, glow: 0x536DFE),
        Palette(name: "Toxic",       a: 0x76FF03, b: 0x00E676, glow: 0xB2FF59),
        Palette(name: "Magma",       a: 0xD50000, b: 0xFF6E40, glow: 0xFF1744),
        Palette(name: "Ice",         a: 0x18FFFF, b: 0x82B1FF, glow: 0x40C4FF),
        Palette(name: "Neon Rose",   a: 0xFF4081, b: 0xF50057, glow: 0xFF80AB),
        Palette(name: "Solar",       a: 0xFFD600, b: 0xFFAB00, glow: 0xFFEA00),
        Palette(name: "Aurora",      a: 0x00E676, b: 0x00B0FF, glow: 0x1DE9B6),
        Palette(name: "Ultraviolet", a: 0xE040FB, b: 0x651FFF, glow: 0xAA00FF),
        Palette(name: "Copper",      a: 0xFF9100, b: 0xFFD180, glow: 0xFF6D00),
    ]

    // MARK: - Colour space

    public static func linear(from hex: UInt32) -> SIMD3<Float> {
        SIMD3(srgbToLinear(Float((hex >> 16) & 0xFF) / 255),
              srgbToLinear(Float((hex >>  8) & 0xFF) / 255),
              srgbToLinear(Float( hex        & 0xFF) / 255))
    }

    public static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
