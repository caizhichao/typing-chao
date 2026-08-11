import AppKit
import InputMethodKit

@main
struct OverlayLayoutSmoke {
    private static let screenList = [(
        frame: NSRect(x: 100, y: 100, width: 1200, height: 800),
        visibleFrame: NSRect(x: 100, y: 120, width: 1200, height: 760)
    )]

    static func main() {
        verifyAttributesAtZeroWins()
        verifyFirstRectScreenSpaceWins()
        verifyTinyFirstRectFallsBack()
        verifyPaseoScreenCoordinates()
        verifyDocumentRangesDoNotAffectAnchor()
        verifyInvalidRectanglesAreRejected()
        verifyOffscreenRectangleIsRejected()
        verifyPanelClamping()
        verifyLongTranslationClearsAdjacentLine()
        verifyRecentAnchorReuse()
        print("Overlay layout smoke test passed: firstRect validation, screen-space attributes fallback, invalid anchor rejection, screen clamping, adjacent-line clearance, and recent anchor reuse")
    }

    // firstRect 无效时仍回退到 attributes index 0 的组合区矩形。
    private static func verifyAttributesAtZeroWins() {
        let client = OverlayLayoutSmokeClient(
            selectedRangeValue: NSRange(location: 204, length: 0),
            markedRangeValue: NSRange(location: 200, length: 10),
            attributesRect: NSRect(x: 420, y: 360, width: 1, height: 22),
            firstRectValue: NSRect(x: 2, y: 3, width: 1, height: 22)
        )
        guard let anchor = InputOverlayAnchor(client: client, screenList: screenList) else {
            fatalError("expected attributes anchor")
        }
        guard client.attributesIndexList == [0],
              !client.firstRectRangeList.isEmpty,
              anchor.caretRect.origin == NSPoint(x: 420, y: 360) else {
            fatalError("overlay anchor must fall back to attributes index 0 when firstRect is invalid")
        }
    }

    // Paseo 等宿主可能把 attributes 矩形留在窗口内，但 firstRect 仍提供正确屏幕坐标。
    private static func verifyFirstRectScreenSpaceWins() {
        let client = OverlayLayoutSmokeClient(
            selectedRangeValue: NSRange(location: 204, length: 0),
            attributesRect: NSRect(x: 32, y: 40, width: 1, height: 22),
            firstRectValue: NSRect(x: 620, y: 420, width: 1, height: 22)
        )
        guard let anchor = InputOverlayAnchor(
            client: client,
            screenList: screenList
        ) else {
            fatalError("expected firstRect screen anchor")
        }
        guard anchor.caretRect.origin == NSPoint(x: 620, y: 420) else {
            fatalError("screen-space firstRect must win over a window-local attributes rectangle")
        }
    }

    // Paseo 可能返回极小的非零垃圾矩形，必须回退到屏幕坐标 attributes 矩形。
    private static func verifyTinyFirstRectFallsBack() {
        let tinyValue = CGFloat.leastNonzeroMagnitude
        let client = OverlayLayoutSmokeClient(
            attributesRect: NSRect(x: 747, y: 188, width: 1, height: 19),
            firstRectValue: NSRect(x: tinyValue, y: 0, width: tinyValue, height: tinyValue),
            bundleIdentifierValue: "sh.paseo.desktop"
        )
        guard let anchor = InputOverlayAnchor(
            client: client,
            screenList: [(
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: NSRect(x: 0, y: 90, width: 1920, height: 960)
            )]
        ) else {
            fatalError("expected attributes fallback after rejecting tiny firstRect")
        }
        guard anchor.caretRect.origin == NSPoint(x: 747, y: 188) else {
            fatalError("tiny firstRect must fall back to screen-space attributes coordinates")
        }
    }

    // Paseo 的 attributes 矩形按 IMK 屏幕坐标使用，不能因为它落在窗口尺寸内而再次翻转。
    private static func verifyPaseoScreenCoordinates() {
        let client = OverlayLayoutSmokeClient(
            attributesRect: NSRect(x: 620, y: 188, width: 1, height: 22),
            bundleIdentifierValue: "sh.paseo.desktop"
        )
        guard let anchor = InputOverlayAnchor(
            client: client,
            screenList: [(
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: NSRect(x: 0, y: 90, width: 1920, height: 960)
            )]
        ) else {
            fatalError("expected Paseo screen-space anchor")
        }
        guard anchor.caretRect.origin == NSPoint(x: 620, y: 188) else {
            fatalError("Paseo attributes coordinates must not be flipped")
        }
    }

    // selectedRange 与 markedRange 缺失或变化都不能改变组合区定位 API 的固定 index 0 契约。
    private static func verifyDocumentRangesDoNotAffectAnchor() {
        let client = OverlayLayoutSmokeClient(
            selectedRangeValue: NSRange(location: NSNotFound, length: NSNotFound),
            markedRangeValue: NSRange(location: NSNotFound, length: NSNotFound),
            attributesRect: NSRect(x: 540, y: 420, width: 0, height: 0),
            firstRectValue: NSRect(x: 3, y: 4, width: 1, height: 20)
        )
        guard let anchor = InputOverlayAnchor(client: client, screenList: screenList) else {
            fatalError("document ranges must not block attributes placement")
        }
        guard client.attributesIndexList == [0],
              client.firstRectRangeList.isEmpty,
              anchor.caretRect.size == NSSize(width: 1, height: 20) else {
            fatalError("zero-sized line rect at a valid position must be normalized")
        }
    }

    // 零值、非有限值和负尺寸都不是可显示的光标锚点。
    private static func verifyInvalidRectanglesAreRejected() {
        let invalidRectList = [
            NSRect.zero,
            NSRect(x: CGFloat.nan, y: 220, width: 1, height: 20),
            NSRect(x: 220, y: CGFloat.infinity, width: 1, height: 20),
            NSRect(x: 220, y: 220, width: -1, height: 20),
            NSRect(x: CGFloat.greatestFiniteMagnitude, y: 220, width: 1, height: 20),
        ]
        for invalidRect in invalidRectList {
            let client = OverlayLayoutSmokeClient(attributesRect: invalidRect)
            guard InputOverlayAnchor(client: client, screenList: screenList) == nil else {
                fatalError("invalid attributes rectangle must be rejected: \(invalidRect)")
            }
            guard client.attributesIndexList == [0] else {
                fatalError("invalid attributes rectangle must still query attributes index 0")
            }
        }
    }

    // 有限非零但完全不属于任何屏幕的矩形必须隐藏，不能夹到主屏幕左上角或左下角。
    private static func verifyOffscreenRectangleIsRejected() {
        let client = OverlayLayoutSmokeClient(
            attributesRect: NSRect(x: 5000, y: 5000, width: 1, height: 20),
            firstRectValue: NSRect(x: 5000, y: 5000, width: 1, height: 20)
        )
        guard InputOverlayAnchor(client: client, screenList: screenList) == nil else {
            fatalError("offscreen attributes rectangle must not fall back to a main screen")
        }
        guard !client.firstRectRangeList.isEmpty else {
            fatalError("offscreen attributes rectangle must check the screen-space fallback")
        }
    }

    // 有效锚点仍需保证候选条和译文卡完整落在对应屏幕的可见区域内。
    private static func verifyPanelClamping() {
        let client = OverlayLayoutSmokeClient(
            attributesRect: NSRect(x: 1288, y: 132, width: 1, height: 20)
        )
        guard let anchor = InputOverlayAnchor(client: client, screenList: screenList) else {
            fatalError("expected edge anchor")
        }
        let candidateSize = NSSize(width: 460, height: 48)
        let candidateOrigin = anchor.candidateOrigin(for: candidateSize)
        verifyVisible(candidateOrigin, size: candidateSize, anchor: anchor)
        let candidateFrame = NSRect(origin: candidateOrigin, size: candidateSize)
        let translationSize = NSSize(width: 420, height: 58)
        verifyVisible(
            anchor.translationOrigin(for: translationSize, candidateFrame: candidateFrame),
            size: translationSize,
            anchor: anchor
        )
    }

    // 无候选条的长译文翻到光标上方时必须空出一整行，不能遮住多行输入的上一行正文。
    private static func verifyLongTranslationClearsAdjacentLine() {
        let client = OverlayLayoutSmokeClient(
            attributesRect: NSRect(x: 560, y: 142, width: 1, height: 22)
        )
        guard let anchor = InputOverlayAnchor(client: client, screenList: screenList) else {
            fatalError("expected multiline translation anchor")
        }
        let longSize = NSSize(width: 420, height: 114)
        let longOrigin = anchor.translationOrigin(for: longSize, candidateFrame: nil)
        guard longOrigin.y >= anchor.caretRect.maxY + anchor.caretRect.height else {
            fatalError("long translation above the caret must clear the adjacent text line: \(longOrigin)")
        }
        let shortSize = NSSize(width: 200, height: 38)
        let shortOrigin = anchor.translationOrigin(for: shortSize, candidateFrame: nil)
        guard shortOrigin.y < anchor.caretRect.maxY + anchor.caretRect.height else {
            fatalError("short translation should remain tightly attached to the caret: \(shortOrigin)")
        }
    }

    // 同一编辑客户端只允许短时复用最近可信锚点，跨客户端和过期锚点必须拒绝。
    private static func verifyRecentAnchorReuse() {
        let firstClient = OverlayLayoutSmokeClient(
            attributesRect: NSRect(x: 520, y: 360, width: 1, height: 20)
        )
        guard let currentAnchor = InputOverlayAnchor(client: firstClient, screenList: screenList) else {
            fatalError("expected cache source anchor")
        }
        var anchorCache = InputOverlayAnchorCache()
        let firstClientIdentifier = "overlay-layout-smoke:first"
        guard anchorCache.resolve(
            currentAnchor: currentAnchor,
            clientIdentifier: firstClientIdentifier,
            currentTime: 10
        )?.caretRect == currentAnchor.caretRect,
              anchorCache.resolve(
                  currentAnchor: nil,
                  clientIdentifier: firstClientIdentifier,
                  currentTime: 15
              )?.caretRect == currentAnchor.caretRect else {
            fatalError("same client must reuse its recent valid anchor")
        }
        guard anchorCache.resolve(
            currentAnchor: nil,
            clientIdentifier: "overlay-layout-smoke:second",
            currentTime: 15
        ) == nil,
              anchorCache.resolve(
                  currentAnchor: nil,
                  clientIdentifier: firstClientIdentifier,
                  currentTime: 16.1
              ) == nil else {
            fatalError("different clients and expired anchors must be rejected")
        }
        anchorCache.reset()
        guard anchorCache.resolve(
            currentAnchor: nil,
            clientIdentifier: firstClientIdentifier,
            currentTime: 15
        ) == nil else {
            fatalError("reset cache must not retain an old caret position")
        }
    }

    private static func verifyVisible(_ origin: NSPoint, size: NSSize, anchor: InputOverlayAnchor) {
        let panelFrame = NSRect(origin: origin, size: size)
        guard anchor.visibleFrame.contains(panelFrame) else {
            fatalError("overlay frame must be clamped to the matched screen")
        }
    }
}

// 用完整 IMKTextInput 替身隔离系统宿主，验证屏幕坐标优先和 attributes 回退。
private final class OverlayLayoutSmokeClient: NSObject, IMKTextInput {
    private let selectedRangeValue: NSRange
    private let markedRangeValue: NSRange
    private let attributesRect: NSRect
    private let firstRectValue: NSRect
    private let bundleIdentifierValue: String
    private(set) var attributesIndexList: [Int] = []
    private(set) var firstRectRangeList: [NSRange] = []

    init(
        selectedRangeValue: NSRange = NSRange(location: 0, length: 0),
        markedRangeValue: NSRange = NSRange(location: NSNotFound, length: 0),
        attributesRect: NSRect,
        firstRectValue: NSRect = .zero,
        bundleIdentifierValue: String = "com.caizhichao.typingchao.overlay-smoke"
    ) {
        self.selectedRangeValue = selectedRangeValue
        self.markedRangeValue = markedRangeValue
        self.attributesRect = attributesRect
        self.firstRectValue = firstRectValue
        self.bundleIdentifierValue = bundleIdentifierValue
    }

    func insertText(_ string: Any, replacementRange: NSRange) {}

    func setMarkedText(_ string: Any, selectionRange: NSRange, replacementRange: NSRange) {}

    func selectedRange() -> NSRange { selectedRangeValue }

    func markedRange() -> NSRange { markedRangeValue }

    func attributedSubstring(from range: NSRange) -> NSAttributedString? { nil }

    func length() -> Int { 0 }

    func characterIndex(
        for point: NSPoint,
        tracking mappingMode: IMKLocationToOffsetMappingMode,
        inMarkedRange: UnsafeMutablePointer<ObjCBool>?
    ) -> Int {
        NSNotFound
    }

    func attributes(
        forCharacterIndex index: Int,
        lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>?
    ) -> [AnyHashable: Any]? {
        attributesIndexList.append(index)
        lineRect?.pointee = attributesRect
        return nil
    }

    func validAttributesForMarkedText() -> [Any] { [] }

    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String) {}

    func selectMode(_ modeIdentifier: String) {}

    func supportsUnicode() -> Bool { true }

    func bundleIdentifier() -> String { bundleIdentifierValue }

    func windowLevel() -> CGWindowLevel { 0 }

    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }

    func uniqueClientIdentifierString() -> String { "overlay-layout-smoke" }

    func string(from range: NSRange, actualRange: NSRangePointer?) -> String? { nil }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        firstRectRangeList.append(range)
        return firstRectValue
    }
}
