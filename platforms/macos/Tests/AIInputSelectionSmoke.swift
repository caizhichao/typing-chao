import Foundation

@main
struct AIInputSelectionSmoke {
    static func main() {
        let selectionContext = AIInputSelectionContext(
            selectedText: "asdf",
            replacementRange: NSRange(location: 12, length: 4)
        )
        guard selectionContext.selectedText == "asdf",
              selectionContext.replacementRange == NSRange(location: 12, length: 4) else {
            fatalError("selected AI input context must preserve prompt text and replacement range")
        }
        print("AI input selection smoke test passed: explicit selected text and replacement range")
    }
}
