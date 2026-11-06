// Renders the app icon: a film frame being squeezed between two arrows.
// usage: swift scripts/make-icon.swift <output.iconset>
// then:  iconutil -c icns <output.iconset> -o Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Squircle background.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor(red: 0.36, green: 0.30, blue: 0.92, alpha: 1).setFill()
    bg.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor(red: 0.42, green: 0.56, blue: 1.0, alpha: 1),
                        NSColor(red: 0.36, green: 0.20, blue: 0.84, alpha: 1)])!.draw(in: bg, angle: -90)

    // Film frame: a strip with sprocket holes down both sides.
    let strip = NSBezierPath(roundedRect: NSRect(x: 362, y: 280, width: 300, height: 470), xRadius: 26, yRadius: 26)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setFill(); strip.fill()
    ctx.restoreGState()
    NSColor(red: 0.36, green: 0.24, blue: 0.86, alpha: 0.45).setFill()
    for i in 0..<6 {
        for x in [378, 618] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 306 + i * 74, width: 28, height: 40), xRadius: 8, yRadius: 8).fill()
        }
    }

    // The picture, with a play button.
    let screen = NSBezierPath(roundedRect: NSRect(x: 422, y: 320, width: 180, height: 390), xRadius: 14, yRadius: 14)
    NSGradient(colors: [NSColor(red: 0.27, green: 0.30, blue: 0.62, alpha: 1),
                        NSColor(red: 0.16, green: 0.13, blue: 0.40, alpha: 1)])!.draw(in: screen, angle: -90)
    let play = NSBezierPath()
    play.move(to: NSPoint(x: 482, y: 565)); play.line(to: NSPoint(x: 482, y: 465)); play.line(to: NSPoint(x: 564, y: 515))
    play.close()
    NSColor.white.setFill(); play.fill()

    // Squeeze arrows.
    NSColor.white.setFill()
    for dir in [1.0, -1.0] {
        let cx = 512 - dir * 290
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: cx + dir * 110, y: 515))
        arrow.line(to: NSPoint(x: cx + dir * 20, y: 605))
        arrow.line(to: NSPoint(x: cx + dir * 20, y: 555))
        arrow.line(to: NSPoint(x: cx - dir * 55, y: 555))
        arrow.line(to: NSPoint(x: cx - dir * 55, y: 475))
        arrow.line(to: NSPoint(x: cx + dir * 20, y: 475))
        arrow.line(to: NSPoint(x: cx + dir * 20, y: 425))
        arrow.close()
        arrow.fill()
    }
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
