import AppKit
import InputMethodKit

// 统一从 InputMethodKit 的组合区入口取得真实光标矩形，并为候选窗与译文窗计算同一套位置。
struct InputOverlayAnchor {
    private static let edgeInset: CGFloat = 8
    private static let candidateGap: CGFloat = 6
    private static let translationGap: CGFloat = 5
    private static let multilineTranslationHeight: CGFloat = 54

    let caretRect: NSRect
    let visibleFrame: NSRect

    var availableOverlayWidth: CGFloat {
        max(visibleFrame.width - Self.edgeInset * 2, 1)
    }

    // 成熟 InputMethodKit 前端以 index 0 查询当前组合区行高，禁止混用文档范围和 firstRect。
    init?(client: IMKTextInput?) {
        let screenList = NSScreen.screens.map { screen in
            (frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        self.init(client: client, screenList: screenList)
    }

    // 测试入口显式注入屏幕几何，确保无匹配屏幕时不会退回主屏角落。
    init?(
        client: IMKTextInput?,
        screenList: [(frame: NSRect, visibleFrame: NSRect)]
    ) {
        guard let client else { return nil }

        var resolvedRect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &resolvedRect)
        guard Self.isUsable(resolvedRect) else { return nil }

        if resolvedRect.width < 1 {
            resolvedRect.size.width = 1
        }
        if resolvedRect.height < 1 {
            resolvedRect.size.height = 20
        }
        guard let matchedScreen = screenList.first(where: { $0.frame.intersects(resolvedRect) }),
              matchedScreen.visibleFrame.width > 0,
              matchedScreen.visibleFrame.height > 0 else {
            return nil
        }

        caretRect = resolvedRect
        visibleFrame = matchedScreen.visibleFrame
    }

    // 候选窗优先紧贴光标下方；两侧都不足时选择可用空间较大的一侧，减少压住光标的概率。
    func candidateOrigin(for panelSize: NSSize) -> NSPoint {
        let belowY = caretRect.minY - Self.candidateGap - panelSize.height
        let aboveY = caretRect.maxY + Self.candidateGap
        let belowSpace = caretRect.minY - visibleFrame.minY - Self.candidateGap
        let aboveSpace = visibleFrame.maxY - caretRect.maxY - Self.candidateGap
        var originY = belowY
        if belowSpace < panelSize.height, aboveSpace > belowSpace {
            originY = aboveY
        }
        return clampedOrigin(x: caretRect.minX, y: originY, panelSize: panelSize)
    }

    // 译文窗避开当前候选窗；两侧都不足时同样优先放到可用空间较大的一侧。
    func translationOrigin(for panelSize: NSSize, candidateFrame: NSRect?) -> NSPoint {
        var lowerEdge = caretRect.minY
        var upperEdge = caretRect.maxY
        var adjacentLineClearance: CGFloat = 0
        if let candidateFrame {
            lowerEdge = min(lowerEdge, candidateFrame.minY)
            upperEdge = max(upperEdge, candidateFrame.maxY)
        } else if panelSize.height > Self.multilineTranslationHeight {
            adjacentLineClearance = max(caretRect.height, 18)
        }

        let belowY = lowerEdge - adjacentLineClearance - Self.translationGap - panelSize.height
        let aboveY = upperEdge + adjacentLineClearance + Self.translationGap
        let belowSpace = lowerEdge - adjacentLineClearance - visibleFrame.minY - Self.translationGap
        let aboveSpace = visibleFrame.maxY - upperEdge - adjacentLineClearance - Self.translationGap
        var originY = belowY
        if belowSpace < panelSize.height, aboveSpace > belowSpace {
            originY = aboveY
        }
        return clampedOrigin(x: caretRect.minX, y: originY, panelSize: panelSize)
    }

    private func clampedOrigin(x: CGFloat, y: CGFloat, panelSize: NSSize) -> NSPoint {
        let minimumX = visibleFrame.minX + Self.edgeInset
        let minimumY = visibleFrame.minY + Self.edgeInset
        let maximumX = max(minimumX, visibleFrame.maxX - panelSize.width - Self.edgeInset)
        let maximumY = max(minimumY, visibleFrame.maxY - panelSize.height - Self.edgeInset)
        let originX = min(max(x, minimumX), maximumX)
        let originY = min(max(y, minimumY), maximumY)
        return NSPoint(x: originX, y: originY)
    }

    // 仅接受有限且非负尺寸的真实行高矩形；屏幕归属由初始化阶段继续验证。
    private static func isUsable(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
            && rect.size.width >= 0
            && rect.size.height >= 0
            && rect != .zero
            && rect.origin.x != CGFloat.greatestFiniteMagnitude
            && rect.origin.y != CGFloat.greatestFiniteMagnitude
    }
}

// 无组合态宿主暂时不给出光标矩形时，短暂复用同一编辑客户端最近一次可信锚点。
struct InputOverlayAnchorCache {
    static let maximumReuseInterval = 6.0

    private var clientIdentifier: String?
    private var anchor: InputOverlayAnchor?
    private var captureTime: TimeInterval?

    mutating func resolve(
        currentAnchor: InputOverlayAnchor?,
        clientIdentifier: String,
        currentTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> InputOverlayAnchor? {
        if let currentAnchor {
            self.clientIdentifier = clientIdentifier
            anchor = currentAnchor
            captureTime = currentTime
            return currentAnchor
        }
        guard self.clientIdentifier == clientIdentifier,
              let anchor,
              let captureTime,
              currentTime - captureTime <= Self.maximumReuseInterval else {
            return nil
        }
        return anchor
    }

    mutating func reset() {
        clientIdentifier = nil
        anchor = nil
        captureTime = nil
    }
}
