import AppKit
import Foundation

// Original vector artwork rendered at each macOS icon resolution.
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
func render(pixels: Int, filename: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.13, blue: 0.20, alpha: 1),
               ending: NSColor(srgbRed: 0.16, green: 0.23, blue: 0.30, alpha: 1))!.draw(in: tile, angle: 70)
    NSColor.white.withAlphaComponent(0.13).setStroke()
    tile.lineWidth = 3; tile.stroke()
    let colors = [NSColor(srgbRed: 0.22, green: 0.83, blue: 0.71, alpha: 1),
                  NSColor(srgbRed: 0.36, green: 0.65, blue: 1, alpha: 1),
                  NSColor(srgbRed: 1, green: 0.63, blue: 0.35, alpha: 1)]
    for (i, height) in [340, 570, 450].enumerated() {
        let x = CGFloat(220 + i * 210)
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 220, width: 150, height: 600), xRadius: 55, yRadius: 55).fill()
        colors[i].setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 220, width: 150, height: CGFloat(height)), xRadius: 55, yRadius: 55).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(filename))
}
for size in [16, 32, 128, 256, 512] {
    try render(pixels: size, filename: "icon_\(size)x\(size).png")
    try render(pixels: size * 2, filename: "icon_\(size)x\(size)@2x.png")
}
