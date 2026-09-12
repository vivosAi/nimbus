// Generates AppIcon.iconset from code, so the icon is reproducible and
// reviewable in the repository rather than being an opaque binary someone has
// to open a design tool to change.
//
//   swift Tools/make-icon.swift build/AppIcon.iconset
//   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

import AppKit
import CoreImage

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"

/// The Plasma palette, matching one of the ring's own colour schemes.
let colourA: UInt32 = 0x7C4DFF
let colourB: UInt32 = 0x00E5FF
let colourGlow: UInt32 = 0x536DFE

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func layer(_ size: CGFloat, _ draw: (CGFloat) -> Void) -> CGImage {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    draw(size)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

/// A real Gaussian blur. Approximating the bloom by stroking the same path at
/// widening widths leaves visible concentric contour bands.
func blurred(_ image: CGImage, radius: CGFloat, size: CGFloat) -> CGImage {
    let filter = CIFilter(name: "CIGaussianBlur")!
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(radius, forKey: kCIInputRadiusKey)
    // Blurring grows the extent; crop back so it composites in register.
    let out = filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    return CIContext().createCGImage(out, from: out.extent)!
}

func paths(_ s: CGFloat) -> (base: NSBezierPath, dash1: NSBezierPath, dash2: NSBezierPath,
                             window: CGRect, radius: CGFloat) {
    let centre = CGPoint(x: s / 2, y: s / 2)
    let window = CGRect(x: centre.x - s * 0.20, y: centre.y - s * 0.15,
                        width: s * 0.40, height: s * 0.30)
    let radius = s * 0.045
    let spread = s * 0.055
    let outer = radius + spread
    let rect = window.insetBy(dx: -spread, dy: -spread)

    func ring() -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: outer, yRadius: outer)
    }

    let dash1 = ring()
    var p1: [CGFloat] = [0.16, 0.10, 0.07, 0.09, 0.20, 0.10].map { $0 * s }
    dash1.setLineDash(&p1, count: p1.count, phase: s * 0.05)
    dash1.lineCapStyle = .round

    let dash2 = ring()
    var p2: [CGFloat] = [0.07, 0.22, 0.12, 0.14].map { $0 * s }
    dash2.setLineDash(&p2, count: p2.count, phase: s * 0.30)
    dash2.lineCapStyle = .round

    return (ring(), dash1, dash2, window, radius)
}

func render(size s: CGFloat, to path: String) {
    // The light on its own, transparent — this is what gets blurred.
    let light = layer(s) { s in
        let p = paths(s)
        p.base.lineWidth = s * 0.030;  srgb(colourGlow).setStroke(); p.base.stroke()
        p.dash1.lineWidth = s * 0.024; srgb(colourB).setStroke();    p.dash1.stroke()
        p.dash2.lineWidth = s * 0.022; srgb(colourA).setStroke();    p.dash2.stroke()
    }
    let wide = blurred(light, radius: s * 0.075, size: s)
    let tight = blurred(light, radius: s * 0.022, size: s)

    let px = Int(s)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext

    let inset = s * 0.085
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    NSBezierPath(roundedRect: body, xRadius: s * 0.225, yRadius: s * 0.225).addClip()
    // Dark ground, so the ring reads as light emitted rather than paint applied.
    NSGradient(colors: [srgb(0x1B1F30), srgb(0x07080E)])!.draw(in: body, angle: -90)

    let full = CGRect(x: 0, y: 0, width: s, height: s)
    // Additive, for the same reason the shader outputs premultiplied alpha:
    // light adds to what is behind it, it does not cover it.
    ctx.setBlendMode(.plusLighter)
    ctx.setAlpha(0.85); ctx.draw(wide, in: full)
    ctx.setAlpha(0.95); ctx.draw(tight, in: full)
    ctx.setAlpha(1.0);  ctx.draw(light, in: full)
    ctx.setBlendMode(.normal)

    let p = paths(s)
    let win = NSBezierPath(roundedRect: p.window, xRadius: p.radius, yRadius: p.radius)
    srgb(0x0B0D16).setFill(); win.fill()

    // A title bar and traffic lights, so the shape reads as a Mac window rather
    // than as a plain rectangle. Both are dropped below 64px: at icon sizes
    // that small they turn to mush, and a suggestion of detail is worse than
    // none. Apple's own icons simplify the same way.
    if s >= 64 {
        let barHeight = p.window.height * 0.22
        let bar = CGRect(x: p.window.minX, y: p.window.maxY - barHeight,
                         width: p.window.width, height: barHeight)
        NSGraphicsContext.saveGraphicsState()
        // Clip to the window so the bar keeps the rounded top corners.
        win.addClip()
        srgb(0xFFFFFF, 0.07).setFill()
        NSBezierPath(rect: bar).fill()
        srgb(0xFFFFFF, 0.10).setFill()
        NSBezierPath(rect: CGRect(x: bar.minX, y: bar.minY,
                                  width: bar.width, height: max(s * 0.002, 0.5))).fill()

        let dot = barHeight * 0.30
        let gap = dot * 1.85
        var x = p.window.minX + barHeight * 0.62
        // Dim, not literal red/yellow/green: at this size the colours would
        // read as noise, and the shape alone is what says "window".
        for alpha in [0.38, 0.30, 0.30] as [CGFloat] {
            srgb(0xFFFFFF, alpha).setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: bar.midY - dot/2,
                                        width: dot, height: dot)).fill()
            x += gap
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    srgb(0xFFFFFF, 0.16).setStroke(); win.lineWidth = s * 0.006; win.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try? FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)
// Every size is rendered natively rather than downscaled from one large image,
// so the small ones stay crisp.
for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                       (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 1 ? "" : "@2x"
    render(size: CGFloat(point * scale),
           to: "\(outDir)/icon_\(point)x\(point)\(suffix).png")
}
print("wrote \(outDir)")
