import AppKit

// 只负责显示简短译文状态和安全替换动作，不参与网络请求生命周期。
final class TranslationOverlay {
    private let panel: NSPanel
    private let visualEffectView: NSVisualEffectView
    private let contentView: TranslationCardView

    init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 260, height: 36)
        contentView = TranslationCardView(frame: initialFrame)
        contentView.autoresizingMask = [.width, .height]

        visualEffectView = NSVisualEffectView(frame: initialFrame)
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = TranslationCardStyle.cornerRadius
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = TranslationCardStyle.borderColor.cgColor
        visualEffectView.addSubview(contentView)

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
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = visualEffectView
    }

    // 译文确认行为由输入控制器处理，浮层只在可替换状态转发按钮点击。
    func setTranslationSelectionHandler(_ selectionHandler: @escaping () -> Void) {
        contentView.selectionHandler = selectionHandler
    }

    func showTranslation(
        translatedText: String,
        languagePair: String,
        replacementEnabled: Bool,
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
                presentation: .translation,
                replacementEnabled: replacementEnabled
            ),
            anchor: anchor,
            candidateFrame: candidateFrame
        )
    }

    func showStale(
        translatedText: String,
        languagePair: String,
        anchor: InputOverlayAnchor,
        candidateFrame: NSRect?
    ) {
        show(
            content: TranslationCardContent(
                languagePair: languagePair,
                bodyText: translatedText,
                presentation: .stale,
                replacementEnabled: false
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
                presentation: .error,
                replacementEnabled: false
            ),
            anchor: anchor,
            candidateFrame: candidateFrame
        )
    }

    func hide() {
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    // 候选条每次随光标变化时只更新译文卡位置，避免重新创建浮层造成跳动。
    func updatePosition(anchor: InputOverlayAnchor, candidateFrame: NSRect?) {
        guard panel.isVisible else { return }
        panel.setFrameOrigin(anchor.translationOrigin(for: panel.frame.size, candidateFrame: candidateFrame))
    }

    private func show(
        content: TranslationCardContent,
        anchor: InputOverlayAnchor,
        candidateFrame: NSRect?
    ) {
        let panelSize = contentView.update(
            content: content,
            maximumPanelWidth: anchor.availableOverlayWidth
        )
        panel.ignoresMouseEvents = !content.replacementEnabled
        visualEffectView.frame = NSRect(origin: .zero, size: panelSize)
        contentView.frame = visualEffectView.bounds
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(anchor.translationOrigin(for: panelSize, candidateFrame: candidateFrame))
        panel.orderFrontRegardless()
    }
}

// 汇总译文浮层一次绘制所需数据，避免加载、结果和失效状态各自拼装字段。
private struct TranslationCardContent {
    let languagePair: String
    let bodyText: String
    let presentation: TranslationPresentation
    let replacementEnabled: Bool
}

private enum TranslationPresentation {
    case translation
    case stale
    case error
}

private enum TranslationCardStyle {
    static let maximumPanelWidth: CGFloat = 960
    static let maximumTranslationBodyHeight: CGFloat = 76
    static let cornerRadius: CGFloat = 9
    static let borderColor = NSColor(calibratedWhite: 1, alpha: 0.15)
    static let accentColor = NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1)
}

private final class TranslationCardView: NSView {
    private var content = TranslationCardContent(
        languagePair: "中 → 英",
        bodyText: "",
        presentation: .translation,
        replacementEnabled: false
    )
    private var actionRect = NSRect.zero
    private var actionHovered = false
    private var actionPressed = false
    private var maximumPanelWidth = TranslationCardStyle.maximumPanelWidth
    var selectionHandler: (() -> Void)?

    override var isFlipped: Bool { true }

    // 译文卡只按译文正文决定尺寸，不再重复显示用户刚输入的原文。
    func update(content: TranslationCardContent, maximumPanelWidth: CGFloat) -> NSSize {
        self.content = content
        self.maximumPanelWidth = min(
            max(maximumPanelWidth, 1),
            TranslationCardStyle.maximumPanelWidth
        )
        actionHovered = false
        actionPressed = false
        let panelSize = calculateSize()
        actionRect = .zero
        if content.replacementEnabled {
            actionRect = NSRect(
                x: panelSize.width - 68,
                y: (panelSize.height - 20) / 2,
                width: 56,
                height: 20
            )
        }
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
        if content.replacementEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // 整张验证通过的译文卡都是替换入口，hover 反馈必须与实际点击范围一致。
    override func mouseMoved(with event: NSEvent) {
        guard content.replacementEnabled else { return }
        let location = convert(event.locationInWindow, from: nil)
        let nextHovered = bounds.contains(location)
        if nextHovered != actionHovered {
            actionHovered = nextHovered
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        actionHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard content.replacementEnabled else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        actionPressed = true
        actionHovered = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard actionPressed else { return }
        let location = convert(event.locationInWindow, from: nil)
        let nextHovered = bounds.contains(location)
        if nextHovered != actionHovered {
            actionHovered = nextHovered
            needsDisplay = true
        }
    }

    // 替换动作在鼠标抬起且仍位于卡片内时提交，拖出卡片可取消误触。
    override func mouseUp(with event: NSEvent) {
        guard actionPressed else { return }
        let location = convert(event.locationInWindow, from: nil)
        let shouldReplace = bounds.contains(location)
        actionPressed = false
        actionHovered = shouldReplace
        needsDisplay = true
        if shouldReplace {
            selectionHandler?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawInteractionState()
        if content.presentation != .translation {
            drawStatusHeader()
        }
        drawBodyText()
        drawAction()
    }

    private func drawInteractionState() {
        guard content.replacementEnabled, actionHovered else { return }
        var interactionColor = NSColor(calibratedWhite: 1, alpha: 0.035)
        if actionPressed {
            interactionColor = TranslationCardStyle.accentColor.withAlphaComponent(0.08)
        }
        interactionColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: TranslationCardStyle.cornerRadius - 1,
            yRadius: TranslationCardStyle.cornerRadius - 1
        ).fill()
    }

    // 只有错误和失效这类例外状态才占用标题行，正常译文保持单行内容卡。
    private func drawStatusHeader() {
        let accentColor = currentAccentColor()
        accentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: 10, width: 5, height: 5)).fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.50),
        ]
        NSString(string: titleText()).draw(
            at: NSPoint(x: 23, y: 6),
            withAttributes: titleAttributes
        )
    }

    private func drawAction() {
        guard content.replacementEnabled else { return }
        if actionHovered {
            var actionColor = TranslationCardStyle.accentColor.withAlphaComponent(0.16)
            if actionPressed {
                actionColor = TranslationCardStyle.accentColor.withAlphaComponent(0.28)
            }
            actionColor.setFill()
            NSBezierPath(roundedRect: actionRect, xRadius: 6, yRadius: 6).fill()
        }
        let actionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: TranslationCardStyle.accentColor,
        ]
        let actionText = NSString(string: "替换")
        let actionWidth = actionText.size(withAttributes: actionAttributes).width
        actionText.draw(
            at: NSPoint(x: actionRect.midX - actionWidth / 2, y: actionRect.minY + 4),
            withAttributes: actionAttributes
        )
    }

    private func drawBodyText() {
        var bodyColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        if content.presentation == .stale {
            bodyColor = NSColor(calibratedWhite: 1, alpha: 0.66)
        }
        if content.presentation == .error {
            bodyColor = NSColor(calibratedWhite: 1, alpha: 0.72)
        }
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: bodyColor,
        ]
        var bodyOriginY: CGFloat = 8
        var bodyHeight: CGFloat = max(bounds.height - 16, 20)
        if content.presentation != .translation {
            bodyOriginY = 24
            bodyHeight = bounds.height - 29
        }
        var trailingInset: CGFloat = 12
        if content.replacementEnabled {
            trailingInset = 76
        }
        NSString(string: content.bodyText).draw(
            with: NSRect(
                x: 12,
                y: bodyOriginY,
                width: max(bounds.width - 12 - trailingInset, 1),
                height: bodyHeight
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: bodyAttributes
        )
    }

    private func titleText() -> String {
        if content.presentation == .stale {
            return "\(content.languagePair) · 原文已变化"
        }
        if content.presentation == .error {
            return "\(content.languagePair) · 翻译错误"
        }
        return content.languagePair
    }

    private func currentAccentColor() -> NSColor {
        if content.presentation == .error {
            return NSColor(calibratedRed: 1, green: 0.46, blue: 0.38, alpha: 1)
        }
        if content.presentation == .stale {
            return NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.22, alpha: 1)
        }
        return TranslationCardStyle.accentColor
    }

    // 正常态以正文和替换入口确定最小宽度，再分档避免译文长度轻微变化时横向跳动。
    private func calculateSize() -> NSSize {
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        ]
        let bodyWidth = NSString(string: content.bodyText).size(withAttributes: bodyAttributes).width
        var actionWidth: CGFloat = 0
        if content.replacementEnabled {
            actionWidth = 64
        }
        var minimumWidth: CGFloat = 136 + actionWidth
        if content.presentation != .translation {
            minimumWidth = 210
        }
        minimumWidth = min(minimumWidth, maximumPanelWidth)
        let preferredWidth = min(
            max(bodyWidth + 24 + actionWidth, minimumWidth),
            maximumPanelWidth
        )
        let panelWidth = stablePanelWidth(
            preferredWidth: preferredWidth,
            minimumWidth: minimumWidth
        )
        let bodyRect = NSString(string: content.bodyText).boundingRect(
            with: NSSize(
                width: max(panelWidth - 24 - actionWidth, 1),
                height: TranslationCardStyle.maximumTranslationBodyHeight
            ),
            options: [.usesLineFragmentOrigin],
            attributes: bodyAttributes
        )
        var panelHeight = min(max(ceil(bodyRect.height) + 16, 36), 96)
        if content.presentation != .translation {
            panelHeight = min(max(ceil(bodyRect.height) + 30, 52), 110)
        }
        return NSSize(width: panelWidth, height: panelHeight)
    }

    // 用有限宽度档位避免译文长度轻微变化时浮层持续横向抖动。
    private func stablePanelWidth(preferredWidth: CGFloat, minimumWidth: CGFloat) -> CGFloat {
        let widthTierList: [CGFloat] = [160, 220, 320, 420, 560, 720, 960]
        for widthTier in widthTierList {
            let resolvedWidth = min(widthTier, maximumPanelWidth)
            if resolvedWidth >= preferredWidth, resolvedWidth >= minimumWidth {
                return resolvedWidth
            }
        }
        return maximumPanelWidth
    }
}
