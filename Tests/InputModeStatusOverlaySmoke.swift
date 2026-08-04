import Foundation

@main
struct InputModeStatusOverlaySmoke {
    static func main() {
        let halfWidthSnapshot = snapshot(fullShape: false, asciiPunctuation: false)
        let fullWidthSnapshot = snapshot(fullShape: true, asciiPunctuation: false)
        let westernPunctuationSnapshot = snapshot(fullShape: false, asciiPunctuation: true)

        guard InputModeStatusMessage.resolve(
            previous: halfWidthSnapshot,
            current: fullWidthSnapshot
        ) == "全角字符" else {
            fatalError("half-to-full transition must show an explicit full-width status")
        }
        guard InputModeStatusMessage.resolve(
            previous: fullWidthSnapshot,
            current: halfWidthSnapshot
        ) == "半角字符" else {
            fatalError("full-to-half transition must show an explicit half-width status")
        }
        guard InputModeStatusMessage.resolve(
            previous: halfWidthSnapshot,
            current: westernPunctuationSnapshot
        ) == "西文标点" else {
            fatalError("punctuation mode must remain independent from character width")
        }
        guard InputModeStatusMessage.resolve(
            previous: snapshot(fullShape: false, asciiPunctuation: false, schemaIdentifier: ""),
            current: fullWidthSnapshot
        ) == nil else {
            fatalError("initial snapshot hydration must not show a false mode transition")
        }
        print("Input mode status smoke test passed: half/full width and punctuation feedback")
    }

    private static func snapshot(
        fullShape: Bool,
        asciiPunctuation: Bool,
        schemaIdentifier: String = "luna_pinyin"
    ) -> RimeSnapshot {
        RimeSnapshot(dictionary: [
            "schemaIdentifier": schemaIdentifier,
            "isFullShape": fullShape,
            "isAsciiPunctuation": asciiPunctuation,
        ])
    }
}
