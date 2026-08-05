import AppKit

// 从完整 Rime 快照派生用户可理解的模式变化文案，半/全角与标点保持两个独立状态。
enum InputModeStatusMessage {
    static func resolve(previous: RimeSnapshot, current: RimeSnapshot) -> String? {
        guard !previous.schemaIdentifier.isEmpty else { return nil }
        if previous.isFullShape != current.isFullShape {
            if current.isFullShape {
                return "全角字符"
            }
            return "半角字符"
        }
        if previous.isAsciiPunctuation != current.isAsciiPunctuation {
            if current.isAsciiPunctuation {
                return "西文标点"
            }
            return "中文标点"
        }
        return nil
    }
}

// 半/全角等模式切换用独立短时状态层反馈，不伪装成候选项，也不占用翻译浮层。
final class InputModeStatusOverlay {
    private static let panelHeight: CGFloat = 34
    private static let minimumPanelWidth: CGFloat = 86
    private static let maximumPanelWidth: CGFloat = 156
    private static let displayDuration = 0.9

    private let panel: NSPanel
    private let visualEffectView: NSVisualEffectView
    private let statusLabel: NSTextField
    private var hideWorkItem: DispatchWorkItem?

    init() {
        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: Self.minimumPanelWidth,
            height: Self.panelHeight
        )
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.alignment = .center
        statusLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byClipping

        visualEffectView = NSVisualEffectView(frame: initialFrame)
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 8
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        visualEffectView.addSubview(statusLabel)

        panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = visualEffectView
    }

    // 模式提示复用辅助层定位并避开候选条，组合中切换状态也不会覆盖候选内容。
    func show(message: String, anchor: InputOverlayAnchor, candidateFrame: NSRect?) {
        hideWorkItem?.cancel()
        statusLabel.stringValue = message
        let measuredWidth = ceil(statusLabel.intrinsicContentSize.width) + 30
        let panelWidth = min(max(measuredWidth, Self.minimumPanelWidth), Self.maximumPanelWidth)
        let panelSize = NSSize(width: panelWidth, height: Self.panelHeight)
        visualEffectView.frame = NSRect(origin: .zero, size: panelSize)
        statusLabel.frame = NSRect(x: 12, y: 8, width: panelWidth - 24, height: 18)
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(anchor.translationOrigin(for: panelSize, candidateFrame: candidateFrame))
        panel.orderFrontRegardless()

        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        self.hideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.displayDuration,
            execute: hideWorkItem
        )
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.orderOut(nil)
    }
}
