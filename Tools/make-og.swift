// The social preview card. 1200x630 is what Open Graph consumers crop to;
// handing them the square app icon instead gets it letterboxed or cut.
//
//   swift Tools/make-og.swift docs/og.png

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/og.png"
let W: CGFloat = 1200, H: CGFloat = 630

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF)/255,
            green: CGFloat((hex >> 8) & 0xFF)/255,
            blue: CGFloat(hex & 0xFF)/255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

NSGradient(colors: [srgb(0x161A2B), srgb(0x06070C)])!
    .draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: -78)

let iconSize: CGFloat = 268
let iconRect = CGRect(x: 108, y: (H - iconSize) / 2, width: iconSize, height: iconSize)
let iconCentre = CGPoint(x: iconRect.midX, y: iconRect.midY)

// Unbounded radial draw, not a rectangle filled with a radial gradient. The
// latter paints a visible square edge where the rectangle ends.
NSGradient(colors: [srgb(0x536DFE, 0.34), srgb(0x7C4DFF, 0.14), srgb(0x536DFE, 0.0)])!
    .draw(fromCenter: iconCentre, radius: 0,
          toCenter: iconCentre, radius: 330, options: [])

if let icon = NSImage(contentsOfFile: "docs/icon.png") {
    icon.draw(in: iconRect)
}

let textLeft: CGFloat = 452

let title = NSAttributedString(string: "Nimbus", attributes: [
    .font: NSFont.systemFont(ofSize: 96, weight: .semibold),
    .foregroundColor: NSColor.white,
    .kern: -2.5,
])
title.draw(at: CGPoint(x: textLeft, y: 372))

// Line breaks are explicit and the box is measured, rather than trusting the
// text to wrap where it looks right. Left to itself at the previous size it
// took three lines and the last one was sliced off by the rule below.
let body = NSMutableParagraphStyle()
body.lineSpacing = 8
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 31, weight: .regular),
    .foregroundColor: srgb(0xAEB4CC),
    .paragraphStyle: body,
]
let sub = NSAttributedString(
    string: "macOS hides which window has keyboard focus.\nNimbus makes it obvious.",
    attributes: subAttrs)
let subWidth: CGFloat = W - textLeft - 44
let subHeight = ceil(sub.boundingRect(
    with: CGSize(width: subWidth, height: .greatestFiniteMagnitude),
    options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 4
assert(subHeight < 130, "description grew past its slot")
sub.draw(in: CGRect(x: textLeft + 4, y: 236, width: subWidth, height: subHeight))

// A hairline above the footer, to sit the credentials on something.
srgb(0xFFFFFF, 0.11).setFill()
NSBezierPath(rect: CGRect(x: textLeft + 4, y: 206, width: 500, height: 1)).fill()

let footer = NSAttributedString(
    string: "Free and open source   ·   Apple Silicon and Intel   ·   macOS 13+",
    attributes: [
        .font: NSFont.systemFont(ofSize: 23, weight: .medium),
        .foregroundColor: srgb(0x7C8298),
        .kern: 0.2,
    ])
footer.draw(at: CGPoint(x: textLeft + 4, y: 164))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
