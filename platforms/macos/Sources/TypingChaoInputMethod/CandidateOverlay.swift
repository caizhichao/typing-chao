import AppKit

// 负责把完整 Rime 快照绘制成紧凑、可点击、可翻页的候选主层。
final class CandidateOverlay {
    private let panel: NSPanel
    private let visualEffectView: NSVisualEffectView
    private let contentView: CandidateBarView

    init() {
        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: 260,
            height: CandidateBarStyle.compactPanelHeight
        )
        contentView = CandidateBarView(frame: initialFrame)
        contentView.autoresizingMask = [.width, .height]

        visualEffectView = NSVisualEffectView(frame: initialFrame)
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = CandidateBarStyle.cornerRadius
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = CandidateBarStyle.borderColor.cgColor
        visualEffectView.layer?.backgroundColor = CandidateBarStyle.panelBackgroundColor.cgColor
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

    // 候选选择统一回到输入控制器执行 librime 动作，视图不直接维护引擎状态。
    func setCandidateSelectionHandler(_ selectionHandler: @escaping (Int) -> Void) {
        contentView.candidateSelectionHandler = selectionHandler
    }

    func setPageHandler(_ pageHandler: @escaping (Bool) -> Void) {
        contentView.pageHandler = pageHandler
    }

    // AI 入口只通知输入控制器打开已有面板，候选视图不直接接管输入会话。
    func setAIInputHandler(_ aiInputHandler: @escaping () -> Void) {
        contentView.aiInputHandler = aiInputHandler
    }

    func setSettingsHandler(_ settingsHandler: @escaping () -> Void) {
        contentView.settingsHandler = settingsHandler
    }

    // 每次 Rime 快照更新时重算布局并锚定真实光标，页面和注释不再由 UI 猜测。
    func show(snapshot: RimeSnapshot, anchor: InputOverlayAnchor) {
        guard snapshot.isComposing, !snapshot.candidateList.isEmpty else {
            hide()
            return
        }
        let panelSize = contentView.update(
            snapshot: snapshot,
            maximumPanelWidth: anchor.availableOverlayWidth
        )
        show(panelSize: panelSize, anchor: anchor)
    }

    // 输入等号时把首位候选切成 AI 入口，等待数字 1、回车或点击确认。
    func showAIInputTrigger(anchor: InputOverlayAnchor) {
        let panelSize = contentView.updateAIInputTrigger(
            maximumPanelWidth: anchor.availableOverlayWidth
        )
        show(panelSize: panelSize, anchor: anchor)
    }

    var visibleFrame: NSRect? {
        if panel.isVisible {
            return panel.frame
        }
        return nil
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show(panelSize: NSSize, anchor: InputOverlayAnchor) {
        visualEffectView.frame = NSRect(origin: .zero, size: panelSize)
        contentView.frame = visualEffectView.bounds
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(anchor.candidateOrigin(for: panelSize))
        panel.orderFrontRegardless()
    }
}

private enum CandidateBarStyle {
    static let compactPanelHeight: CGFloat = 36
    static let commentPanelHeight: CGFloat = 44
    static let maximumPanelWidth: CGFloat = 680
    static let minimumCandidateWidth: CGFloat = 44
    static let cornerRadius: CGFloat = 9
    static let panelBackgroundColor = NSColor(calibratedWhite: 1, alpha: 0.96)
    static let selectedColor = NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1)
    static let hoverColor = NSColor(calibratedWhite: 0, alpha: 0.06)
    static let borderColor = NSColor(calibratedWhite: 0, alpha: 0.16)
    static let primaryTextColor = NSColor(calibratedWhite: 0.14, alpha: 0.94)
    static let secondaryTextColor = NSColor(calibratedWhite: 0.40, alpha: 0.82)
}

// 候选尾部分开分页与 AI/设置操作组，并为页码、间距和分隔线保留真实宽度。
struct CandidateBarTrailingLayout {
    static let candidateGap: CGFloat = 8
    static let pageIndicatorWidth: CGFloat = 18
    static let pageButtonWidth: CGFloat = 24
    static let pageActionGap: CGFloat = 8
    static let separatorWidth: CGFloat = 1
    static let actionGroupGap: CGFloat = 7
    static let actionButtonGap: CGFloat = 4
    static let aiInputButtonWidth: CGFloat = 34
    static let settingsButtonWidth: CGFloat = 28
    static let trailingInset: CGFloat = 8

    let pageIndicatorRect: NSRect
    let previousPageRect: NSRect
    let nextPageRect: NSRect
    let separatorRect: NSRect
    let aiInputButtonRect: NSRect
    let settingsButtonRect: NSRect
    let candidateLimitX: CGFloat

    static func requiredWidth(hasPageControls: Bool) -> CGFloat {
        var requiredWidth = candidateGap + separatorWidth + actionGroupGap + aiInputButtonWidth + actionButtonGap + settingsButtonWidth + trailingInset
        if hasPageControls {
            requiredWidth += pageIndicatorWidth + pageButtonWidth * 2 + pageActionGap
        }
        return requiredWidth
    }

    static func resolve(panelSize: NSSize, hasPageControls: Bool) -> CandidateBarTrailingLayout {
        let settingsButtonRect = NSRect(
            x: panelSize.width - trailingInset - settingsButtonWidth,
            y: (panelSize.height - settingsButtonWidth) / 2,
            width: settingsButtonWidth,
            height: settingsButtonWidth
        )
        let aiInputButtonRect = NSRect(
            x: settingsButtonRect.minX - actionButtonGap - aiInputButtonWidth,
            y: (panelSize.height - aiInputButtonWidth) / 2,
            width: aiInputButtonWidth,
            height: aiInputButtonWidth
        )
        let separatorRect = NSRect(
            x: aiInputButtonRect.minX - actionGroupGap - separatorWidth,
            y: 8,
            width: separatorWidth,
            height: max(panelSize.height - 16, 1)
        )
        guard hasPageControls else {
            return CandidateBarTrailingLayout(
                pageIndicatorRect: .zero,
                previousPageRect: .zero,
                nextPageRect: .zero,
                separatorRect: separatorRect,
                aiInputButtonRect: aiInputButtonRect,
                settingsButtonRect: settingsButtonRect,
                candidateLimitX: separatorRect.minX - candidateGap
            )
        }

        let nextPageRect = NSRect(
            x: separatorRect.minX - pageActionGap - pageButtonWidth,
            y: 0,
            width: pageButtonWidth,
            height: panelSize.height
        )
        let previousPageRect = NSRect(
            x: nextPageRect.minX - pageButtonWidth,
            y: 0,
            width: pageButtonWidth,
            height: panelSize.height
        )
        let pageIndicatorRect = NSRect(
            x: previousPageRect.minX - pageIndicatorWidth,
            y: 0,
            width: pageIndicatorWidth,
            height: panelSize.height
        )
        return CandidateBarTrailingLayout(
            pageIndicatorRect: pageIndicatorRect,
            previousPageRect: previousPageRect,
            nextPageRect: nextPageRect,
            separatorRect: separatorRect,
            aiInputButtonRect: aiInputButtonRect,
            settingsButtonRect: settingsButtonRect,
            candidateLimitX: pageIndicatorRect.minX - candidateGap
        )
    }
}

private final class CandidateBarView: NSView {
    private static let aiInputTriggerCandidate = RimeCandidateItem(
        textValue: "AI",
        labelText: "1",
        commentText: ""
    )
    private let aiInputButton = CandidateAIInputButton()
    private let settingsButton = CandidateSettingsButton()
    private var snapshot = RimeSnapshot(dictionary: [:])
    private var isAIInputTriggerVisible = false
    private var candidateWidthList: [CGFloat] = []
    private var maximumPanelWidth = CandidateBarStyle.maximumPanelWidth
    private var candidateRectList: [NSRect] = []
    private var pageIndicatorRect = NSRect.zero
    private var previousPageRect = NSRect.zero
    private var nextPageRect = NSRect.zero
    private var separatorRect = NSRect.zero
    private var hoveredCandidateIndex: Int?
    private var hoveredPageBackward: Bool?

    var candidateSelectionHandler: ((Int) -> Void)?
    var pageHandler: ((Bool) -> Void)?
    var aiInputHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        aiInputButton.target = self
        aiInputButton.action = #selector(openAIInput(_:))
        settingsButton.target = self
        settingsButton.action = #selector(openSettings(_:))
        addSubview(aiInputButton)
        addSubview(settingsButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 将 Rime 的候选和分页状态一次写入，保证命中区域与本轮绘制完全一致。
    func update(snapshot: RimeSnapshot, maximumPanelWidth: CGFloat) -> NSSize {
        self.snapshot = snapshot
        isAIInputTriggerVisible = false
        self.maximumPanelWidth = min(
            max(maximumPanelWidth, 1),
            CandidateBarStyle.maximumPanelWidth
        )
        candidateWidthList = calculatedCandidateWidthList()
        if let hoveredCandidateIndex,
           !snapshot.candidateList.indices.contains(hoveredCandidateIndex) {
            self.hoveredCandidateIndex = nil
        }
        if !hasPageControls {
            hoveredPageBackward = nil
        }
        let panelSize = calculateSize()
        calculateHitAreas(panelSize: panelSize)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        return panelSize
    }

    // AI 触发候选复用现有候选条布局和点击入口，但不伪造 librime 候选状态。
    func updateAIInputTrigger(maximumPanelWidth: CGFloat) -> NSSize {
        snapshot = RimeSnapshot(dictionary: [:])
        isAIInputTriggerVisible = true
        self.maximumPanelWidth = min(
            max(maximumPanelWidth, 1),
            CandidateBarStyle.maximumPanelWidth
        )
        hoveredCandidateIndex = nil
        hoveredPageBackward = nil
        candidateWidthList = calculatedCandidateWidthList()
        let panelSize = calculateSize()
        calculateHitAreas(panelSize: panelSize)
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
        for candidateRect in candidateRectList {
            addCursorRect(candidateRect, cursor: .pointingHand)
        }
        guard hasPageControls else { return }
        if snapshot.pageNumber > 0 {
            addCursorRect(previousPageRect, cursor: .pointingHand)
        }
        if !snapshot.isLastPage {
            addCursorRect(nextPageRect, cursor: .pointingHand)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let candidateIndex = candidateRectList.firstIndex { $0.contains(location) }
        if candidateIndex != hoveredCandidateIndex {
            hoveredCandidateIndex = candidateIndex
            needsDisplay = true
        }

        var pageBackward: Bool?
        if hasPageControls, snapshot.pageNumber > 0, previousPageRect.contains(location) {
            pageBackward = true
        }
        if hasPageControls, !snapshot.isLastPage, nextPageRect.contains(location) {
            pageBackward = false
        }
        if pageBackward != hoveredPageBackward {
            hoveredPageBackward = pageBackward
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredCandidateIndex = nil
        hoveredPageBackward = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let candidateIndex = candidateRectList.firstIndex(where: { $0.contains(location) }) {
            candidateSelectionHandler?(candidateIndex)
            return
        }
        if hasPageControls, snapshot.pageNumber > 0, previousPageRect.contains(location) {
            pageHandler?(true)
            return
        }
        if hasPageControls, !snapshot.isLastPage, nextPageRect.contains(location) {
            pageHandler?(false)
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (candidateIndex, candidateItem) in displayedCandidateList.enumerated() {
            guard candidateIndex < candidateRectList.count else { break }
            drawCandidate(
                candidateItem,
                index: candidateIndex,
                candidateRect: candidateRectList[candidateIndex]
            )
        }
        drawPageControls()
        drawTrailingSeparator()
    }

    private func drawCandidate(_ candidateItem: RimeCandidateItem, index: Int, candidateRect: NSRect) {
        let isHighlighted = index == displayedHighlightedIndex
        let isHovered = index == hoveredCandidateIndex
        if isHighlighted || isHovered {
            let highlightPath = NSBezierPath(
                roundedRect: candidateRect.insetBy(dx: 1, dy: 3),
                xRadius: 6,
                yRadius: 6
            )
            if isHighlighted {
                CandidateBarStyle.selectedColor.setFill()
            } else {
                CandidateBarStyle.hoverColor.setFill()
            }
            highlightPath.fill()
        }

        if isAIInputTriggerVisible, index == 0 {
            drawAIInputTriggerCandidate(
                candidateRect: candidateRect,
                isHighlighted: isHighlighted
            )
            return
        }

        var labelColor = CandidateBarStyle.secondaryTextColor
        var textColor = CandidateBarStyle.primaryTextColor
        var commentColor = CandidateBarStyle.secondaryTextColor
        var textWeight = NSFont.Weight.regular
        if isHighlighted {
            labelColor = NSColor(calibratedWhite: 1, alpha: 0.86)
            textColor = .white
            commentColor = NSColor(calibratedWhite: 1, alpha: 0.78)
            textWeight = .semibold
        }

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: labelColor,
        ]
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14.5, weight: textWeight),
            .foregroundColor: textColor,
        ]
        let commentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: commentColor,
        ]
        if candidateItem.commentText.isEmpty {
            NSString(string: candidateItem.labelText).draw(
                at: NSPoint(x: candidateRect.minX + 8, y: (candidateRect.height - 13) / 2),
                withAttributes: labelAttributes
            )
            NSString(string: candidateItem.textValue).draw(
                with: NSRect(
                    x: candidateRect.minX + 24,
                    y: (candidateRect.height - 20) / 2,
                    width: candidateRect.width - 31,
                    height: 20
                ),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: textAttributes
            )
            return
        }

        NSString(string: candidateItem.labelText).draw(
            at: NSPoint(x: candidateRect.minX + 8, y: 15),
            withAttributes: labelAttributes
        )
        NSString(string: candidateItem.textValue).draw(
            with: NSRect(
                x: candidateRect.minX + 24,
                y: 7,
                width: candidateRect.width - 31,
                height: 20
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: textAttributes
        )
        NSString(string: candidateItem.commentText).draw(
            with: NSRect(
                x: candidateRect.minX + 24,
                y: 26,
                width: candidateRect.width - 31,
                height: 14
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: commentAttributes
        )
    }

    // 首位 AI 候选同时显示数字标签和星标图形，明确提示可按 1 确认。
    private func drawAIInputTriggerCandidate(candidateRect: NSRect, isHighlighted: Bool) {
        var iconColor = CandidateBarStyle.selectedColor
        var labelColor = CandidateBarStyle.secondaryTextColor
        var textColor = CandidateBarStyle.primaryTextColor
        if isHighlighted {
            iconColor = .white
            labelColor = NSColor(calibratedWhite: 1, alpha: 0.86)
            textColor = .white
        }
        NSString(string: "1").draw(
            at: NSPoint(x: candidateRect.minX + 8, y: 14),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: labelColor,
            ]
        )
        NSString(string: "✦").draw(
            at: NSPoint(x: candidateRect.minX + 25, y: 10),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: iconColor,
            ]
        )
        NSString(string: "AI").draw(
            at: NSPoint(x: candidateRect.minX + 47, y: 10),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: textColor,
            ]
        )
    }

    private func drawPageControls() {
        guard hasPageControls else { return }
        let pageParagraphStyle = NSMutableParagraphStyle()
        pageParagraphStyle.alignment = .center
        let pageAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: CandidateBarStyle.secondaryTextColor,
            .paragraphStyle: pageParagraphStyle,
        ]
        NSString(string: String(snapshot.pageNumber + 1)).draw(
            with: NSRect(
                x: pageIndicatorRect.minX,
                y: (pageIndicatorRect.height - 14) / 2,
                width: pageIndicatorRect.width,
                height: 14
            ),
            options: [.usesLineFragmentOrigin],
            attributes: pageAttributes
        )
        drawPageChevron(backward: true, pageRect: previousPageRect, enabled: snapshot.pageNumber > 0)
        drawPageChevron(backward: false, pageRect: nextPageRect, enabled: !snapshot.isLastPage)
    }

    private func drawPageChevron(backward: Bool, pageRect: NSRect, enabled: Bool) {
        if enabled, hoveredPageBackward == backward {
            CandidateBarStyle.hoverColor.setFill()
            NSBezierPath(roundedRect: pageRect.insetBy(dx: 2, dy: 5), xRadius: 6, yRadius: 6).fill()
        }
        var chevronAlpha = CGFloat(0.20)
        if enabled {
            chevronAlpha = 0.72
        }
        let chevronAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: chevronAlpha),
        ]
        var chevronText = "›"
        if backward {
            chevronText = "‹"
        }
        NSString(string: chevronText).draw(
            at: NSPoint(x: pageRect.minX + 7, y: (pageRect.height - 22) / 2),
            withAttributes: chevronAttributes
        )
    }

    private func drawTrailingSeparator() {
        guard !separatorRect.isEmpty else { return }
        NSColor(calibratedWhite: 0, alpha: 0.12).setFill()
        NSBezierPath(rect: separatorRect).fill()
    }

    private var hasPageControls: Bool {
        snapshot.pageNumber > 0 || !snapshot.isLastPage
    }

    // 候选条仅保留必要的点击宽度和内容边距，单候选时不再预留宽大的空白面板。
    private func calculateSize() -> NSSize {
        let candidateWidth = candidateWidthList.reduce(CGFloat.zero, +)
        let minimumPanelWidth = min(122, maximumPanelWidth)
        let panelWidth = min(
            max(
                candidateWidth + 10 + CandidateBarTrailingLayout.requiredWidth(
                    hasPageControls: hasPageControls
                ),
                minimumPanelWidth
            ),
            maximumPanelWidth
        )
        var panelHeight = CandidateBarStyle.compactPanelHeight
        if displayedCandidateList.contains(where: { !$0.commentText.isEmpty }) {
            panelHeight = CandidateBarStyle.commentPanelHeight
        }
        return NSSize(width: panelWidth, height: panelHeight)
    }

    private func calculateHitAreas(panelSize: NSSize) {
        candidateRectList = []
        var currentX: CGFloat = 10
        let trailingLayout = CandidateBarTrailingLayout.resolve(
            panelSize: panelSize,
            hasPageControls: hasPageControls
        )
        pageIndicatorRect = trailingLayout.pageIndicatorRect
        previousPageRect = trailingLayout.previousPageRect
        nextPageRect = trailingLayout.nextPageRect
        separatorRect = trailingLayout.separatorRect
        aiInputButton.frame = trailingLayout.aiInputButtonRect
        settingsButton.frame = trailingLayout.settingsButtonRect
        let candidateLimitX = trailingLayout.candidateLimitX
        for (candidateIndex, _) in displayedCandidateList.enumerated() {
            guard candidateIndex < candidateWidthList.count else { break }
            let candidateWidth = min(
                candidateWidthList[candidateIndex],
                max(candidateLimitX - currentX, 0)
            )
            guard candidateWidth > 0 else { break }
            candidateRectList.append(NSRect(x: currentX, y: 0, width: candidateWidth, height: panelSize.height))
            currentX += candidateWidth
        }
        guard hasPageControls else {
            pageIndicatorRect = .zero
            previousPageRect = .zero
            nextPageRect = .zero
            return
        }
    }

    // 宽度不足时按候选的理想宽度分配剩余空间，优先保证本页候选不被静默隐藏。
    private func calculatedCandidateWidthList() -> [CGFloat] {
        let idealWidthList = displayedCandidateList.enumerated().map { candidateIndex, candidateItem in
            if isAIInputTriggerVisible, candidateIndex == 0 {
                return CGFloat(90)
            }
            return width(for: candidateItem)
        }
        guard !idealWidthList.isEmpty else { return [] }
        let availableCandidateWidth = max(
            maximumPanelWidth - 10 - CandidateBarTrailingLayout.requiredWidth(
                hasPageControls: hasPageControls
            ),
            1
        )
        let idealWidth = idealWidthList.reduce(CGFloat.zero, +)
        guard idealWidth > availableCandidateWidth else {
            return idealWidthList
        }
        let minimumWidth = CandidateBarStyle.minimumCandidateWidth
        let minimumTotalWidth = minimumWidth * CGFloat(idealWidthList.count)
        if minimumTotalWidth >= availableCandidateWidth {
            let compressedWidth = availableCandidateWidth / CGFloat(idealWidthList.count)
            return idealWidthList.map { _ in compressedWidth }
        }
        let extraWidth = availableCandidateWidth - minimumTotalWidth
        let idealExtraWidth = idealWidthList.reduce(CGFloat.zero) { currentWidth, idealCandidateWidth in
            currentWidth + max(idealCandidateWidth - minimumWidth, 0)
        }
        guard idealExtraWidth > 0 else {
            return idealWidthList.map { _ in availableCandidateWidth / CGFloat(idealWidthList.count) }
        }
        return idealWidthList.map { idealCandidateWidth in
            minimumWidth + extraWidth * max(idealCandidateWidth - minimumWidth, 0) / idealExtraWidth
        }
    }

    private func width(for candidateItem: RimeCandidateItem) -> CGFloat {
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        ]
        let commentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
        ]
        let textWidth = NSString(string: candidateItem.textValue).size(withAttributes: textAttributes).width
        let commentWidth = NSString(string: candidateItem.commentText).size(withAttributes: commentAttributes).width
        return min(max(max(textWidth, commentWidth) + 42, 64), 132)
    }

    private var displayedCandidateList: [RimeCandidateItem] {
        if isAIInputTriggerVisible {
            return [Self.aiInputTriggerCandidate]
        }
        return snapshot.candidateList
    }

    private var displayedHighlightedIndex: Int {
        if isAIInputTriggerVisible {
            return 0
        }
        return snapshot.highlightedIndex
    }

    // AI 按钮只通知输入控制器打开已有面板，不在候选视图中接管输入会话。
    @objc private func openAIInput(_ sender: NSButton) {
        aiInputHandler?()
    }

    @objc private func openSettings(_ sender: NSButton) {
        settingsHandler?()
    }
}

// 候选条 AI 入口使用明确文本，避免把普通候选选择和 AI 面板入口混为一组。
private final class CandidateAIInputButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "AI"
        font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        isBordered = false
        contentTintColor = CandidateBarStyle.secondaryTextColor
        toolTip = "打开 AI 输入"
        setAccessibilityLabel("打开 AI 输入")
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = CandidateBarStyle.hoverColor.cgColor
        contentTintColor = CandidateBarStyle.primaryTextColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = CandidateBarStyle.secondaryTextColor
    }
}

// 使用真实按钮承载候选条设置入口，保证点击、辅助功能标签和悬停反馈不依赖手写命中区。
private final class CandidateSettingsButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "打开 Typing Chao 设置"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        )
        contentTintColor = CandidateBarStyle.secondaryTextColor
        toolTip = "打开设置"
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = CandidateBarStyle.hoverColor.cgColor
        contentTintColor = CandidateBarStyle.primaryTextColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = CandidateBarStyle.secondaryTextColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
