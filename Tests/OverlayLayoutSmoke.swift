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
        verifyDocumentRangesDoNotAffectAnchor()
        verifyInvalidRectanglesAreRejected()
        verifyOffscreenRectangleIsRejected()
        verifyPanelClamping()
        print("Overlay layout smoke test passed: attributes index 0, invalid anchor rejection, and screen clamping")
    }

    // 即使宿主返回非零 firstRect，浮层也只能采用 attributes index 0 的组合区矩形。
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
              client.firstRectRangeList.isEmpty,
              anchor.caretRect.origin == NSPoint(x: 420, y: 360) else {
            fatalError("overlay anchor must use attributes index 0 and never query firstRect")
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
            guard client.attributesIndexList == [0], client.firstRectRangeList.isEmpty else {
                fatalError("invalid attributes rectangle must not trigger firstRect fallback")
            }
        }
    }

    // 有限非零但完全不属于任何屏幕的矩形必须隐藏，不能夹到主屏幕左上角或左下角。
    private static func verifyOffscreenRectangleIsRejected() {
        let client = OverlayLayoutSmokeClient(
            attributesRect: NSRect(x: 5000, y: 5000, width: 1, height: 20),
            firstRectValue: NSRect(x: 300, y: 300, width: 1, height: 20)
        )
        guard InputOverlayAnchor(client: client, screenList: screenList) == nil else {
            fatalError("offscreen attributes rectangle must not fall back to a main screen")
        }
        guard client.firstRectRangeList.isEmpty else {
            fatalError("offscreen attributes rectangle must not query firstRect")
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

    private static func verifyVisible(_ origin: NSPoint, size: NSSize, anchor: InputOverlayAnchor) {
        let panelFrame = NSRect(origin: origin, size: size)
        guard anchor.visibleFrame.contains(panelFrame) else {
            fatalError("overlay frame must be clamped to the matched screen")
        }
    }
}

// 用完整 IMKTextInput 替身隔离系统宿主，验证定位只读取 attributes index 0。
private final class OverlayLayoutSmokeClient: NSObject, IMKTextInput {
    private let selectedRangeValue: NSRange
    private let markedRangeValue: NSRange
    private let attributesRect: NSRect
    private let firstRectValue: NSRect
    private(set) var attributesIndexList: [Int] = []
    private(set) var firstRectRangeList: [NSRange] = []

    init(
        selectedRangeValue: NSRange = NSRange(location: 0, length: 0),
        markedRangeValue: NSRange = NSRange(location: NSNotFound, length: 0),
        attributesRect: NSRect,
        firstRectValue: NSRect = .zero
    ) {
        self.selectedRangeValue = selectedRangeValue
        self.markedRangeValue = markedRangeValue
        self.attributesRect = attributesRect
        self.firstRectValue = firstRectValue
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

    func bundleIdentifier() -> String { "com.caizhichao.typing-dongnanya.overlay-smoke" }

    func windowLevel() -> CGWindowLevel { 0 }

    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }

    func uniqueClientIdentifierString() -> String { "overlay-layout-smoke" }

    func string(from range: NSRange, actualRange: NSRangePointer?) -> String? { nil }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        firstRectRangeList.append(range)
        return firstRectValue
    }
}
