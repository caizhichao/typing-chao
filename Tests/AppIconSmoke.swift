import AppKit

@main
struct AppIconSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 128,
                pixelsHigh: 128,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            fatalError("app icon must be a readable color PDF")
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("app icon bitmap context is unavailable")
        }
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 128, height: 128).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: 128, height: 128),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        verifyTransparentCorners(bitmap)
        verifyColorIcon(bitmap)
        print("App icon smoke test passed: transparent corners, blue/teal background, and white translation glyph")
    }

    private static func verifyTransparentCorners(_ bitmap: NSBitmapImageRep) {
        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 127, y: 0), NSPoint(x: 0, y: 127), NSPoint(x: 127, y: 127)] {
            guard let color = bitmap.colorAt(x: Int(point.x), y: Int(point.y)), color.alphaComponent < 0.01 else {
                fatalError("app icon corners must stay transparent")
            }
        }
    }

    private static func verifyColorIcon(_ bitmap: NSBitmapImageRep) {
        guard let backgroundColor = bitmap.colorAt(x: 32, y: 64),
              backgroundColor.blueComponent > 0.7,
              backgroundColor.alphaComponent > 0.9 else {
            fatalError("app icon must keep its blue product background")
        }
        guard let accentColor = bitmap.colorAt(x: 99, y: 42),
              accentColor.greenComponent > accentColor.redComponent,
              accentColor.alphaComponent > 0.9 else {
            fatalError("app icon must keep its teal translation accent")
        }
        var whiteGlyphPixelCount = 0
        for y in 0..<128 {
            for x in 0..<128 {
                guard let glyphColor = bitmap.colorAt(x: x, y: y),
                      glyphColor.alphaComponent > 0.8,
                      glyphColor.redComponent > 0.85,
                      glyphColor.greenComponent > 0.85,
                      glyphColor.blueComponent > 0.85 else {
                    continue
                }
                whiteGlyphPixelCount += 1
            }
        }
        guard whiteGlyphPixelCount > 700 else {
            fatalError("app icon must keep a visible white translation glyph")
        }
    }
}
