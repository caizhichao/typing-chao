import AppKit

// 译文展示框只发出两个明确确认动作，不读取宿主正文或参与网络生命周期。
enum TranslationOverlayAction {
    case useTranslation
    case commitOriginal
}

// 统一翻译模式的等待、请求、结果和错误视觉状态。
enum TranslationOverlayPresentation {
    case waiting
    case loading
    case translation
    case error
}

// 只负责显示翻译模式状态和显式确认按钮，不再提供追溯替换入口。
final class TranslationOverlay {
    private let panel: TranslationOverlayPanel
    private let visualEffectView: NSVisualEffectView
    private let contentView: TranslationCardView

    init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 280, height: 60)
        contentView = TranslationCardView(frame: initialFrame)
        contentView.autoresizingMask = [.width, .height]

        visualEffectView = NSVisualEffectView(frame: initialFrame)
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .darkAqua)
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = TranslationCardStyle.cornerRadius
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.backgroundColor = TranslationCardStyle.backgroundColor.cgColor
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = TranslationCardStyle.borderColor.cgColor
        visualEffectView.addSubview(contentView)

        panel = TranslationOverlayPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = visualEffectView
        panel.mouseEventHandler = { [weak contentView] event in
            contentView?.handlePanelMouseEvent(event) ?? false
        }
    }

    // 两个确认动作统一回到输入控制器结束 marked draft 事务。
    func setActionHandler(_ actionHandler: @escaping (TranslationOverlayAction) -> Void) {
        contentView.actionHandler = actionHandler
    }

    func showWaiting(
        languagePair: String,
        anchor: InputOverlayAnchor,
        candidateFrame: NSRect?
    ) {
        show(
            content: TranslationCardContent(
                languagePair: languagePair,
                bodyText: "继续输入，停顿 1 秒后翻译",
                presentation: .waiting
            ),
            anchor: anchor,
            candidateFrame: candidateFrame
        )
    }

    func showLoading(
        languagePair: String,
        anchor: InputOverlayAnchor,
        candidateFrame: NSRect?
    ) {
        show(
            content: TranslationCardContent(
                languagePair: languagePair,
                bodyText: "正在翻译…",
                presentation: .loading
            ),
            anchor: anchor,
            candidateFrame: candidateFrame
        )
    }

    func showTranslation(
        translatedText: String,
        languagePair: String,
        anchor: InputOverlayAnchor,
        candidateFrame: NSRect?
    ) {
        guard !translatedText.isEmpty else {
            hide()
            return
        }
        show(
            content: TranslationCardContent(
                languagePair: languagePair,
                bodyText: translatedText,
                presentation: .translation
            ),
            anchor: anchor,
            candidateFrame: candidateFrame
        )
    }

    func showError(
        message: String,
        languagePair: String,
        anchor: InputOverlayAnchor,
        candidateFrame: NSRect?
    ) {
        show(
            content: TranslationCardContent(
                languagePair: languagePair,
                bodyText: message,
                presentation: .error
            ),
            anchor: anchor,
            candidateFrame: candidateFrame
        )
    }

    func hide() {
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    var visibleFrame: NSRect? {
        panel.isVisible ? panel.frame : nil
    }

    func updatePosition(anchor: InputOverlayAnchor, candidateFrame: NSRect?) {
        guard panel.isVisible else { return }
        panel.setFrameOrigin(
            anchor.translationOrigin(
                for: panel.frame.size,
                candidateFrame: candidateFrame
            )
        )
    }

    // 四种状态共用同一层与同一左边缘，只有结果态开放两个按钮的鼠标事件。
    private func show(
        content: TranslationCardContent,
        anchor: InputOverlayAnchor,
        candidateFrame: NSRect?
    ) {
        let panelSize = contentView.update(
            content: content,
            maximumPanelWidth: anchor.availableOverlayWidth
        )
        visualEffectView.frame = NSRect(origin: .zero, size: panelSize)
        contentView.frame = visualEffectView.bounds
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(anchor.translationOrigin(for: panelSize, candidateFrame: candidateFrame))
        panel.ignoresMouseEvents = content.presentation != .translation
        panel.orderFrontRegardless()
    }
}

// 非激活输入法浮窗在窗口层转发鼠标，避免宿主焦点不变时按钮收不到点击。
final class TranslationOverlayPanel: NSPanel {
    var mouseEventHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if mouseEventHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

// 汇总翻译展示框一次绘制所需数据，等待和结果状态不再分别拼装布局。
private struct TranslationCardContent {
    let languagePair: String
    let bodyText: String
    let presentation: TranslationOverlayPresentation
}

private enum TranslationCardStyle {
    static let cornerRadius: CGFloat = 10
    static let backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 0.74)
    static let borderColor = NSColor(calibratedWhite: 1, alpha: 0.14)
    static let accentColor = NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1)
    static let secondaryFillColor = NSColor(calibratedWhite: 1, alpha: 0.055)
}

// 结果态按钮使用固定高度，正文只在有限宽度档位内换行，避免卡片抖成横向长条。
struct TranslationCardLayout {
    static let maximumPanelWidth: CGFloat = 420
    static let maximumBodyHeight: CGFloat = 92
    static let compactPanelHeight: CGFloat = 60
    static let maximumTranslationPanelHeight: CGFloat = 158
    static let horizontalInset: CGFloat = 12
    static let headerHeight: CGFloat = 28
    static let actionHeight: CGFloat = 28
    static let actionBottomInset: CGFloat = 10
    static let actionGap: CGFloat = 8

    static func resolvedSize(
        bodyText: String,
        presentation: TranslationOverlayPresentation,
        availableWidth: CGFloat
    ) -> NSSize {
        let maximumWidth = min(max(availableWidth, 1), maximumPanelWidth)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        ]
        let minimumWidth = min(presentation == .translation ? 280 : 240, maximumWidth)
        let naturalBodyWidth = NSString(string: bodyText).size(withAttributes: bodyAttributes).width
        let preferredWidth = min(
            max(naturalBodyWidth + horizontalInset * 2, minimumWidth),
            maximumWidth
        )
        let panelWidth = stablePanelWidth(
            preferredWidth: preferredWidth,
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth
        )
        guard presentation == .translation else {
            let bodyRect = NSString(string: bodyText).boundingRect(
                with: NSSize(width: max(panelWidth - horizontalInset * 2, 1), height: 44),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: bodyAttributes
            )
            return NSSize(
                width: panelWidth,
                height: max(compactPanelHeight, ceil(bodyRect.height) + headerHeight + 12)
            )
        }

        let bodyRect = NSString(string: bodyText).boundingRect(
            with: NSSize(
                width: max(panelWidth - horizontalInset * 2, 1),
                height: maximumBodyHeight
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: bodyAttributes
        )
        let panelHeight = min(
            headerHeight + ceil(bodyRect.height) + 12 + actionHeight + actionBottomInset,
            maximumTranslationPanelHeight
        )
        return NSSize(width: panelWidth, height: max(panelHeight, 92))
    }

    private static func stablePanelWidth(
        preferredWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGFloat {
        for widthTier in [240, 280, 340, maximumPanelWidth] as [CGFloat] {
            let resolvedWidth = min(widthTier, maximumWidth)
            if resolvedWidth >= preferredWidth, resolvedWidth >= minimumWidth {
                return resolvedWidth
            }
        }
        return maximumWidth
    }
}

// 两个确认按钮共享同一排版入口，绘制和点击命中始终使用同一矩形。
struct TranslationActionLayout {
    let primaryRect: NSRect
    let secondaryRect: NSRect

    static func resolve(panelSize: NSSize) -> TranslationActionLayout {
        let availableWidth = panelSize.width - TranslationCardLayout.horizontalInset * 2
        let buttonWidth = max(
            (availableWidth - TranslationCardLayout.actionGap) / 2,
            1
        )
        let buttonY = panelSize.height - TranslationCardLayout.actionBottomInset - TranslationCardLayout.actionHeight
        return TranslationActionLayout(
            primaryRect: NSRect(
                x: TranslationCardLayout.horizontalInset,
                y: buttonY,
                width: buttonWidth,
                height: TranslationCardLayout.actionHeight
            ),
            secondaryRect: NSRect(
                x: TranslationCardLayout.horizontalInset + buttonWidth + TranslationCardLayout.actionGap,
                y: buttonY,
                width: buttonWidth,
                height: TranslationCardLayout.actionHeight
            )
        )
    }
}

private final class TranslationCardView: NSView {
    private var content = TranslationCardContent(
        languagePair: "简体中文 → 英语",
        bodyText: "继续输入，停顿 1 秒后翻译",
        presentation: .waiting
    )
    private var actionLayout = TranslationActionLayout.resolve(
        panelSize: NSSize(width: 280, height: 92)
    )
    private var hoveredAction: TranslationOverlayAction?
    private var pressedAction: TranslationOverlayAction?
    private var maximumPanelWidth = TranslationCardLayout.maximumPanelWidth
    var actionHandler: ((TranslationOverlayAction) -> Void)?

    override var isFlipped: Bool { true }

    // 每次状态变化只重算当前内容尺寸，等待与加载态保持同一紧凑高度。
    func update(content: TranslationCardContent, maximumPanelWidth: CGFloat) -> NSSize {
        self.content = content
        self.maximumPanelWidth = min(
            max(maximumPanelWidth, 1),
            TranslationCardLayout.maximumPanelWidth
        )
        hoveredAction = nil
        pressedAction = nil
        let panelSize = calculateSize()
        actionLayout = TranslationActionLayout.resolve(panelSize: panelSize)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        return panelSize
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard content.presentation == .translation else { return }
        addCursorRect(actionLayout.primaryRect, cursor: .pointingHand)
        addCursorRect(actionLayout.secondaryRect, cursor: .pointingHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // 非激活 panel 的窗口事件按按钮矩形路由，拖出按钮后抬起不会误确认。
    func handlePanelMouseEvent(_ event: NSEvent) -> Bool {
        guard content.presentation == .translation else { return false }
        let location = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .mouseMoved:
            let nextAction = action(at: location)
            if nextAction != hoveredAction {
                hoveredAction = nextAction
                needsDisplay = true
            }
            return nextAction != nil
        case .leftMouseDown:
            guard let nextAction = action(at: location) else { return false }
            pressedAction = nextAction
            hoveredAction = nextAction
            needsDisplay = true
            return true
        case .leftMouseDragged:
            guard pressedAction != nil else { return false }
            hoveredAction = action(at: location)
            needsDisplay = true
            return true
        case .leftMouseUp:
            guard let pressedAction else { return false }
            let releasedAction = action(at: location)
            self.pressedAction = nil
            hoveredAction = releasedAction
            needsDisplay = true
            if releasedAction == pressedAction {
                actionHandler?(pressedAction)
            }
            return true
        default:
            return false
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBackground()
        drawHeader()
        drawBody()
        if content.presentation == .translation {
            drawAction(
                titleText: "使用译文",
                actionName: .useTranslation,
                actionRect: actionLayout.primaryRect,
                isPrimary: true
            )
            drawAction(
                titleText: "上屏原文",
                actionName: .commitOriginal,
                actionRect: actionLayout.secondaryRect,
                isPrimary: false
            )
        }
    }

    private func action(at location: NSPoint) -> TranslationOverlayAction? {
        if actionLayout.primaryRect.contains(location) {
            return .useTranslation
        }
        if actionLayout.secondaryRect.contains(location) {
            return .commitOriginal
        }
        return nil
    }

    private func drawBackground() {
        NSColor(calibratedWhite: 0.02, alpha: 0.14).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: TranslationCardStyle.cornerRadius - 1,
            yRadius: TranslationCardStyle.cornerRadius - 1
        ).fill()
    }

    private func drawHeader() {
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.58),
        ]
        NSString(string: content.languagePair).draw(
            at: NSPoint(x: TranslationCardLayout.horizontalInset, y: 8),
            withAttributes: headerAttributes
        )
    }

    private func drawBody() {
        var bodyColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        if content.presentation == .waiting || content.presentation == .loading {
            bodyColor = NSColor(calibratedWhite: 1, alpha: 0.58)
        }
        if content.presentation == .error {
            bodyColor = NSColor(calibratedRed: 1, green: 0.68, blue: 0.62, alpha: 0.92)
        }
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: bodyColor,
        ]
        var bodyHeight = bounds.height - TranslationCardLayout.headerHeight - 8
        if content.presentation == .translation {
            bodyHeight -= TranslationCardLayout.actionHeight + TranslationCardLayout.actionBottomInset + 8
        }
        NSString(string: content.bodyText).draw(
            with: NSRect(
                x: TranslationCardLayout.horizontalInset,
                y: TranslationCardLayout.headerHeight,
                width: max(bounds.width - TranslationCardLayout.horizontalInset * 2, 1),
                height: max(bodyHeight, 18)
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: bodyAttributes
        )
    }

    private func drawAction(
        titleText: String,
        actionName: TranslationOverlayAction,
        actionRect: NSRect,
        isPrimary: Bool
    ) {
        let isHovered = hoveredAction == actionName
        let isPressed = pressedAction == actionName && isHovered
        var fillColor = TranslationCardStyle.secondaryFillColor
        var textColor = NSColor(calibratedWhite: 1, alpha: 0.78)
        if isPrimary {
            fillColor = NSColor(calibratedWhite: 0.96, alpha: isPressed ? 0.78 : 0.96)
            textColor = NSColor(calibratedWhite: 0.10, alpha: 0.96)
        } else if isPressed {
            fillColor = NSColor(calibratedWhite: 1, alpha: 0.14)
        } else if isHovered {
            fillColor = NSColor(calibratedWhite: 1, alpha: 0.09)
        }
        fillColor.setFill()
        NSBezierPath(roundedRect: actionRect, xRadius: 6, yRadius: 6).fill()
        if !isPrimary {
            TranslationCardStyle.borderColor.setStroke()
            let borderPath = NSBezierPath(roundedRect: actionRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            borderPath.lineWidth = 1
            borderPath.stroke()
        }
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: textColor,
        ]
        let titleValue = NSString(string: titleText)
        let titleSize = titleValue.size(withAttributes: titleAttributes)
        titleValue.draw(
            at: NSPoint(
                x: actionRect.midX - titleSize.width / 2,
                y: actionRect.midY - titleSize.height / 2
            ),
            withAttributes: titleAttributes
        )
    }

    private func calculateSize() -> NSSize {
        TranslationCardLayout.resolvedSize(
            bodyText: content.bodyText,
            presentation: content.presentation,
            availableWidth: maximumPanelWidth
        )
    }
}
