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
        guard panel.canBecomeKey, !panel.canBecomeMain else {
            fatalError("AI input panel must accept the AI prompt focus without becoming the main window")
        }
        let promptView = AIInputPromptView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        guard promptView.acceptsFirstResponder else {
            fatalError("AI prompt view must accept first responder focus")
        }
        print("AI input overlay smoke test passed: key panel and prompt first responder")
    }
}
