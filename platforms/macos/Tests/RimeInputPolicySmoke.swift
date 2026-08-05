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

        let firstPageSnapshot = snapshot(
            preedit: "shi",
            commitPreview: "是",
            candidates: ["是", "时", "事"],
            pageNumber: 0,
            isLastPage: false
        )
        guard RimeInputPolicy.candidatePageBackward(
            keyName: "=",
            snapshot: firstPageSnapshot
        ) == false,
        RimeInputPolicy.candidatePageBackward(
            keyName: "+",
            snapshot: firstPageSnapshot
        ) == false,
        RimeInputPolicy.candidatePageBackward(
            keyName: "-",
            snapshot: firstPageSnapshot
        ) == nil,
        RimeInputPolicy.candidatePageBackward(
            keyName: "equal",
            snapshot: firstPageSnapshot
        ) == false,
        RimeInputPolicy.candidatePageBackward(
            keyName: "KP_Add",
            snapshot: firstPageSnapshot
        ) == false else {
            fatalError("首屏候选应识别字符和命名加号进入下一页，减号仍保留普通输入语义")
        }

        guard RimeInputPolicy.candidatePagingKeyName(
            forPhysicalKeyCode: CandidatePagingKeyCode.ansiEqual
        ) == "=",
        RimeInputPolicy.candidatePagingKeyName(
            forPhysicalKeyCode: CandidatePagingKeyCode.ansiMinus
        ) == "-",
        RimeInputPolicy.candidatePagingKeyName(
            forPhysicalKeyCode: CandidatePagingKeyCode.keypadPlus
        ) == "+",
        RimeInputPolicy.candidatePagingKeyName(
            forPhysicalKeyCode: CandidatePagingKeyCode.keypadMinus
        ) == "-",
        RimeInputPolicy.candidatePagingKeyName(
            forPhysicalKeyCode: CandidatePagingKeyCode.unrelatedKey
        ) == nil else {
            fatalError("无文本 InputMethodKit 回调必须按物理键码恢复主键盘和数字键盘加减号")
        }

        let middlePageSnapshot = snapshot(
            preedit: "shi",
            commitPreview: "始",
            candidates: ["始", "使", "十"],
            pageNumber: 1,
            isLastPage: false
        )
        guard RimeInputPolicy.candidatePageBackward(
            keyName: "-",
            snapshot: middlePageSnapshot
        ) == true,
        RimeInputPolicy.candidatePageBackward(
            keyName: "KP_Subtract",
            snapshot: middlePageSnapshot
        ) == true else {
            fatalError("非首屏候选应识别字符和命名减号返回上一页")
        }

        let lastPageSnapshot = snapshot(
            preedit: "shi",
            commitPreview: "式",
            candidates: ["式"],
            pageNumber: 2,
            isLastPage: true
        )
        guard RimeInputPolicy.candidatePageBackward(
            keyName: "=",
            snapshot: lastPageSnapshot
        ) == nil else {
            fatalError("末页不应继续吞掉等号或加号")
        }

        print("Rime input policy smoke test passed: direct symbols, full shape, pinyin delimiter, and minus/plus paging")
    }

    private static func snapshot(
        preedit: String = "",
        commitText: String = "",
        commitPreview: String = "",
        candidates: [String] = [],
        highlightedIndex: Int = 0,
        isFullShape: Bool = false,
        pageNumber: Int = 0,
        isLastPage: Bool = true
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
            "pageNumber": pageNumber,
            "isLastPage": isLastPage,
        ])
    }
}

// 测试值对应 macOS ANSI 键盘虚拟键码，只用于验证无文本回调的翻页键恢复。
private enum CandidatePagingKeyCode {
    static let ansiEqual = 0x18 // 主键盘等号/加号键
    static let ansiMinus = 0x1B // 主键盘减号键
    static let keypadPlus = 0x45 // 数字键盘加号键
    static let keypadMinus = 0x4E // 数字键盘减号键
    static let unrelatedKey = 0x00 // 与翻页无关的 A 键
}
