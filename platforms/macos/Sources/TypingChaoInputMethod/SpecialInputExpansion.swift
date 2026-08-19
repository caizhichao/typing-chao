import Foundation

// 日期和时间扩展以独立候选入口展开，普通“日期/时间”候选仍保持原有提交语义。
enum SpecialInputExpansionKind: String, CaseIterable {
    case date
    case time

    var triggerText: String {
        switch self {
        case .date:
            return "日期"
        case .time:
            return "时间"
        }
    }

    var displayTitle: String {
        triggerText
    }

    var triggerSpellings: Set<String> {
        switch self {
        case .date:
            return ["riqi", "rq"]
        case .time:
            return ["shijian", "sj"]
        }
    }
}

// 维护一次扩展展开期间的候选，所有候选使用同一个时间快照，避免跨秒显示不一致。
struct SpecialInputExpansionState {
    let kind: SpecialInputExpansionKind
    let candidateList: [RimeCandidateItem]
    let highlightedIndex: Int
}

enum SpecialInputExpansionCatalog {
    static func kind(for snapshot: RimeSnapshot) -> SpecialInputExpansionKind? {
        guard snapshot.isComposing,
              isSupportedPinyinSchema(snapshot.schemaIdentifier) else {
            return nil
        }
        let normalizedPreedit = normalizeSpelling(snapshot.preeditText)
        return SpecialInputExpansionKind.allCases.first { kind in
            kind.triggerSpellings.contains(normalizedPreedit)
        }
    }

    static func kind(
        forSpecialTriggerSelectionKey selectionKey: String,
        snapshot: RimeSnapshot
    ) -> SpecialInputExpansionKind? {
        guard let kind = kind(for: snapshot),
              let triggerCandidateIndex = triggerCandidateIndex(
                  for: kind,
                  snapshot: snapshot
              ),
              selectionKey == String(triggerCandidateIndex + 2) else {
            return nil
        }
        return kind
    }

    static func specialTriggerInsertIndex(for snapshot: RimeSnapshot) -> Int? {
        guard let kind = kind(for: snapshot) else {
            return nil
        }
        return triggerCandidateIndex(for: kind, snapshot: snapshot)
    }

    static func specialTriggerLabelText(for snapshot: RimeSnapshot) -> String? {
        guard let insertIndex = specialTriggerInsertIndex(for: snapshot) else {
            return nil
        }
        return String(insertIndex + 2)
    }

    static func state(
        for kind: SpecialInputExpansionKind,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> SpecialInputExpansionState {
        SpecialInputExpansionState(
            kind: kind,
            candidateList: candidateList(for: kind, date: date, calendar: calendar),
            highlightedIndex: 0
        )
    }

    private static func triggerCandidateIndex(
        for kind: SpecialInputExpansionKind,
        snapshot: RimeSnapshot
    ) -> Int? {
        snapshot.candidateList.firstIndex { candidate in
            candidate.textValue == kind.triggerText
        }
    }

    private static func isSupportedPinyinSchema(_ schemaIdentifier: String) -> Bool {
        schemaIdentifier == "typing_pinyin" ||
            schemaIdentifier == "typing_double_pinyin_natural" ||
            schemaIdentifier == "typing_double_pinyin_flypy"
    }

    private static func normalizeSpelling(_ value: String) -> String {
        value.lowercased().filter { character in
            character.isLetter || character.isNumber
        }
    }

    private static func candidateList(
        for kind: SpecialInputExpansionKind,
        date: Date,
        calendar: Calendar
    ) -> [RimeCandidateItem] {
        let textList: [String]
        switch kind {
        case .date:
            textList = dateTextList(date: date, calendar: calendar)
        case .time:
            textList = timeTextList(date: date, calendar: calendar)
        }
        return textList.enumerated().map { index, textValue in
            RimeCandidateItem(
                textValue: textValue,
                labelText: String(index + 1),
                commentText: ""
            )
        }
    }

    private static func dateTextList(date: Date, calendar: Calendar) -> [String] {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = dateComponents.year,
              let month = dateComponents.month,
              let day = dateComponents.day else {
            return []
        }
        let lunarText = lunarDateText(date: date)
        return [
            String(format: "%04d-%02d-%02d", year, month, day),
            "\(year)年\(month)月\(day)日",
            String(format: "%04d/%02d/%02d", year, month, day),
            String(format: "%04d.%02d.%02d", year, month, day),
            String(format: "%04d%02d%02d", year, month, day),
            "\(chineseYearText(year))年\(chineseNumberText(month))月\(chineseNumberText(day))日",
            lunarText,
        ]
    }

    private static func timeTextList(date: Date, calendar: Calendar) -> [String] {
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let hour = timeComponents.hour,
              let minute = timeComponents.minute,
              let second = timeComponents.second else {
            return []
        }
        let hour12: Int
        if hour % 12 == 0 {
            hour12 = 12
        } else {
            hour12 = hour % 12
        }
        let meridiem: String
        if hour < 12 {
            meridiem = "上午"
        } else {
            meridiem = "下午"
        }
        return [
            String(format: "%02d:%02d", hour, minute),
            String(format: "%02d:%02d:%02d", hour, minute, second),
            "\(meridiem)\(hour12):\(String(format: "%02d", minute))",
            "\(hour)时\(minute)分",
            "\(meridiem)\(chineseNumberText(hour12))点\(chineseNumberText(minute))分",
            "\(chineseNumberText(hour))点\(chineseNumberText(minute))分",
            "\(hour)点\(minute)分\(second)秒",
        ]
    }

    private static func lunarDateText(date: Date) -> String {
        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.locale = Locale(identifier: "zh_CN")
        let components = lunarCalendar.dateComponents([.year, .month, .day], from: date)
        guard let cycleYear = components.year,
              let month = components.month,
              let day = components.day else {
            return ""
        }
        let cycleIndex = (cycleYear - 1) % 60
        let heavenlyStems = Array("甲乙丙丁戊己庚辛壬癸")
        let earthlyBranches = Array("子丑寅卯辰巳午未申酉戌亥")
        let zodiacAnimals = Array("鼠牛虎兔龙蛇马羊猴鸡狗猪")
        let stem = heavenlyStems[cycleIndex % heavenlyStems.count]
        let branch = earthlyBranches[cycleIndex % earthlyBranches.count]
        let animal = zodiacAnimals[cycleIndex % zodiacAnimals.count]
        let monthNameList = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
        let monthName: String
        if monthNameList.indices.contains(month - 1) {
            monthName = monthNameList[month - 1]
        } else {
            monthName = chineseNumberText(month)
        }
        let dayNameList = [
            "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
            "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
            "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
        ]
        let dayName: String
        if dayNameList.indices.contains(day - 1) {
            dayName = dayNameList[day - 1]
        } else {
            dayName = chineseNumberText(day)
        }
        return "\(stem)\(branch)[\(animal)]年\(monthName)月\(dayName)"
    }

    private static func chineseYearText(_ year: Int) -> String {
        let digitList = Array("〇一二三四五六七八九")
        return String(String(year).compactMap { character in
            guard let digit = character.wholeNumberValue,
                  digitList.indices.contains(digit) else {
                return nil
            }
            return digitList[digit]
        })
    }

    private static func chineseNumberText(_ value: Int) -> String {
        guard value > 0 else {
            return "零"
        }
        let digitList = Array("零一二三四五六七八九")
        if value < 10 {
            return String(digitList[value])
        }
        if value == 10 {
            return "十"
        }
        if value < 20 {
            return "十\(digitList[value - 10])"
        }
        if value % 10 == 0 {
            return "\(digitList[value / 10])十"
        }
        return "\(digitList[value / 10])十\(digitList[value % 10])"
    }
}
