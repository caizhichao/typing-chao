import AppKit

// 负责把完整 Rime 快照映射为 React 候选状态，选择、翻页和设置动作仍只回到输入控制器执行。
final class CandidateOverlay {
    private let panel: NSPanel
    private let webView = TypingChaoWebView(webViewName: .candidate, acceptsKeyboardFocus: false)

    private var candidateSelectionHandler: ((Int) -> Void)?
    private var pageHandler: ((Bool) -> Void)?
    private var settingsHandler: (() -> Void)?

    init() {
        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: 260,
            height: CandidateBarStyle.compactPanelHeight
        )
        webView.frame = initialFrame
        webView.autoresizingMask = [.width, .height]

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
        panel.contentView = webView

        webView.setMessageHandler { [weak self] messageBody in
            self?.handleWebMessage(messageBody)
        }
        webView.loadBundledPage()
    }

    // 候选选择统一回到输入控制器执行 librime 动作，Web 页面不直接维护引擎状态。
    func setCandidateSelectionHandler(_ selectionHandler: @escaping (Int) -> Void) {
        candidateSelectionHandler = selectionHandler
    }

    func setPageHandler(_ pageHandler: @escaping (Bool) -> Void) {
        self.pageHandler = pageHandler
    }

    func setSettingsHandler(_ settingsHandler: @escaping () -> Void) {
        self.settingsHandler = settingsHandler
    }

    // 每次 Rime 快照更新时计算紧凑宽度，再把同一份候选快照送到 React 绘制。
    func show(snapshot: RimeSnapshot, anchor: InputOverlayAnchor) {
        guard snapshot.isComposing, !snapshot.candidateList.isEmpty else {
            hide()
            return
        }
        let candidateState = CandidateWebState(
            snapshot: snapshot,
            maximumPanelWidth: anchor.availableOverlayWidth,
            isAIInputTriggerVisible: false
        )
        show(candidateState: candidateState, anchor: anchor)
    }

    // 输入等号时只把首位候选切为 AI 触发项，候选尾部不再保留重复 AI 图标。
    func showAIInputTrigger(anchor: InputOverlayAnchor) {
        let candidateState = CandidateWebState(
            snapshot: RimeSnapshot(dictionary: [:]),
            maximumPanelWidth: anchor.availableOverlayWidth,
            isAIInputTriggerVisible: true
        )
        show(candidateState: candidateState, anchor: anchor)
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

    private func show(candidateState: CandidateWebState, anchor: InputOverlayAnchor) {
        webView.sendMessage(
            messageType: "candidateState",
            messageData: candidateState.messageData
        )
        let panelSize = candidateState.panelSize
        webView.frame = NSRect(origin: .zero, size: panelSize)
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(anchor.candidateOrigin(for: panelSize))
        panel.orderFrontRegardless()
    }

    // Web UI 只触发白名单候选动作，所有 Rime 状态更新仍由 Swift 快照回写。
    private func handleWebMessage(_ messageBody: [String: Any]) {
        guard let messageType = messageBody["messageType"] as? String else {
            NSLog("TypingChao ignored candidate Web UI message without type")
            return
        }
        if messageType == "webViewReady" {
            webView.markPageReady()
            return
        }
        guard messageType == "candidateAction",
              let messageData = messageBody["messageData"] as? [String: Any],
              let actionName = messageData["actionName"] as? String else {
            NSLog("TypingChao ignored unknown candidate Web UI message: %@", messageType)
            return
        }
        switch actionName {
        case "selectCandidate":
            guard let candidateIndex = messageData["candidateIndex"] as? Int else { return }
            candidateSelectionHandler?(candidateIndex)
        case "changePage":
            guard let pageBackward = messageData["pageBackward"] as? Bool else { return }
            pageHandler?(pageBackward)
        case "openSettings":
            settingsHandler?()
        default:
            NSLog("TypingChao ignored unsupported candidate Web UI action: %@", actionName)
        }
    }
}

private enum CandidateBarStyle {
    static let compactPanelHeight: CGFloat = 36
    static let commentPanelHeight: CGFloat = 44
    static let maximumPanelWidth: CGFloat = 680
    static let minimumCandidateWidth: CGFloat = 44
    static let horizontalInset: CGFloat = 10
}

// 候选尾部只保留分页和设置入口，AI 由等号候选与输入法菜单统一进入。
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
        var requiredWidth = candidateGap + separatorWidth + actionGroupGap + settingsButtonWidth + trailingInset
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
        let separatorRect = NSRect(
            x: settingsButtonRect.minX - actionGroupGap - separatorWidth,
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
            settingsButtonRect: settingsButtonRect,
            candidateLimitX: pageIndicatorRect.minX - candidateGap
        )
    }
}

// 将 AppKit 字体测量结果和 Rime 分页状态一次性映射给 React，避免 Web 层再猜测宽度或引擎状态。
private struct CandidateWebState {
    private static let aiInputTriggerCandidate = RimeCandidateItem(
        textValue: "AI",
        labelText: "1",
        commentText: ""
    )

    let candidateList: [CandidateWebItem]
    let highlightedIndex: Int
    let isAIInputTriggerVisible: Bool
    let hasPageControls: Bool
    let pageText: String
    let isPreviousPageEnabled: Bool
    let isNextPageEnabled: Bool
    let panelSize: NSSize

    init(
        snapshot: RimeSnapshot,
        maximumPanelWidth: CGFloat,
        isAIInputTriggerVisible: Bool
    ) {
        self.isAIInputTriggerVisible = isAIInputTriggerVisible
        let displayedCandidateList: [RimeCandidateItem]
        if isAIInputTriggerVisible {
            displayedCandidateList = [Self.aiInputTriggerCandidate]
        } else {
            displayedCandidateList = snapshot.candidateList
        }
        hasPageControls = !isAIInputTriggerVisible && (snapshot.pageNumber > 0 || !snapshot.isLastPage)
        let boundedMaximumWidth = min(
            max(maximumPanelWidth, 1),
            CandidateBarStyle.maximumPanelWidth
        )
        let widthList = Self.resolveCandidateWidthList(
            candidateList: displayedCandidateList,
            maximumPanelWidth: boundedMaximumWidth,
            hasPageControls: hasPageControls,
            isAIInputTriggerVisible: isAIInputTriggerVisible
        )
        candidateList = displayedCandidateList.enumerated().map { candidateIndex, candidateItem in
            CandidateWebItem(
                labelText: candidateItem.labelText,
                textValue: candidateItem.textValue,
                commentText: candidateItem.commentText,
                widthPoint: widthList[candidateIndex]
            )
        }
        if isAIInputTriggerVisible {
            highlightedIndex = 0
        } else if displayedCandidateList.indices.contains(snapshot.highlightedIndex) {
            highlightedIndex = snapshot.highlightedIndex
        } else {
            highlightedIndex = -1
        }
        pageText = hasPageControls ? "\(snapshot.pageNumber + 1)" : ""
        isPreviousPageEnabled = hasPageControls && snapshot.pageNumber > 0
        isNextPageEnabled = hasPageControls && !snapshot.isLastPage
        let panelHeight: CGFloat
        if displayedCandidateList.contains(where: { !$0.commentText.isEmpty }) {
            panelHeight = CandidateBarStyle.commentPanelHeight
        } else {
            panelHeight = CandidateBarStyle.compactPanelHeight
        }
        let preferredPanelWidth = widthList.reduce(CandidateBarStyle.horizontalInset, +) +
            CandidateBarTrailingLayout.requiredWidth(hasPageControls: hasPageControls)
        let minimumPanelWidth = CandidateBarStyle.minimumCandidateWidth +
            CandidateBarStyle.horizontalInset +
            CandidateBarTrailingLayout.requiredWidth(hasPageControls: hasPageControls)
        panelSize = NSSize(
            width: min(boundedMaximumWidth, max(preferredPanelWidth, minimumPanelWidth)),
            height: panelHeight
        )
    }

    var messageData: [String: Any] {
        [
            "candidateList": candidateList.map { candidateItem in
                [
                    "labelText": candidateItem.labelText,
                    "textValue": candidateItem.textValue,
                    "commentText": candidateItem.commentText,
                    "widthPoint": Double(candidateItem.widthPoint),
                ]
            },
            "highlightedIndex": highlightedIndex,
            "isAIInputTriggerVisible": isAIInputTriggerVisible,
            "hasPageControls": hasPageControls,
            "pageText": pageText,
            "isPreviousPageEnabled": isPreviousPageEnabled,
            "isNextPageEnabled": isNextPageEnabled,
        ]
    }

    // 宽度先保留候选文本需求，再在锚点限制内按原候选比例压缩，避免候选被静默隐藏。
    private static func resolveCandidateWidthList(
        candidateList: [RimeCandidateItem],
        maximumPanelWidth: CGFloat,
        hasPageControls: Bool,
        isAIInputTriggerVisible: Bool
    ) -> [CGFloat] {
        let idealWidthList = candidateList.enumerated().map { candidateIndex, candidateItem in
            if isAIInputTriggerVisible, candidateIndex == 0 {
                return CGFloat(90)
            }
            return width(for: candidateItem)
        }
        guard !idealWidthList.isEmpty else { return [] }
        let availableCandidateWidth = max(
            maximumPanelWidth - CandidateBarStyle.horizontalInset -
                CandidateBarTrailingLayout.requiredWidth(hasPageControls: hasPageControls),
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

    private static func width(for candidateItem: RimeCandidateItem) -> CGFloat {
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

private struct CandidateWebItem {
    let labelText: String
    let textValue: String
    let commentText: String
    let widthPoint: CGFloat
}
