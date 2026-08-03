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
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = CandidateBarStyle.cornerRadius
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = CandidateBarStyle.borderColor.cgColor
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
        visualEffectView.frame = NSRect(origin: .zero, size: panelSize)
        contentView.frame = visualEffectView.bounds
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(anchor.candidateOrigin(for: panelSize))
        panel.orderFrontRegardless()
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
}

private enum CandidateBarStyle {
    static let compactPanelHeight: CGFloat = 40
    static let commentPanelHeight: CGFloat = 48
    static let maximumPanelWidth: CGFloat = 680
    static let minimumCandidateWidth: CGFloat = 44
    static let cornerRadius: CGFloat = 8
    static let selectedColor = NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 0.92)
    static let hoverColor = NSColor(calibratedWhite: 1, alpha: 0.08)
    static let borderColor = NSColor(calibratedWhite: 1, alpha: 0.16)
}

private final class CandidateBarView: NSView {
    private var snapshot = RimeSnapshot(dictionary: [:])
    private var candidateWidthList: [CGFloat] = []
    private var maximumPanelWidth = CandidateBarStyle.maximumPanelWidth
    private var candidateRectList: [NSRect] = []
    private var previousPageRect = NSRect.zero
    private var nextPageRect = NSRect.zero
    private var hoveredCandidateIndex: Int?
    private var hoveredPageBackward: Bool?

    var candidateSelectionHandler: ((Int) -> Void)?
    var pageHandler: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    // 将 Rime 的候选和分页状态一次写入，保证命中区域与本轮绘制完全一致。
    func update(snapshot: RimeSnapshot, maximumPanelWidth: CGFloat) -> NSSize {
        self.snapshot = snapshot
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
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (candidateIndex, candidateItem) in snapshot.candidateList.enumerated() {
            guard candidateIndex < candidateRectList.count else { break }
            drawCandidate(
                candidateItem,
                index: candidateIndex,
                candidateRect: candidateRectList[candidateIndex]
            )
        }
        drawPageControls()
    }

    private func drawCandidate(_ candidateItem: RimeCandidateItem, index: Int, candidateRect: NSRect) {
        let isHighlighted = index == snapshot.highlightedIndex
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

        var labelColor = NSColor(calibratedWhite: 1, alpha: 0.42)
        var textColor = NSColor(calibratedWhite: 1, alpha: 0.84)
        var commentColor = NSColor(calibratedWhite: 1, alpha: 0.38)
        var textWeight = NSFont.Weight.regular
        if isHighlighted {
            labelColor = NSColor(calibratedWhite: 1, alpha: 0.86)
            textColor = .white
            commentColor = NSColor(calibratedWhite: 1, alpha: 0.64)
            textWeight = .semibold
        }

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: labelColor,
        ]
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: textWeight),
            .foregroundColor: textColor,
        ]
        let commentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: commentColor,
        ]
        if candidateItem.commentText.isEmpty {
            NSString(string: candidateItem.labelText).draw(
                at: NSPoint(x: candidateRect.minX + 8, y: 14),
                withAttributes: labelAttributes
            )
            NSString(string: candidateItem.textValue).draw(
                with: NSRect(
                    x: candidateRect.minX + 24,
                    y: 10,
                    width: candidateRect.width - 31,
                    height: 20
                ),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: textAttributes
            )
            return
        }

        NSString(string: candidateItem.labelText).draw(
            at: NSPoint(x: candidateRect.minX + 8, y: 16),
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

    private func drawPageControls() {
        guard hasPageControls else { return }
        let pageAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.46),
        ]
        NSString(string: String(snapshot.pageNumber + 1)).draw(
            at: NSPoint(x: previousPageRect.minX - 18, y: 13),
            withAttributes: pageAttributes
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
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: chevronAlpha),
        ]
        var chevronText = "›"
        if backward {
            chevronText = "‹"
        }
        NSString(string: chevronText).draw(
            at: NSPoint(x: pageRect.minX + 8, y: 9),
            withAttributes: chevronAttributes
        )
    }

    private var hasPageControls: Bool {
        snapshot.pageNumber > 0 || !snapshot.isLastPage
    }

    // 候选条仅保留必要的点击宽度和内容边距，单候选时不再预留宽大的空白面板。
    private func calculateSize() -> NSSize {
        let candidateWidth = candidateWidthList.reduce(CGFloat.zero, +)
        let controlWidth = pageControlWidth
        let minimumPanelWidth = min(84, maximumPanelWidth)
        let panelWidth = min(
            max(candidateWidth + 20 + controlWidth, minimumPanelWidth),
            maximumPanelWidth
        )
        var panelHeight = CandidateBarStyle.compactPanelHeight
        if snapshot.candidateList.contains(where: { !$0.commentText.isEmpty }) {
            panelHeight = CandidateBarStyle.commentPanelHeight
        }
        return NSSize(width: panelWidth, height: panelHeight)
    }

    private func calculateHitAreas(panelSize: NSSize) {
        candidateRectList = []
        var currentX: CGFloat = 10
        var trailingInset: CGFloat = 10
        if hasPageControls {
            trailingInset = 58
        }
        let candidateLimitX = panelSize.width - trailingInset
        for (candidateIndex, _) in snapshot.candidateList.enumerated() {
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
            previousPageRect = .zero
            nextPageRect = .zero
            return
        }
        previousPageRect = NSRect(x: panelSize.width - 52, y: 0, width: 26, height: panelSize.height)
        nextPageRect = NSRect(x: panelSize.width - 26, y: 0, width: 26, height: panelSize.height)
    }

    private var pageControlWidth: CGFloat {
        if hasPageControls {
            return 58
        }
        return 10
    }

    // 宽度不足时按候选的理想宽度分配剩余空间，优先保证本页候选不被静默隐藏。
    private func calculatedCandidateWidthList() -> [CGFloat] {
        let idealWidthList = snapshot.candidateList.map { width(for: $0) }
        guard !idealWidthList.isEmpty else { return [] }
        let availableCandidateWidth = max(
            maximumPanelWidth - 20 - pageControlWidth,
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
}
