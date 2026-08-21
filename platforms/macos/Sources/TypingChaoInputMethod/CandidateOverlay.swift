import AppKit

// Swift 原生候选条：彻底移除 WKWebView，复刻 CandidateApp.tsx + styles.css 的横向候选与日期/时间扩展。
final class CandidateOverlay {
    private let panel: NSPanel
    private let contentView: CandidateBarNativeView

    private var candidateSelectionHandler: ((Int) -> Void)?
    private var specialInputExpansionHandler: (() -> Void)?
    private var pageHandler: ((Bool) -> Void)?
    private var settingsHandler: (() -> Void)?

    init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 260, height: CandidateBarStyle.compactPanelHeight)
        let barView = CandidateBarNativeView(frame: initialFrame)
        barView.autoresizingMask = [.width, .height]

        let panel = NSPanel(
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
        // 使用视觉效果容器承载原生候选，避免 WebView
        let effectView = NSVisualEffectView(frame: initialFrame)
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 9
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]
        effectView.addSubview(barView)
        panel.contentView = effectView
        self.panel = panel
        self.contentView = barView

        barView.candidateSelectionHandler = { [weak self] idx in self?.candidateSelectionHandler?(idx) }
        barView.specialInputExpansionHandler = { [weak self] in self?.specialInputExpansionHandler?() }
        barView.pageHandler = { [weak self] backward in self?.pageHandler?(backward) }
        barView.settingsHandler = { [weak self] in self?.settingsHandler?() }
    }

    func setCandidateSelectionHandler(_ h: @escaping (Int) -> Void) { candidateSelectionHandler = h }
    func setSpecialInputExpansionHandler(_ h: @escaping () -> Void) { specialInputExpansionHandler = h }
    func setPageHandler(_ h: @escaping (Bool) -> Void) { pageHandler = h }
    func setSettingsHandler(_ h: @escaping () -> Void) { settingsHandler = h }

    func show(snapshot: RimeSnapshot, anchor: InputOverlayAnchor) {
        guard snapshot.isComposing, !snapshot.candidateList.isEmpty else { hide(); return }
        let state = CandidateBarState(snapshot: snapshot, maximumPanelWidth: anchor.availableOverlayWidth, isAIInputTriggerVisible: false)
        show(state: state, anchor: anchor)
    }

    func show(candidates: [RimeCandidateItem], highlightedIndex: Int, specialInputExpansionKind: SpecialInputExpansionKind, anchor: InputOverlayAnchor) {
        guard !candidates.isEmpty else { hide(); return }
        let state = CandidateBarState(candidateList: candidates, highlightedIndex: highlightedIndex, maximumPanelWidth: anchor.availableOverlayWidth, specialInputExpansionKind: specialInputExpansionKind)
        show(state: state, anchor: anchor)
    }

    func showAIInputTrigger(anchor: InputOverlayAnchor) {
        let state = CandidateBarState(snapshot: RimeSnapshot(dictionary: [:]), maximumPanelWidth: anchor.availableOverlayWidth, isAIInputTriggerVisible: true)
        show(state: state, anchor: anchor)
    }

    var visibleFrame: NSRect? { panel.isVisible ? panel.frame : nil }

    func hide() { panel.orderOut(nil) }

    private func show(state: CandidateBarState, anchor: InputOverlayAnchor) {
        let panelSize = state.panelSize
        contentView.update(state: state)
        contentView.frame = NSRect(origin: .zero, size: panelSize)
        if let effectView = panel.contentView as? NSVisualEffectView {
            effectView.frame = NSRect(origin: .zero, size: panelSize)
            // 保持 barView 填充
            contentView.frame = effectView.bounds
        }
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(anchor.candidateOrigin(for: panelSize))
        panel.orderFrontRegardless()
    }
}

// MARK: - Style

private enum CandidateBarStyle {
    static let compactPanelHeight: CGFloat = 36
    static let commentPanelHeight: CGFloat = 44
    static let maximumPanelWidth: CGFloat = 680
    static let minimumCandidateWidth: CGFloat = 44
    static let horizontalInset: CGFloat = 10
}

struct CandidateBarTrailingLayout {
    static let candidateGap: CGFloat = 8
    static let pageIndicatorWidth: CGFloat = 18
    static let pageButtonWidth: CGFloat = 24
    static let pageActionGap: CGFloat = 8
    static let separatorWidth: CGFloat = 1
    static let actionGroupGap: CGFloat = 7
    static let settingsButtonWidth: CGFloat = 28
    static let trailingInset: CGFloat = 8

    let pageIndicatorRect: NSRect
    let previousPageRect: NSRect
    let nextPageRect: NSRect
    let separatorRect: NSRect
    let settingsButtonRect: NSRect
    let candidateLimitX: CGFloat

    static func requiredWidth(hasPageControls: Bool) -> CGFloat {
        var w = candidateGap + separatorWidth + actionGroupGap + settingsButtonWidth + trailingInset
        if hasPageControls { w += pageIndicatorWidth + pageButtonWidth * 2 + pageActionGap }
        return w
    }

    static func resolve(panelSize: NSSize, hasPageControls: Bool) -> CandidateBarTrailingLayout {
        let settingsButtonRect = NSRect(x: panelSize.width - trailingInset - settingsButtonWidth, y: (panelSize.height - settingsButtonWidth)/2, width: settingsButtonWidth, height: settingsButtonWidth)
        let separatorRect = NSRect(x: settingsButtonRect.minX - actionGroupGap - separatorWidth, y: 8, width: separatorWidth, height: max(panelSize.height - 16, 1))
        guard hasPageControls else {
            return CandidateBarTrailingLayout(pageIndicatorRect: .zero, previousPageRect: .zero, nextPageRect: .zero, separatorRect: separatorRect, settingsButtonRect: settingsButtonRect, candidateLimitX: separatorRect.minX - candidateGap)
        }
        let nextPageRect = NSRect(x: separatorRect.minX - pageActionGap - pageButtonWidth, y: 0, width: pageButtonWidth, height: panelSize.height)
        let previousPageRect = NSRect(x: nextPageRect.minX - pageButtonWidth, y: 0, width: pageButtonWidth, height: panelSize.height)
        let pageIndicatorRect = NSRect(x: previousPageRect.minX - pageIndicatorWidth, y: 0, width: pageIndicatorWidth, height: panelSize.height)
        return CandidateBarTrailingLayout(pageIndicatorRect: pageIndicatorRect, previousPageRect: previousPageRect, nextPageRect: nextPageRect, separatorRect: separatorRect, settingsButtonRect: settingsButtonRect, candidateLimitX: pageIndicatorRect.minX - candidateGap)
    }
}

// MARK: - State (复刻 CandidateWebState 的宽度与面板计算，去除 Web 消息)

struct CandidateBarState {
    private static let aiInputTriggerCandidate = RimeCandidateItem(textValue: "AI", labelText: "1", commentText: "")
    let candidateList: [CandidateBarItem]
    let highlightedIndex: Int
    let isAIInputTriggerVisible: Bool
    let isSpecialInputExpansionVisible: Bool
    let specialInputExpansionTitle: String
    let isSpecialInputExpansionTriggerVisible: Bool
    let specialInputExpansionTriggerInsertIndex: Int
    let specialInputExpansionTriggerLabelText: String
    let specialInputExpansionTriggerText: String
    let specialInputExpansionTriggerWidthPoint: CGFloat
    let hasPageControls: Bool
    let pageText: String
    let isPreviousPageEnabled: Bool
    let isNextPageEnabled: Bool
    let panelSize: NSSize

    init(snapshot: RimeSnapshot, maximumPanelWidth: CGFloat, isAIInputTriggerVisible: Bool) {
        let displayedList: [RimeCandidateItem]
        if isAIInputTriggerVisible { displayedList = [Self.aiInputTriggerCandidate] } else { displayedList = snapshot.candidateList }
        let triggerKind: SpecialInputExpansionKind?
        if isAIInputTriggerVisible { triggerKind = nil } else { triggerKind = SpecialInputExpansionCatalog.kind(for: snapshot) }
        self.init(candidateList: displayedList, highlightedIndex: isAIInputTriggerVisible ? 0 : snapshot.highlightedIndex, maximumPanelWidth: maximumPanelWidth, isAIInputTriggerVisible: isAIInputTriggerVisible, specialInputExpansionKind: nil, specialInputExpansionTriggerKind: triggerKind, hasPageControls: !isAIInputTriggerVisible && (snapshot.pageNumber > 0 || !snapshot.isLastPage), pageText: !isAIInputTriggerVisible && (snapshot.pageNumber > 0 || !snapshot.isLastPage) ? "\(snapshot.pageNumber + 1)" : "", isPreviousPageEnabled: !isAIInputTriggerVisible && snapshot.pageNumber > 0, isNextPageEnabled: !isAIInputTriggerVisible && !snapshot.isLastPage)
    }

    init(candidateList: [RimeCandidateItem], highlightedIndex: Int, maximumPanelWidth: CGFloat, specialInputExpansionKind: SpecialInputExpansionKind? = nil) {
        self.init(candidateList: candidateList, highlightedIndex: highlightedIndex, maximumPanelWidth: maximumPanelWidth, isAIInputTriggerVisible: false, specialInputExpansionKind: specialInputExpansionKind, specialInputExpansionTriggerKind: nil, hasPageControls: false, pageText: "", isPreviousPageEnabled: false, isNextPageEnabled: false)
    }

    private init(candidateList displayedCandidateList: [RimeCandidateItem], highlightedIndex requestedHighlightedIndex: Int, maximumPanelWidth: CGFloat, isAIInputTriggerVisible: Bool, specialInputExpansionKind: SpecialInputExpansionKind?, specialInputExpansionTriggerKind: SpecialInputExpansionKind?, hasPageControls: Bool, pageText: String, isPreviousPageEnabled: Bool, isNextPageEnabled: Bool) {
        self.isAIInputTriggerVisible = isAIInputTriggerVisible
        self.isSpecialInputExpansionVisible = specialInputExpansionKind != nil
        self.specialInputExpansionTitle = specialInputExpansionKind?.displayTitle ?? ""
        self.hasPageControls = hasPageControls
        self.pageText = pageText
        self.isPreviousPageEnabled = isPreviousPageEnabled
        self.isNextPageEnabled = isNextPageEnabled
        let specialTriggerIndex = specialInputExpansionTriggerKind.flatMap { kind in displayedCandidateList.firstIndex { $0.textValue == kind.triggerText } }
        self.isSpecialInputExpansionTriggerVisible = specialTriggerIndex != nil
        self.specialInputExpansionTriggerInsertIndex = specialTriggerIndex ?? -1
        self.specialInputExpansionTriggerLabelText = specialTriggerIndex.map { String($0 + 2) } ?? ""
        self.specialInputExpansionTriggerText = specialInputExpansionTriggerKind?.triggerText ?? ""
        if let kind = specialInputExpansionTriggerKind {
            self.specialInputExpansionTriggerWidthPoint = Self.width(for: RimeCandidateItem(textValue: "▦ \(kind.triggerText)", labelText: "", commentText: ""))
        } else { self.specialInputExpansionTriggerWidthPoint = 0 }
        let boundedMaximumWidth = min(max(maximumPanelWidth, 1), CandidateBarStyle.maximumPanelWidth)
        let widthList = Self.resolveCandidateWidthList(candidateList: displayedCandidateList, maximumPanelWidth: boundedMaximumWidth, hasPageControls: hasPageControls, isAIInputTriggerVisible: isAIInputTriggerVisible, reservedWidth: self.specialInputExpansionTriggerWidthPoint)
        self.candidateList = displayedCandidateList.enumerated().map { idx, item in CandidateBarItem(labelText: item.labelText, textValue: item.textValue, commentText: item.commentText, widthPoint: widthList[idx]) }
        if isAIInputTriggerVisible { self.highlightedIndex = 0 } else if displayedCandidateList.indices.contains(requestedHighlightedIndex) { self.highlightedIndex = requestedHighlightedIndex } else { self.highlightedIndex = -1 }
        let panelHeight: CGFloat
        if specialInputExpansionKind != nil { panelHeight = CGFloat(displayedCandidateList.count * 30 + 12) }
        else if displayedCandidateList.contains(where: { !$0.commentText.isEmpty }) { panelHeight = CandidateBarStyle.commentPanelHeight }
        else { panelHeight = CandidateBarStyle.compactPanelHeight }
        if specialInputExpansionKind != nil {
            let widest = widthList.max() ?? CandidateBarStyle.minimumCandidateWidth
            panelSize = NSSize(width: min(boundedMaximumWidth, max(widest + 36, 220)), height: panelHeight)
        } else {
            let preferred = widthList.reduce(CandidateBarStyle.horizontalInset, +) + specialInputExpansionTriggerWidthPoint + CandidateBarTrailingLayout.requiredWidth(hasPageControls: hasPageControls)
            let minimum = CandidateBarStyle.minimumCandidateWidth + CandidateBarStyle.horizontalInset + specialInputExpansionTriggerWidthPoint + CandidateBarTrailingLayout.requiredWidth(hasPageControls: hasPageControls)
            panelSize = NSSize(width: min(boundedMaximumWidth, max(preferred, minimum)), height: panelHeight)
        }
    }

    private static func resolveCandidateWidthList(candidateList: [RimeCandidateItem], maximumPanelWidth: CGFloat, hasPageControls: Bool, isAIInputTriggerVisible: Bool, reservedWidth: CGFloat) -> [CGFloat] {
        let ideal = candidateList.enumerated().map { idx, item in
            if isAIInputTriggerVisible, idx == 0 { return CGFloat(90) }
            return width(for: item)
        }
        guard !ideal.isEmpty else { return [] }
        let available = max(maximumPanelWidth - CandidateBarStyle.horizontalInset - CandidateBarTrailingLayout.requiredWidth(hasPageControls: hasPageControls) - reservedWidth, 1)
        let idealWidth = ideal.reduce(0, +)
        guard idealWidth > available else { return ideal }
        let minW = CandidateBarStyle.minimumCandidateWidth
        let minTotal = minW * CGFloat(ideal.count)
        if minTotal >= available { return ideal.map { _ in available / CGFloat(ideal.count) } }
        let extra = available - minTotal
        let idealExtra = ideal.reduce(0) { $0 + max($1 - minW, 0) }
        guard idealExtra > 0 else { return ideal.map { _ in available / CGFloat(ideal.count) } }
        return ideal.map { minW + extra * max($0 - minW, 0) / idealExtra }
    }

    private static func width(for item: RimeCandidateItem) -> CGFloat {
        let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .regular)]
        let commentAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .regular)]
        let tw = NSString(string: item.textValue).size(withAttributes: textAttrs).width
        let cw = NSString(string: item.commentText).size(withAttributes: commentAttrs).width
        return min(max(max(tw, cw) + 42, 64), 132)
    }
}

struct CandidateBarItem {
    let labelText: String
    let textValue: String
    let commentText: String
    let widthPoint: CGFloat
}

// MARK: - Native View (AppKit 自绘，支持 hover/点击/翻页/设置)

private final class CandidateBarNativeView: NSView {
    var candidateSelectionHandler: ((Int) -> Void)?
    var specialInputExpansionHandler: (() -> Void)?
    var pageHandler: ((Bool) -> Void)?
    var settingsHandler: (() -> Void)?

    private var state: CandidateBarState?
    private var candidateFrames: [NSRect] = []
    private var specialTriggerFrame: NSRect?
    private var trailingLayout: CandidateBarTrailingLayout?
    private var hoveredCandidateIndex: Int?
    private var pressedCandidateIndex: Int?
    private var hoveredSpecialTrigger = false
    private var pressedSpecialTrigger = false
    private var hoveredTrailing: TrailingAction?
    private var pressedTrailing: TrailingAction?
    private var trackingArea: NSTrackingArea?

    private enum TrailingAction { case prevPage, nextPage, settings, specialTrigger }

    override var wantsUpdateLayer: Bool { false }
    override var isFlipped: Bool { false }

    func update(state: CandidateBarState) {
        self.state = state
        recomputeLayout()
        needsDisplay = true
    }

    private func recomputeLayout() {
        guard let state else { candidateFrames = []; specialTriggerFrame = nil; trailingLayout = nil; return }
        if state.isSpecialInputExpansionVisible {
            // 垂直扩展：每项高度 30，间隙 1，内边距 6
            var frames: [NSRect] = []
            let w = state.panelSize.width - 12
            for idx in 0..<state.candidateList.count {
                let y = state.panelSize.height - 6 - CGFloat(idx + 1) * 30 - CGFloat(idx) * 1
                frames.append(NSRect(x: 6, y: y, width: w, height: 30))
            }
            candidateFrames = frames
            specialTriggerFrame = nil
            trailingLayout = nil
            return
        }
        // 横向候选
        trailingLayout = CandidateBarTrailingLayout.resolve(panelSize: state.panelSize, hasPageControls: state.hasPageControls)
        var frames: [NSRect] = []
        var x = CandidateBarStyle.horizontalInset
        // 为保持与旧 CSS 的 5px 左内边距对齐，实际从 5 开始
        x = 5
        for (idx, item) in state.candidateList.enumerated() {
            let f = NSRect(x: x, y: 3, width: item.widthPoint, height: state.panelSize.height - 6)
            frames.append(f)
            x += item.widthPoint
            if state.isSpecialInputExpansionTriggerVisible && idx == state.specialInputExpansionTriggerInsertIndex {
                let sf = NSRect(x: x, y: 3, width: state.specialInputExpansionTriggerWidthPoint, height: state.panelSize.height - 6)
                specialTriggerFrame = sf
                x += state.specialInputExpansionTriggerWidthPoint
            }
        }
        if !state.isSpecialInputExpansionTriggerVisible { specialTriggerFrame = nil }
        candidateFrames = frames
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { clearHover() }
    private func clearHover() {
        hoveredCandidateIndex = nil; hoveredSpecialTrigger = false; hoveredTrailing = nil; needsDisplay = true
        NSCursor.arrow.set()
    }
    private func updateHover(at point: NSPoint) {
        guard let state else { return }
        if state.isSpecialInputExpansionVisible {
            var idx: Int? = nil
            for (i, f) in candidateFrames.enumerated() where f.contains(point) { idx = i; break }
            if idx != hoveredCandidateIndex { hoveredCandidateIndex = idx; needsDisplay = true }
            hoveredSpecialTrigger = false; hoveredTrailing = nil
            if idx != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            return
        }
        // 横向
        var cIdx: Int? = nil
        for (i, f) in candidateFrames.enumerated() where f.contains(point) { cIdx = i; break }
        var sHover = false
        if let sf = specialTriggerFrame, sf.contains(point) { sHover = true; cIdx = nil }
        var tHover: TrailingAction? = nil
        if let tl = trailingLayout {
            if tl.settingsButtonRect.contains(point) { tHover = .settings }
            else if tl.previousPageRect.contains(point) && state.hasPageControls { tHover = .prevPage }
            else if tl.nextPageRect.contains(point) && state.hasPageControls { tHover = .nextPage }
        }
        let changed = cIdx != hoveredCandidateIndex || sHover != hoveredSpecialTrigger || tHover != hoveredTrailing
        hoveredCandidateIndex = cIdx
        hoveredSpecialTrigger = sHover
        hoveredTrailing = tHover
        if changed { needsDisplay = true }
        if cIdx != nil || sHover || tHover != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateHover(at: pt)
        pressedCandidateIndex = hoveredCandidateIndex
        pressedSpecialTrigger = hoveredSpecialTrigger
        pressedTrailing = hoveredTrailing
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateHover(at: pt)
        defer { pressedCandidateIndex = nil; pressedSpecialTrigger = false; pressedTrailing = nil; needsDisplay = true }
        if let idx = pressedCandidateIndex, idx == hoveredCandidateIndex {
            candidateSelectionHandler?(idx)
            return
        }
        if pressedSpecialTrigger && hoveredSpecialTrigger {
            specialInputExpansionHandler?()
            return
        }
        guard let pressed = pressedTrailing, pressed == hoveredTrailing else { return }
        switch pressed {
        case .settings: settingsHandler?()
        case .prevPage: if state?.isPreviousPageEnabled == true { pageHandler?(true) }
        case .nextPage: if state?.isNextPageEnabled == true { pageHandler?(false) }
        case .specialTrigger: break
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let state else { return }
        // 背景由 NSVisualEffectView 承载，这里只绘制内容；为保持圆角，裁切
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSColor.clear.setFill(); bgPath.fill()

        if state.isSpecialInputExpansionVisible {
            drawSpecialExpansion(state: state)
            return
        }
        drawCandidateBar(state: state)
    }

    private func drawSpecialExpansion(state: CandidateBarState) {
        for (idx, frame) in candidateFrames.enumerated() {
            let isHighlighted = idx == state.highlightedIndex
            let isHovered = idx == hoveredCandidateIndex
            let isPressed = idx == pressedCandidateIndex && isHovered
            drawSpecialItem(frame: frame, label: state.candidateList[idx].labelText, text: state.candidateList[idx].textValue, isHighlighted: isHighlighted, isHovered: isHovered, isPressed: isPressed)
        }
    }

    private func drawSpecialItem(frame: NSRect, label: String, text: String, isHighlighted: Bool, isHovered: Bool, isPressed: Bool) {
        let accent = NSColor(calibratedRed: 0.031, green: 0.667, blue: 0.584, alpha: 1)
        let bg: NSColor
        if isHighlighted { bg = accent }
        else if isPressed { bg = NSColor(calibratedWhite: 0, alpha: 0.08) }
        else if isHovered { bg = NSColor(calibratedWhite: 0, alpha: 0.06) }
        else { bg = .clear }
        bg.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5).fill()

        // label 26px 居中
        let labelRect = NSRect(x: frame.minX, y: frame.minY, width: 26, height: frame.height)
        let labelColor: NSColor = isHighlighted ? NSColor(white: 1, alpha: 0.82) : NSColor(calibratedWhite: 0.48, alpha: 1)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: labelColor]
        let labelSize = NSString(string: label).size(withAttributes: labelAttrs)
        NSString(string: label).draw(at: NSPoint(x: labelRect.midX - labelSize.width/2, y: labelRect.midY - labelSize.height/2), withAttributes: labelAttrs)

        let textColor: NSColor = isHighlighted ? .white : NSColor(calibratedWhite: 0.19, alpha: 1)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: textColor]
        // 文本左起 26
        let textX = frame.minX + 26
        let textW = frame.width - 26 - 8
        let textStr = NSString(string: text)
        let textSize = textStr.size(withAttributes: textAttrs)
        let drawRect = NSRect(x: textX, y: frame.midY - textSize.height/2, width: textW, height: textSize.height)
        textStr.draw(with: drawRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: textAttrs)
    }

    private func drawCandidateBar(state: CandidateBarState) {
        let accent = NSColor(calibratedRed: 0.031, green: 0.667, blue: 0.584, alpha: 1)
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // 绘制候选
        for (idx, frame) in candidateFrames.enumerated() {
            let isHighlighted = idx == state.highlightedIndex
            let isAI = state.isAIInputTriggerVisible && idx == 0
            let isHovered = idx == hoveredCandidateIndex
            let isPressed = idx == pressedCandidateIndex && isHovered
            let bg: NSColor
            if isHighlighted { bg = accent }
            else if isPressed { bg = NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.12 : 0.08) }
            else if isHovered { bg = NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.1 : 0.12) }
            else { bg = .clear }
            bg.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()

            // label 16
            let label = state.candidateList[idx].labelText
            let labelColor: NSColor = isHighlighted ? NSColor(white: 1, alpha: 0.84) : NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.48 : 0.48)
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: labelColor]
            let labelSize = NSString(string: label).size(withAttributes: labelAttrs)
            let labelRect = NSRect(x: frame.minX, y: frame.minY, width: 16, height: frame.height)
            NSString(string: label).draw(at: NSPoint(x: labelRect.midX - labelSize.width/2, y: labelRect.midY - labelSize.height/2), withAttributes: labelAttrs)

            if isAI {
                // AI 标记
                let markAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: isHighlighted ? NSColor.white : accent]
                let markSize = NSString(string: "✦").size(withAttributes: markAttrs)
                let markRect = NSRect(x: frame.minX + 16, y: frame.minY, width: 22, height: frame.height)
                NSString(string: "✦").draw(at: NSPoint(x: markRect.midX - markSize.width/2, y: markRect.midY - markSize.height/2), withAttributes: markAttrs)
                let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14.5, weight: .medium), .foregroundColor: isHighlighted ? NSColor.white : (isDark ? NSColor(white: 1, alpha: 0.92) : NSColor(calibratedWhite: 0.08, alpha: 0.92))]
                let textSize = NSString(string: "AI").size(withAttributes: textAttrs)
                let textX = frame.minX + 16 + 22
                NSString(string: "AI").draw(at: NSPoint(x: textX, y: frame.midY - textSize.height/2), withAttributes: textAttrs)
                continue
            }

            let hasComment = !state.candidateList[idx].commentText.isEmpty
            let textColor: NSColor = isHighlighted ? .white : (isDark ? NSColor(white: 1, alpha: 0.92) : NSColor(calibratedWhite: 0.08, alpha: 0.92))
            let commentColor: NSColor = isHighlighted ? NSColor(white: 1, alpha: 0.78) : NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.42 : 0.48)
            if hasComment {
                let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: textColor]
                let commentAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: commentColor]
                let textStr = state.candidateList[idx].textValue
                let commentStr = state.candidateList[idx].commentText
                let textSize = NSString(string: textStr).size(withAttributes: textAttrs)
                let commentSize = NSString(string: commentStr).size(withAttributes: commentAttrs)
                let textX = frame.minX + 16 + 3
                let availableW = frame.width - 16 - 7
                // 上行文本
                let upperY = frame.midY + 1
                NSString(string: textStr).draw(with: NSRect(x: textX, y: upperY, width: availableW, height: textSize.height), options: [.truncatesLastVisibleLine], attributes: textAttrs)
                // 下行注释
                let lowerY = frame.midY - commentSize.height - 1
                NSString(string: commentStr).draw(with: NSRect(x: textX, y: lowerY, width: availableW, height: commentSize.height), options: [.truncatesLastVisibleLine], attributes: commentAttrs)
            } else {
                let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14.5, weight: .medium), .foregroundColor: textColor]
                let textStr = state.candidateList[idx].textValue
                let textSize = NSString(string: textStr).size(withAttributes: textAttrs)
                let textX = frame.minX + 16 + 3
                let availableW = frame.width - 16 - 7
                let drawRect = NSRect(x: textX, y: frame.midY - textSize.height/2, width: availableW, height: textSize.height)
                NSString(string: textStr).draw(with: drawRect, options: [.truncatesLastVisibleLine], attributes: textAttrs)
            }
        }
        // 特殊触发按钮
        if let sf = specialTriggerFrame, state.isSpecialInputExpansionTriggerVisible {
            let isHovered = hoveredSpecialTrigger
            let isPressed = pressedSpecialTrigger && isHovered
            let bg: NSColor = isPressed ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.12 : 0.08) : isHovered ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.1 : 0.12) : .clear
            bg.setFill()
            NSBezierPath(roundedRect: sf, xRadius: 6, yRadius: 6).fill()
            let label = state.specialInputExpansionTriggerLabelText
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.48)]
            let labelSize = NSString(string: label).size(withAttributes: labelAttrs)
            let labelRect = NSRect(x: sf.minX, y: sf.minY, width: 16, height: sf.height)
            NSString(string: label).draw(at: NSPoint(x: labelRect.midX - labelSize.width/2, y: labelRect.midY - labelSize.height/2), withAttributes: labelAttrs)
            let iconAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.55)]
            let iconSize = NSString(string: "▦").size(withAttributes: iconAttrs)
            let iconRect = NSRect(x: sf.minX + 16, y: sf.minY, width: 18, height: sf.height)
            NSString(string: "▦").draw(at: NSPoint(x: iconRect.midX - iconSize.width/2, y: iconRect.midY - iconSize.height/2), withAttributes: iconAttrs)
            let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: isDark ? NSColor(white: 1, alpha: 0.88) : NSColor(calibratedWhite: 0.15, alpha: 1)]
            let textStr = state.specialInputExpansionTriggerText
            let textSize = NSString(string: textStr).size(withAttributes: textAttrs)
            NSString(string: textStr).draw(at: NSPoint(x: sf.minX + 16 + 18, y: sf.midY - textSize.height/2), withAttributes: textAttrs)
        }
        // 尾部
        guard let tl = trailingLayout else { return }
        // 分隔线
        let sepColor = NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.12 : 0.14)
        sepColor.setFill()
        NSBezierPath(rect: tl.separatorRect).fill()
        // 页码
        if state.hasPageControls {
            let pageAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.55)]
            let pageSize = NSString(string: state.pageText).size(withAttributes: pageAttrs)
            NSString(string: state.pageText).draw(at: NSPoint(x: tl.pageIndicatorRect.midX - pageSize.width/2, y: tl.pageIndicatorRect.midY - pageSize.height/2), withAttributes: pageAttrs)
            // 上一页
            let prevHovered = hoveredTrailing == .prevPage
            let prevPressed = pressedTrailing == .prevPage && prevHovered
            let prevEnabled = state.isPreviousPageEnabled
            let prevBg: NSColor = prevPressed ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.12) : prevHovered && prevEnabled ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.08) : .clear
            if prevHovered && prevEnabled { prevBg.setFill(); NSBezierPath(roundedRect: tl.previousPageRect.insetBy(dx: 2, dy: 4), xRadius: 4, yRadius: 4).fill() }
            let prevColor: NSColor = prevEnabled ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.7) : NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.25)
            let prevAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .regular), .foregroundColor: prevColor]
            let prevStr = "‹"
            let prevSize = NSString(string: prevStr).size(withAttributes: prevAttrs)
            NSString(string: prevStr).draw(at: NSPoint(x: tl.previousPageRect.midX - prevSize.width/2, y: tl.previousPageRect.midY - prevSize.height/2 + 1), withAttributes: prevAttrs)
            // 下一页
            let nextHovered = hoveredTrailing == .nextPage
            let nextPressed = pressedTrailing == .nextPage && nextHovered
            let nextEnabled = state.isNextPageEnabled
            let nextBg: NSColor = nextPressed ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.12) : nextHovered && nextEnabled ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.08) : .clear
            if nextHovered && nextEnabled { nextBg.setFill(); NSBezierPath(roundedRect: tl.nextPageRect.insetBy(dx: 2, dy: 4), xRadius: 4, yRadius: 4).fill() }
            let nextColor: NSColor = nextEnabled ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.7) : NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.25)
            let nextAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .regular), .foregroundColor: nextColor]
            let nextStr = "›"
            let nextSize = NSString(string: nextStr).size(withAttributes: nextAttrs)
            NSString(string: nextStr).draw(at: NSPoint(x: tl.nextPageRect.midX - nextSize.width/2, y: tl.nextPageRect.midY - nextSize.height/2 + 1), withAttributes: nextAttrs)
        }
        // 设置按钮
        let settingsHovered = hoveredTrailing == .settings
        let settingsPressed = pressedTrailing == .settings && settingsHovered
        let settingsBg: NSColor = settingsPressed ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.14) : settingsHovered ? NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.08) : .clear
        if settingsHovered || settingsPressed {
            settingsBg.setFill()
            NSBezierPath(roundedRect: tl.settingsButtonRect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let settingsAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.55)]
        let settingsStr = "⚙"
        let settingsSize = NSString(string: settingsStr).size(withAttributes: settingsAttrs)
        NSString(string: settingsStr).draw(at: NSPoint(x: tl.settingsButtonRect.midX - settingsSize.width/2, y: tl.settingsButtonRect.midY - settingsSize.height/2), withAttributes: settingsAttrs)
    }
}
