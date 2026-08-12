import AppKit
import Foundation

let out = URL(fileURLWithPath: "Live2Still/Assets.xcassets/AppIcon.appiconset")
let canvasSize = NSSize(width: 1024, height: 1024)

func makeImage(bgTop: NSColor, bgBottom: NSColor, ring: NSColor, frame: NSColor, accent: NSColor) -> NSImage {
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 512, y: 1024),
        end: CGPoint(x: 512, y: 0),
        options: []
    )
    let ringRect = CGRect(x: 172, y: 172, width: 680, height: 680)
    ctx.setStrokeColor(ring.cgColor)
    ctx.setLineWidth(28)
    ctx.strokeEllipse(in: ringRect)
    let frameRect = CGRect(x: 292, y: 264, width: 440, height: 460)
    let path = NSBezierPath(roundedRect: frameRect, xRadius: 48, yRadius: 48)
    frame.setFill()
    path.fill()
    accent.setStroke()
    path.lineWidth = 12
    path.stroke()
    let sun = CGRect(x: 442, y: 584, width: 80, height: 80)
    ctx.setFillColor(accent.cgColor)
    ctx.fillEllipse(in: sun)
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, filename: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1024,
        pixelsHigh: 1024,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try! png.write(to: out.appendingPathComponent(filename))
    print("wrote \(filename)")
}

writePNG(
    makeImage(
        bgTop: NSColor(red: 1, green: 0.7, blue: 0.24, alpha: 1),
        bgBottom: NSColor(red: 1, green: 0.47, blue: 0.16, alpha: 1),
        ring: .white,
        frame: NSColor(white: 1, alpha: 0.94),
        accent: NSColor(red: 1, green: 0.86, blue: 0.47, alpha: 1)
    ),
    filename: "AppIcon.png"
)
writePNG(
    makeImage(
        bgTop: NSColor(red: 0.18, green: 0.14, blue: 0.22, alpha: 1),
        bgBottom: NSColor(red: 0.08, green: 0.07, blue: 0.11, alpha: 1),
        ring: NSColor(red: 1, green: 0.78, blue: 0.47, alpha: 1),
        frame: NSColor(white: 0.94, alpha: 1),
        accent: NSColor(red: 1, green: 0.63, blue: 0.31, alpha: 1)
    ),
    filename: "AppIcon-dark.png"
)
writePNG(
    makeImage(
        bgTop: NSColor(white: 0.47, alpha: 1),
        bgBottom: NSColor(white: 0.31, alpha: 1),
        ring: .white,
        frame: NSColor(white: 1, alpha: 0.95),
        accent: NSColor(white: 0.86, alpha: 1)
    ),
    filename: "AppIcon-tinted.png"
)
