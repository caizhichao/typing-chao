import AppKit

@main
struct MenuIconSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 16,
                pixelsHigh: 16,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            fatalError("menu icon must be a readable 16×16 PDF")
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("menu icon bitmap context is unavailable")
        }
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: 16, height: 16),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        verifyTransparentCorners(bitmap)
        verifySparseMonochromeGlyph(bitmap)
        print("Menu icon smoke test passed: transparent corners, sparse mask, and monochrome translation glyph")
    }

    // 菜单模板会把所有非透明像素统一着色，因此四角必须完全透明，不能再画背景底块。
    private static func verifyTransparentCorners(_ bitmap: NSBitmapImageRep) {
        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 15, y: 0), NSPoint(x: 0, y: 15), NSPoint(x: 15, y: 15)] {
            guard let color = bitmap.colorAt(x: Int(point.x), y: Int(point.y)), color.alphaComponent < 0.01 else {
                fatalError("menu icon corners must stay transparent")
            }
        }
    }

    // 可见像素必须是稀疏单色符号，避免再次退化成整块白色圆角方形。
    private static func verifySparseMonochromeGlyph(_ bitmap: NSBitmapImageRep) {
        var visiblePixelCount = 0
        var minimumX = 16
        var minimumY = 16
        var maximumX = -1
        var maximumY = -1
        for y in 0..<16 {
            for x in 0..<16 {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.05 else {
                    continue
                }
                visiblePixelCount += 1
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
                guard abs(color.redComponent - color.greenComponent) < 0.03,
                      abs(color.greenComponent - color.blueComponent) < 0.03 else {
                    fatalError("menu icon must remain monochrome")
                }
            }
        }
        guard visiblePixelCount >= 24,
              visiblePixelCount <= 100,
              minimumX <= 4,
              minimumY <= 4,
              maximumX >= 11,
              maximumY >= 11 else {
            fatalError("menu icon alpha mask must be a centered sparse glyph, got \(visiblePixelCount) pixels")
        }
    }
}
