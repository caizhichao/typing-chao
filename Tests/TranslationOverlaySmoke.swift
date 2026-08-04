import AppKit

@main
struct TranslationOverlaySmoke {
    static func main() {
        verifyStableModeStates()
        verifyTranslationResultLayout()
        verifyExplicitActionLayout()
        verifyPanelMouseEventRouting()
        print("Translation overlay smoke test passed: stable waiting/loading states, bounded result layout, explicit actions, and panel-level mouse routing")
    }

    // 等待和请求状态必须保持同一尺寸，避免一秒防抖前后浮层上下跳动。
    private static func verifyStableModeStates() {
        let waitingSize = TranslationCardLayout.resolvedSize(
            bodyText: "继续输入，停顿 1 秒后翻译",
            presentation: .waiting,
            availableWidth: 1200
        )
        let loadingSize = TranslationCardLayout.resolvedSize(
            bodyText: "正在翻译…",
            presentation: .loading,
            availableWidth: 1200
        )
        guard waitingSize.height == TranslationCardLayout.compactPanelHeight,
              loadingSize.height == TranslationCardLayout.compactPanelHeight,
              waitingSize.width == loadingSize.width else {
            fatalError("waiting and loading states must keep one stable compact frame")
        }
    }

    // 完整译文在有限宽度内换行，并为两个明确操作保留固定按钮行。
    private static func verifyTranslationResultLayout() {
        let shortSize = TranslationCardLayout.resolvedSize(
            bodyText: "Hello! How is the weather today?",
            presentation: .translation,
            availableWidth: 1200
        )
        let longSize = TranslationCardLayout.resolvedSize(
            bodyText: "Using product information as the carrier, create compliant QR codes and provide certification, promotion, and application services without changing the original meaning.",
            presentation: .translation,
            availableWidth: 1200
        )
        guard shortSize.width >= 280,
              shortSize.height >= 92,
              longSize.width == TranslationCardLayout.maximumPanelWidth,
              longSize.height > shortSize.height,
              longSize.height <= TranslationCardLayout.maximumTranslationPanelHeight else {
            fatalError("translation result must stay compact while preserving a visible action row")
        }
        let constrainedSize = TranslationCardLayout.resolvedSize(
            bodyText: "This result must remain visible near the edge of a narrow screen.",
            presentation: .translation,
            availableWidth: 300
        )
        guard constrainedSize.width <= 300 else {
            fatalError("available screen width must constrain the translation card")
        }
    }

    // 使用译文和上屏原文必须是两个独立且完整位于卡片内的点击区域。
    private static func verifyExplicitActionLayout() {
        let panelSize = NSSize(width: 340, height: 112)
        let actionLayout = TranslationActionLayout.resolve(panelSize: panelSize)
        let panelBounds = NSRect(origin: .zero, size: panelSize)
        guard panelBounds.contains(actionLayout.primaryRect),
              panelBounds.contains(actionLayout.secondaryRect),
              !actionLayout.primaryRect.intersects(actionLayout.secondaryRect),
              actionLayout.primaryRect.width == actionLayout.secondaryRect.width else {
            fatalError("translation confirmation actions must be explicit, balanced, and non-overlapping")
        }
    }

    // 非激活 NSPanel 必须先在窗口 sendEvent 层收到点击，再交给按钮状态机处理。
    private static func verifyPanelMouseEventRouting() {
        let panel = TranslationOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var didReceiveMouseUp = false
        panel.mouseEventHandler = { event in
            didReceiveMouseUp = event.type == .leftMouseUp
            return true
        }
        guard let mouseUpEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else {
            fatalError("expected synthetic panel mouse event")
        }
        panel.sendEvent(mouseUpEvent)
        guard didReceiveMouseUp else {
            fatalError("nonactivating translation panel must route mouse-up at the window level")
        }
    }
}
