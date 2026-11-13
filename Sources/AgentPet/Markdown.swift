// 말풍선용 간단한 마크다운 렌더러 — 에이전트 댓글·답변에 흔한 문법만 다룬다.
//   블록: # 제목 · - / * / 1. 목록 · > 인용 · ``` 코드 블록 · --- 구분선 · | 표 | (고정폭으로)
//   인라인: **굵게** · *기울임* · `코드` · [글](https://…) · [@이름](mention://…) → @이름 강조
import AppKit

enum Markdown {
    static func render(_ text: String, size: CGFloat = 12) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = BubbleFont.font(size)
        let mono = BubbleFont.mono(size - 1)
        let codeBg = NSColor.labelColor.withAlphaComponent(0.07)
        var inCode = false
        var codeLines: [String] = []
        var tableRows: [[String]] = []

        func para(indent: CGFloat = 0, spacing: CGFloat = 4) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacing
            p.headIndent = indent
            p.lineSpacing = 1.5
            return p
        }

        func newline() {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
        }

        func flushCode() {
            newline()
            let p = para(indent: 6, spacing: 6)
            p.firstLineHeadIndent = 6
            out.append(NSAttributedString(string: codeLines.joined(separator: "\n"), attributes: [
                .font: mono, .foregroundColor: NSColor.labelColor, .backgroundColor: codeBg, .paragraphStyle: p,
            ]))
            codeLines = []
        }

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            newline()
            out.append(table(tableRows, font: body))
            tableRows = []
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inCode && line.hasPrefix("|") {   // 표 줄 모으기 — 구분 줄(|---|)은 건너뜀
                if !line.allSatisfy({ "|-: ".contains($0) }) {
                    tableRows.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                }
                continue
            }
            flushTable()
            if line.hasPrefix("```") {
                if inCode { flushCode() }
                inCode.toggle()
                continue
            }
            if inCode { codeLines.append(raw); continue }
            if line.isEmpty { continue }

            newline()
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {   // 제목
                let level = m.1.count
                let font = BubbleFont.font(size + CGFloat(max(0, 4 - level)), .bold)
                out.append(inline(String(m.2), font: font, para: para(spacing: 6)))
            } else if line.allSatisfy({ "-*_".contains($0) }) && line.count >= 3 {   // 구분선
                out.append(NSAttributedString(string: "────────────", attributes: [
                    .font: body, .foregroundColor: NSColor.separatorColor, .paragraphStyle: para(),
                ]))
            } else if let m = line.firstMatch(of: /^[-*+]\s+(.*)$/) {   // 글머리 목록
                let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 12
                let p = para(indent: indent + 14, spacing: 2)
                p.firstLineHeadIndent = indent
                let item = NSMutableAttributedString(string: "•  ", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p])
                item.append(inline(String(m.1), font: body, para: p))
                out.append(item)
            } else if let m = line.firstMatch(of: /^(\d{1,3})[.)]\s+(.*)$/) {   // 번호 목록
                let p = para(indent: 18, spacing: 2)
                let item = NSMutableAttributedString(string: "\(m.1). ", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p])
                item.append(inline(String(m.2), font: body, para: p))
                out.append(item)
            } else if line.hasPrefix(">") {   // 인용
                let p = para(indent: 10)
                p.firstLineHeadIndent = 10
                let q = inline(String(line.drop { $0 == ">" || $0 == " " }), font: body, para: p)
                let m = NSMutableAttributedString(attributedString: q)
                m.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: m.length))
                out.append(m)
            } else {
                out.append(inline(line, font: body, para: para()))
            }
        }
        if inCode && !codeLines.isEmpty { flushCode() }
        flushTable()
        return out
    }

    /// 표 — NSTextTable 로 칸을 나눠 그린다. 첫 줄은 머리글(굵게·배경)
    static func table(_ rows: [[String]], font: NSFont) -> NSAttributedString {
        let cols = rows.map(\.count).max() ?? 1
        let t = NSTextTable()
        t.numberOfColumns = cols
        t.layoutAlgorithm = .automaticLayoutAlgorithm
        t.collapsesBorders = true
        t.setContentWidth(100, type: .percentageValueType)
        let out = NSMutableAttributedString()
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for (r, row) in rows.enumerated() {
            for c in 0..<cols {
                let block = NSTextTableBlock(table: t, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                if r == 0 { block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06) }
                let p = NSMutableParagraphStyle()
                p.textBlocks = [block]
                let cell = inline(c < row.count ? row[c] : "", font: r == 0 ? bold : font, para: p)
                let m = NSMutableAttributedString(attributedString: cell)
                m.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: p, .font: font]))
                out.append(m)
            }
        }
        // 마지막 줄바꿈은 다음 블록이 붙이므로 뺀다
        if out.length > 0 { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// 한 줄 안의 인라인 문법
    static func inline(_ s: String, font: NSFont, para: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
        let out = NSMutableAttributedString()
        var rest = Substring(s)
        let pattern = /`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*\s][^*]*)\*/
        while let m = rest.firstMatch(of: pattern) {
            out.append(NSAttributedString(string: String(rest[rest.startIndex..<m.range.lowerBound]), attributes: base))
            var a = base
            var text = ""
            if let code = m.1 {
                text = String(code)
                a[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                a[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.07)
            } else if let label = m.2, let url = m.3 {
                if url.hasPrefix("mention://") {   // 멀티카 멘션 → @이름
                    text = label.hasPrefix("@") ? String(label) : "@" + label
                    a[.foregroundColor] = NSColor.controlAccentColor
                    a[.font] = BubbleFont.exact(font.pointSize, .semibold)
                } else {
                    text = String(label)
                    if let u = URL(string: String(url)) { a[.link] = u }
                }
            } else if let bold = m.4 ?? m.5 {
                text = String(bold)
                a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            } else if let italic = m.6 {
                text = String(italic)
                a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            out.append(NSAttributedString(string: text, attributes: a))
            rest = rest[m.range.upperBound...]
        }
        out.append(NSAttributedString(string: String(rest), attributes: base))
        return out
    }
}
