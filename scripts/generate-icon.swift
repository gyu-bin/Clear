// Renders the Clear app icon at every size the asset catalog needs.
// Usage: swift scripts/generate-icon.swift Clear/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 185 / 1024
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.45))
    ctx.addPath(path); ctx.setFillColor(color(0x10141C)); ctx.fillPath()
    ctx.restoreGState()

    // Body gradient (navy → charcoal)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0x22303F), color(0x10141C)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft mint glow
    let glow = CGGradient(colorsSpace: cs, colors: [color(0x87D9D7, 0.35), color(0x87D9D7, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.52), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.52), endRadius: s * 0.42, options: [])
    ctx.restoreGState()

    // Inner hairline
    ctx.saveGState()
    ctx.addPath(path); ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(max(1, s * 0.004)); ctx.strokePath()
    ctx.restoreGState()

    // Ring gauge: track + 3/4 arc with mint→cyan gradient
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let r = s * 0.235
    let lw = s * 0.07
    ctx.setLineCap(.round)
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    ctx.saveGState()
    let arc = CGMutablePath()
    arc.addArc(center: center, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.5, clockwise: true)
    let stroked = arc.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 1)
    ctx.addPath(stroked); ctx.clip()
    let ringGradient = CGGradient(colorsSpace: cs, colors: [color(0xA6F0E4), color(0x87D9D7), color(0x5BB8E8)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(ringGradient, start: CGPoint(x: center.x - r, y: center.y + r), end: CGPoint(x: center.x + r, y: center.y - r), options: [])
    ctx.restoreGState()

    // Sparkle in the middle
    func sparkle(at p: CGPoint, size k: CGFloat, alpha: CGFloat) {
        let sp = CGMutablePath()
        sp.move(to: CGPoint(x: p.x, y: p.y + k))
        sp.addQuadCurve(to: CGPoint(x: p.x + k, y: p.y), control: CGPoint(x: p.x + k * 0.12, y: p.y + k * 0.12))
        sp.addQuadCurve(to: CGPoint(x: p.x, y: p.y - k), control: CGPoint(x: p.x + k * 0.12, y: p.y - k * 0.12))
        sp.addQuadCurve(to: CGPoint(x: p.x - k, y: p.y), control: CGPoint(x: p.x - k * 0.12, y: p.y - k * 0.12))
        sp.addQuadCurve(to: CGPoint(x: p.x, y: p.y + k), control: CGPoint(x: p.x - k * 0.12, y: p.y + k * 0.12))
        ctx.addPath(sp); ctx.setFillColor(color(0xF2FBFA, alpha)); ctx.fillPath()
    }
    sparkle(at: center, size: s * 0.105, alpha: 1)
    sparkle(at: CGPoint(x: center.x + s * 0.105, y: center.y + s * 0.095), size: s * 0.035, alpha: 0.85)

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let url = outputDir.appendingPathComponent("icon_\(size).png")
    try! render(size: size).write(to: url)
    print("wrote \(url.lastPathComponent)")
}
