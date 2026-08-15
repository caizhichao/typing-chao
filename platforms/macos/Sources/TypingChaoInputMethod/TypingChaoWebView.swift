import AppKit
import WebKit

// 约束包内 React 页面只能通过单一消息通道调用原生输入法能力，避免 Web UI 直接接触密钥或网络实现。
enum TypingChaoWebViewName: String {
    case candidate
    case settings
    case aiInput = "ai-input"
}

// 接收 WebKit 的结构化页面消息，并在页面销毁时自动释放回调避免输入法会话循环引用。
private final class TypingChaoWebMessageHandler: NSObject, WKScriptMessageHandler {
    var messageHandler: (([String: Any]) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let messageBody = message.body as? [String: Any] else {
            NSLog("TypingChao ignored malformed Web UI message")
            return
        }
        messageHandler?(messageBody)
    }
}

// 复用系统 WebKit 加载包内静态资源；设置页允许原生文本焦点，AI 面板保留 IMK 键盘主链。
final class TypingChaoWebView: WKWebView, WKNavigationDelegate {
    private static let messageHandlerName = "typingChao"

    private let acceptsKeyboardFocus: Bool
    private let nativeMessageHandler: TypingChaoWebMessageHandler
    private var messageHandler: (([String: Any]) -> Void)?
    private var isPageReady = false
    private var pendingMessageList: [(messageType: String, messageData: Any)] = []

    init(webViewName: TypingChaoWebViewName, acceptsKeyboardFocus: Bool) {
        self.acceptsKeyboardFocus = acceptsKeyboardFocus
        nativeMessageHandler = TypingChaoWebMessageHandler()

        let userContentController = WKUserContentController()
        let userScript = WKUserScript(
            source: "window.typingChaoViewName = \"\(webViewName.rawValue)\";",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(userScript)
        userContentController.add(nativeMessageHandler, name: Self.messageHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        super.init(frame: .zero, configuration: configuration)

        navigationDelegate = self
        allowsBackForwardNavigationGestures = false
        if webViewName == .aiInput {
            wantsLayer = true
            layer?.cornerRadius = 15
            layer?.masksToBounds = true
        }
        if webViewName == .candidate {
            wantsLayer = true
            layer?.cornerRadius = 9
            layer?.masksToBounds = true
            underPageBackgroundColor = .clear
        }
        nativeMessageHandler.messageHandler = { [weak self] messageBody in
            self?.messageHandler?(messageBody)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    override var acceptsFirstResponder: Bool {
        acceptsKeyboardFocus
    }

    func setMessageHandler(_ handler: @escaping ([String: Any]) -> Void) {
        messageHandler = handler
    }

    // 页面主动确认 React 已挂载后再发送状态，避免初始化阶段的脚本调用丢失。
    func markPageReady() {
        isPageReady = true
        let queuedMessageList = pendingMessageList
        pendingMessageList.removeAll()
        for queuedMessage in queuedMessageList {
            sendMessage(
                messageType: queuedMessage.messageType,
                messageData: queuedMessage.messageData
            )
        }
    }

    // 静态页面必须来自 app Resources，加载失败时在页面内呈现可行动提示而不是空白浮层。
    func loadBundledPage() {
        isPageReady = false
        pendingMessageList.removeAll()
        guard let resourceRoot = Bundle.main.resourceURL else {
            showResourceError()
            return
        }
        let pageURL = resourceRoot
            .appendingPathComponent("WebUI", isDirectory: true)
            .appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: pageURL.path) else {
            showResourceError()
            return
        }
        loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    // 原生状态经过 JSON 序列化后再注入，避免字符串拼接让用户内容改变脚本结构。
    func sendMessage(messageType: String, messageData: Any) {
        guard isPageReady else {
            if let pendingIndex = pendingMessageList.lastIndex(where: { $0.messageType == messageType }) {
                pendingMessageList[pendingIndex] = (messageType, messageData)
            } else {
                pendingMessageList.append((messageType, messageData))
            }
            return
        }
        let nativeMessage: [String: Any] = [
            "messageType": messageType,
            "messageData": messageData,
        ]
        guard JSONSerialization.isValidJSONObject(nativeMessage) else {
            NSLog("TypingChao ignored non-serializable Web UI state: %@", messageType)
            return
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: nativeMessage)
            guard let jsonText = String(data: jsonData, encoding: .utf8) else {
                NSLog("TypingChao could not encode Web UI state: %@", messageType)
                return
            }
            evaluateJavaScript("window.typingChaoReceive(\(jsonText));") { _, error in
                guard let error else { return }
                NSLog("TypingChao Web UI state delivery failed for %@: %@", messageType, error.localizedDescription)
            }
        } catch {
            NSLog("TypingChao Web UI state serialization failed for %@: %@", messageType, error.localizedDescription)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let requestURL = navigationAction.request.url else {
            NSLog("TypingChao blocked Web UI navigation without URL")
            decisionHandler(.cancel)
            return
        }
        if requestURL.isFileURL || requestURL.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        NSLog("TypingChao blocked non-local Web UI navigation")
        decisionHandler(.cancel)
    }

    private func showResourceError() {
        let errorHTML = """
        <!doctype html><html lang=\"zh-CN\"><body style=\"margin:0;display:grid;place-items:center;height:100vh;font:-apple-system-body;background:#202225;color:#fff\"><div style=\"text-align:center\"><strong>Web UI 资源缺失</strong><p style=\"color:#bbb\">请重新构建并安装 Typing Chao。</p></div></body></html>
        """
        loadHTMLString(errorHTML, baseURL: nil)
    }
}
