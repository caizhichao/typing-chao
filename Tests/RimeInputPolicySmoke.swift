import Foundation

@main
struct RimeInputPolicySmoke {
    static func main() {
        let emptySnapshot = snapshot()
        let pinyinSnapshot = snapshot(
            preedit: "nihao",
            commitPreview: "你好",
            candidates: ["你好", "你号"]
        )
        let slashSnapshot = snapshot(
            preedit: "你好、",
            commitPreview: "你好、",
            candidates: ["、", "､", "/", "／", "÷"]
        )
        guard RimeInputPolicy.directSymbolCandidateIndex(
            keyName: "/",
            previousSnapshot: pinyinSnapshot,
            currentSnapshot: slashSnapshot
        ) == 2 else {
            fatalError("半角斜杠应直接选择与用户按键一致的符号")
        }

        let bracketSnapshot = snapshot(
            preedit: "「",
            commitPreview: "「",
            candidates: ["「", "【", "〔", "［"]
        )
        guard RimeInputPolicy.directSymbolCandidateIndex(
            keyName: "[",
            previousSnapshot: emptySnapshot,
            currentSnapshot: bracketSnapshot
        ) == 0 else {
            fatalError("首个多选符号应直接确认首选项而不拉起候选窗")
        }

        let fullShapeSlashSnapshot = snapshot(
            preedit: "／",
            commitPreview: "／",
            candidates: ["／", "÷"],
            highlightedIndex: 0,
            isFullShape: true
        )
        guard RimeInputPolicy.directSymbolCandidateIndex(
            keyName: "/",
            previousSnapshot: emptySnapshot,
            currentSnapshot: fullShapeSlashSnapshot
        ) == 0 else {
            fatalError("全角状态必须保留 librime 的高亮全角符号")
        }

        let directQuestionSnapshot = snapshot(commitText: "？")
        guard RimeInputPolicy.directSymbolCandidateIndex(
            keyName: "?",
            previousSnapshot: emptySnapshot,
            currentSnapshot: directQuestionSnapshot
        ) == nil else {
            fatalError("librime 已直接提交的标点不得再次选择候选")
        }

        let delimiterSnapshot = snapshot(
            preedit: "xi'an",
            commitPreview: "西安",
            candidates: ["西安", "西岸"]
        )
        guard RimeInputPolicy.directSymbolCandidateIndex(
            keyName: "'",
            previousSnapshot: snapshot(
                preedit: "xi",
                commitPreview: "西",
                candidates: ["西", "系"]
            ),
            currentSnapshot: delimiterSnapshot
        ) == nil else {
            fatalError("拼音组合中的单引号必须继续作为音节分隔符")
        }

        let pagingSnapshot = snapshot(
            preedit: "nihao",
            commitPreview: "你好",
            candidates: ["你好", "你号"]
        )
        guard RimeInputPolicy.directSymbolCandidateIndex(
            keyName: ",",
            previousSnapshot: pinyinSnapshot,
            currentSnapshot: pagingSnapshot
        ) == nil else {
            fatalError("未改变提交预览的翻页键不得误提交当前候选")
        }

        print("Rime input policy smoke test passed: direct symbols, full shape, pinyin delimiter, and paging")
    }

    private static func snapshot(
        preedit: String = "",
        commitText: String = "",
        commitPreview: String = "",
        candidates: [String] = [],
        highlightedIndex: Int = 0,
        isFullShape: Bool = false
    ) -> RimeSnapshot {
        RimeSnapshot(dictionary: [
            "handled": true,
            "preedit": preedit,
            "commitText": commitText,
            "commitPreview": commitPreview,
            "candidates": candidates.enumerated().map { index, textValue in
                ["text": textValue, "label": String(index + 1), "comment": ""]
            },
            "highlightedIndex": highlightedIndex,
            "isFullShape": isFullShape,
        ])
    }
}
