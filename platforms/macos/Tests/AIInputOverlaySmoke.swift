import AppKit

@main
struct AIInputOverlaySmoke {
    static func main() {
        let panel = AIInputOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        guard !panel.canBecomeKey, !panel.canBecomeMain else {
            fatalError("AI input panel must preserve the host IMK session instead of accepting text focus")
        }
        print("AI input overlay smoke test passed: host-session panel lifecycle")
    }
}
