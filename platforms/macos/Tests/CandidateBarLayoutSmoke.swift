import AppKit

@main
struct CandidateBarLayoutSmoke {
    static func main() {
        verifyPagedTrailingLayout()
        verifySingleActionLayout()
        print("Candidate bar layout smoke test passed: page indicator, navigation, separator, and settings stay in distinct groups")
    }

    // 分页页码、箭头、分隔线与设置按钮必须各自占用真实宽度，不能侵入候选或彼此合并。
    private static func verifyPagedTrailingLayout() {
        let panelSize = NSSize(width: 520, height: 40)
        let layout = CandidateBarTrailingLayout.resolve(
            panelSize: panelSize,
            hasPageControls: true
        )
        guard layout.candidateLimitX + CandidateBarTrailingLayout.candidateGap <=
                layout.pageIndicatorRect.minX,
              layout.pageIndicatorRect.maxX <= layout.previousPageRect.minX,
              layout.previousPageRect.maxX <= layout.nextPageRect.minX,
              layout.nextPageRect.maxX + CandidateBarTrailingLayout.pageActionGap <=
                layout.separatorRect.minX,
              layout.separatorRect.maxX + CandidateBarTrailingLayout.actionGroupGap <=
                layout.settingsButtonRect.minX,
              layout.settingsButtonRect.maxX + CandidateBarTrailingLayout.trailingInset <=
                panelSize.width else {
            fatalError("paged candidate trailing controls overlap or lack a visible group boundary")
        }
        let actualWidth = panelSize.width - layout.candidateLimitX
        let expectedWidth = CandidateBarTrailingLayout.requiredWidth(hasPageControls: true)
        guard abs(actualWidth - expectedWidth) < 0.001 else {
            fatalError("page indicator width must be included in the candidate trailing reservation")
        }
    }

    // 无分页时只保留分隔后的设置入口，不得留下隐藏 AI 或箭头命中区。
    private static func verifySingleActionLayout() {
        let panelSize = NSSize(width: 260, height: 40)
        let layout = CandidateBarTrailingLayout.resolve(
            panelSize: panelSize,
            hasPageControls: false
        )
        guard layout.pageIndicatorRect.isEmpty,
              layout.previousPageRect.isEmpty,
              layout.nextPageRect.isEmpty,
              layout.candidateLimitX + CandidateBarTrailingLayout.candidateGap <=
                layout.separatorRect.minX,
              layout.separatorRect.maxX + CandidateBarTrailingLayout.actionGroupGap <=
                layout.settingsButtonRect.minX else {
            fatalError("single action layout must not preserve page controls or a redundant AI entry")
        }
    }
}
