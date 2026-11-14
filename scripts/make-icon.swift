// Renders the CcinnClickHouse app icon (all macOS iconset sizes) with AppKit: an ember-amber squircle
// with stacked data parts merging into one — the MergeTree idea, without any vendor artwork.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 186 * scale

    // Drop shadow under the squircle.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.70, green: 0.18, blue: 0.08, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Ember gradient.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.99, green: 0.68, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.45, blue: 0.14, alpha: 1),
        NSColor(srgbRed: 0.66, green: 0.16, blue: 0.07, alpha: 1),
    ], atLocations: [0, 0.5, 1], colorSpace: .sRGB)
    gradient?.draw(in: shape, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Soft top highlight.
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.24), NSColor.white.withAlphaComponent(0)])
    highlight?.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    // Small "parts" on the left flowing into the stack (merges).
    let parts: [(CGFloat, CGFloat, CGFloat)] = [(0.17, 0.70, 46), (0.13, 0.52, 38), (0.19, 0.34, 30)]
    for (x, y, size) in parts {
        let rect = NSRect(x: body.minX + body.width * x - size * scale / 2, y: body.minY + body.height * y - size * scale / 2,
                          width: size * scale, height: size * scale)
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8 * scale, yRadius: 8 * scale).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Stacked-parts glyph.
    let configuration = NSImage.SymbolConfiguration(pointSize: 430 * scale, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "square.stack.3d.down.forward.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        glyphShadow.shadowBlurRadius = 18 * scale
        glyphShadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        NSGraphicsContext.saveGraphicsState()
        glyphShadow.set()
        let size = tinted.size
        let origin = NSPoint(x: body.midX - size.width / 2 + 40 * scale, y: body.midY - size.height / 2)
        tinted.draw(in: NSRect(origin: origin, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
print("wrote \(sizes.count) images to \(outputDirectory.path)")
