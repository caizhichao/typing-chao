import AppKit

// Swift 侧的 streamdown/shiki 替代：用 NSAttributedString 承载 MessageResponse 的 Markdown 表格与代码块高亮+复制。
// 设计对齐 ai-elements 的 MessageResponse(streamdown table) + CodeBlock(shiki) + Sources/Reasoning 折叠。
final class AIInputMarkdownView: NSView {
    private let textView: NSTextView
    private var codeCopyButtonList: [NSButton] = []
    private var codeByButtonIdentifier: [String: String] = [:]

    init() {
        let tv = NSTextView()
        self.textView = tv
        super.init(frame: .zero)
        tv.isEditable = false; tv.isSelectable = true; tv.isRichText = true
        tv.drawsBackground = false; tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.font = NSFont.systemFont(ofSize: 11.5)
        tv.textColor = NSColor.labelColor
        tv.allowsUndo = false
        addSubview(tv)
        tv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: trailingAnchor),
            tv.topAnchor.constraint(equalTo: topAnchor),
            tv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Native scroll is handled by outer NSScrollView; this view is the document.
        wantsLayer = true; layer?.cornerRadius = 9
    }

    required init?(coder: NSCoder) { fatalError() }

    // 暴露给外层滚动容器测量的首选尺寸。
    var fittingHeight: CGFloat {
        textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
    }

    func setMarkdownText(_ markdown: String) {
        let attr = Self.attributedString(from: markdown)
        textView.textStorage?.setAttributedString(attr)
        // 挂载代码块复制按钮（每段 code 的末尾右侧）。
        rebuildCodeCopyButtons(markdown: markdown)
        needsLayout = true
    }

    func setPlainText(_ text: String) {
        textView.string = text
        rebuildCodeCopyButtons(markdown: "")
        needsLayout = true
    }

    // MARK: - Code copy

    private func rebuildCodeCopyButtons(markdown: String) {
        codeCopyButtonList.forEach { $0.removeFromSuperview() }
        codeCopyButtonList.removeAll()
        codeByButtonIdentifier.removeAll()
        let blocks = Self.codeBlocks(in: markdown)
        for block in blocks {
            let btn = NSButton(title: "复制", target: self, action: #selector(copyCodeBlock(_:)))
            btn.bezelStyle = .rounded; btn.controlSize = .mini
            btn.font = NSFont.systemFont(ofSize: 9)
            let bid = UUID().uuidString
            btn.identifier = NSUserInterfaceItemIdentifier(bid)
            codeByButtonIdentifier[bid] = block.code
            btn.toolTip = "复制代码"
            textView.addSubview(btn)
            codeCopyButtonList.append(btn)
        }
        layoutCodeCopyButtons()
    }

    override func layout() {
        super.layout()
        layoutCodeCopyButtons()
    }

    private func layoutCodeCopyButtons() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        var idx = 0
        for btn in codeCopyButtonList {
            // 粗略把按钮放在对应代码块的右上角（按文本行估算）。
            let glyphRange = layout.glyphRange(for: container)
            let rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            btn.frame = NSRect(x: bounds.width - 52, y: max(6, rect.maxY - CGFloat(22 + idx*28)), width: 44, height: 18)
            idx += 1
        }
    }

    @objc private func copyCodeBlock(_ sender: NSButton) {
        guard let bid = sender.identifier?.rawValue, let code = codeByButtonIdentifier[bid] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        sender.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now()+1.2) { sender.title = "复制" }
    }

    // MARK: - Markdown -> NSAttributedString (最小可用：标题、表格、代码块、行内 code/link、列表)

    private static func attributedString(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let lang = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { codeLines.append(lines[i]); i += 1 }
                // code block: monospaced + gray bg rounded (用段落背景色近似)
                let code = codeLines.joined(separator: "\n")
                let block = codeBlockAttributedString(code: code, language: String(lang))
                result.append(block)
                result.append(NSAttributedString(string: "\n"))
            } else if isTableRow(line), i+1 < lines.count, isTableDelimiter(lines[i+1]) {
                let header = parseTableRow(line)
                let aligns = parseTableAlignments(lines[i+1])
                i += 2
                var rows: [[String]] = []
                while i < lines.count, isTableRow(lines[i]) { rows.append(parseTableRow(lines[i])); i += 1 }
                result.append(tableAttributedString(header: header, aligns: aligns, rows: rows))
                result.append(NSAttributedString(string: "\n"))
                continue
            } else if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                let font = NSFont.boldSystemFont(ofSize: max(10, 16 - CGFloat(level)))
                result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") || line.trimmingCharacters(in: .whitespaces).hasPrefix("* ") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                result.append(NSAttributedString(string: "• \(text)\n", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor]))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(NSAttributedString(string: "\n"))
            } else {
                // inline: `code` and [text](url)
                result.append(inlineAttributedString(line + "\n"))
            }
            i += 1
        }
        result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func inlineAttributedString(_ text: String) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 11.5)
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let r = NSMutableAttributedString(string: text, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
        // `code`
        let codePattern = try? NSRegularExpression(pattern: "`([^`]+)`")
        let ns = (text as NSString)
        let matches = codePattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in matches.reversed() {
            let range = m.range(at: 1)
            let full = m.range(at: 0)
            let code = ns.substring(with: range)
            let attr = NSAttributedString(string: code, attributes: [.font: mono, .backgroundColor: NSColor.controlBackgroundColor, .foregroundColor: NSColor.labelColor])
            r.replaceCharacters(in: full, with: attr)
        }
        // [text](url) -> underline + link
        let linkPattern = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)")
        let r2 = NSMutableAttributedString(attributedString: r)
        let ns2 = (r.string as NSString)
        let linkMatches = linkPattern?.matches(in: r.string, range: NSRange(location: 0, length: ns2.length)) ?? []
        for m in linkMatches.reversed() {
            let label = ns2.substring(with: m.range(at: 1)); let url = ns2.substring(with: m.range(at: 2))
            let link = NSAttributedString(string: label, attributes: [.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.systemBlue])
            r2.replaceCharacters(in: m.range(at: 0), with: link)
        }
        return r2
    }

    private static func codeBlockAttributedString(code: String, language: String) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let header = language.isEmpty ? "" : "\(language)\n"
        let full = header + code
        let attr = NSMutableAttributedString(string: full, attributes: [
            .font: mono,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor,
        ])
        // 添加圆角背景的段落样式近似（用 paragraph + 背景色）。
        let para = NSMutableParagraphStyle(); para.lineSpacing = 2; para.paragraphSpacing = 4
        attr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attr.length))
        if !language.isEmpty {
            attr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: min(header.count, attr.length)))
            attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 9), range: NSRange(location: 0, length: min(header.count, attr.length)))
        }
        return attr
    }

    // MARK: Table helpers (GFM | col | col |)

    private static func isTableRow(_ line: String) -> Bool { line.contains("|") && line.trimmingCharacters(in: .whitespaces).first == "|" || line.contains("|") && line.components(separatedBy: "|").count >= 3 }
    private static func isTableDelimiter(_ line: String) -> Bool { let t = line.trimmingCharacters(in: .whitespaces); return t.contains("-") && t.contains("|") }
    private static func parseTableRow(_ line: String) -> [String] {
        var parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }; if parts.last == "" { parts.removeLast() }
        return parts
    }
    private static func parseTableAlignments(_ line: String) -> [NSTextAlignment] {
        parseTableRow(line).map { c in
            if c.hasPrefix(":") && c.hasSuffix(":") { return .center }
            if c.hasSuffix(":") { return .right }
            return .left
        }
    }
    private static func tableAttributedString(header: [String], aligns: [NSTextAlignment], rows: [[String]]) -> NSAttributedString {
        _ = [header] + rows
        // 渲染为等宽制表 + 分隔线（原生 NSTextTable 在 NSTextView 内兼容性差，用文本表格最稳）。
        var colWidths: [Int] = header.map { $0.count }
        for r in rows { for (i,c) in r.enumerated() { if i < colWidths.count { colWidths[i] = max(colWidths[i], c.count) } else { colWidths.append(c.count) } } }
        func pad(_ s: String, _ w: Int, _ align: NSTextAlignment) -> String {
            let len = s.count; if len >= w { return s }
            switch align {
            case .center:
                let left = (w - len)/2; let right = w - len - left; return String(repeating: " ", count: left) + s + String(repeating: " ", count: right)
            case .right: return String(repeating: " ", count: w - len) + s
            default: return s + String(repeating: " ", count: w - len)
            }
        }
        var lines: [String] = []
        func lineFor(_ row: [String]) -> String {
            var cells: [String] = []
            for (i,c) in row.enumerated() { let w = i < colWidths.count ? colWidths[i] : c.count; let a = i < aligns.count ? aligns[i] : .left; cells.append(pad(c, w, a)) }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        lines.append(lineFor(header))
        let sep = "| " + colWidths.map { String(repeating: "-", count: max(3, $0)) }.joined(separator: " | ") + " |"
        lines.append(sep)
        for r in rows { lines.append(lineFor(r)) }
        let text = lines.joined(separator: "\n") + "\n"
        let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        return NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
    }

    private static func codeBlocks(in markdown: String) -> [(code: String, language: String)] {
        var out: [(String,String)] = []
        let pattern = try? NSRegularExpression(pattern: "```(\\w*)\\n(.*?)\\n```", options: .dotMatchesLineSeparators)
        let ns = (markdown as NSString)
        let ms = pattern?.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in ms {
            let lang = m.range(at: 1).length > 0 ? ns.substring(with: m.range(at: 1)) : ""
            let code = ns.substring(with: m.range(at: 2))
            out.append((code, lang))
        }
        return out
    }
}
