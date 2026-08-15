import AppKit

@main
struct AIInputOverlaySmoke {
    static func main() {
        _ = NSApplication.shared
        let panel = AIInputOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        guard panel.canBecomeKey, !panel.canBecomeMain else {
            fatalError("AI input panel must accept the AI prompt focus without becoming the main window")
        }
        let keyCaptureView = AIInputKeyCaptureView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        guard keyCaptureView.acceptsFirstResponder else {
            fatalError("AI key capture view must preserve the existing IMK session focus")
        }
        let settingsWebView = TypingChaoWebView(webViewName: .settings, acceptsKeyboardFocus: true)
        let aiWebView = TypingChaoWebView(webViewName: .aiInput, acceptsKeyboardFocus: false)
        guard settingsWebView.acceptsFirstResponder, !aiWebView.acceptsFirstResponder else {
            fatalError("settings WebView may edit fields, while AI WebView must keep keyboard focus in the native IMK bridge")
        }
        print("AI input overlay smoke test passed: key panel, IMK key capture, and WebView focus boundary")
    }
}
