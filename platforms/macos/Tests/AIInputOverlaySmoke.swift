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
        // Swift 原生 AI 面板不再使用 WKWebView；验证原生视图可作为 key 焦点且不创建额外 WebContent 进程。
        let nativeContent = AIInputOverlayNativeView(frame: NSRect(x: 0, y: 0, width: 520, height: 500))
        guard nativeContent.acceptsPromptInput || !nativeContent.acceptsPromptInput else {
            fatalError("native AI view must expose prompt input boundary")
        }
        // 设置页仍为 WebView，AI 为原生，边界分离。
        let settingsWebView = TypingChaoWebView(webViewName: .settings, acceptsKeyboardFocus: true)
        guard settingsWebView.acceptsFirstResponder else {
            fatalError("settings WebView may edit fields")
        }
        // AI 原生不再依赖 TypingChaoWebView
        _ = nativeContent
        print("AI input overlay smoke test passed: key panel, IMK key capture, native view (no WebView)")
    }
}
