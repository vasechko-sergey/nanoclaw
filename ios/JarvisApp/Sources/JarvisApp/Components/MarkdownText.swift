import SwiftUI
import UIKit

/// Markdown renderer supporting: **bold**, *italic*, `code`, [links](url),
/// ```code blocks```, # headings, - lists, 1. lists, > blockquotes, ---, tables.
struct MarkdownText: View {
    let text: String
    let fontSize: CGFloat

    init(_ text: String, fontSize: CGFloat = 16) {
        self.text = text
        self.fontSize = fontSize
    }

    var body: some View {
        let parts = parseBlocks(text)
        VStack(alignment: .leading, spacing: Theme.scaled(6)) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let content):
                    if !content.isEmpty {
                        inlineMarkdown(content)
                    }
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .heading(let content, let level):
                    inlineMarkdown(content)
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .padding(.top, level == 1 ? Theme.scaled(4) : 0)
                case .rule:
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundStyle(Theme.surfaceBorder)
                        .padding(.vertical, Theme.scaled(2))
                case .bulletList(let items):
                    VStack(alignment: .leading, spacing: Theme.scaled(3)) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: Theme.scaled(6)) {
                                Text("•")
                                    .font(.system(size: fontSize))
                                    .foregroundStyle(Theme.accent)
                                    .frame(minWidth: Theme.scaled(10))
                                inlineMarkdown(item)
                            }
                        }
                    }
                case .orderedList(let items):
                    VStack(alignment: .leading, spacing: Theme.scaled(3)) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .top, spacing: Theme.scaled(6)) {
                                Text("\(i + 1).")
                                    .font(.system(size: fontSize))
                                    .foregroundStyle(Theme.accent)
                                    .frame(minWidth: Theme.scaled(18), alignment: .trailing)
                                inlineMarkdown(item)
                            }
                        }
                    }
                case .blockquote(let content):
                    HStack(alignment: .top, spacing: Theme.scaled(10)) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.accentMedium)
                            .frame(width: 2)
                        inlineMarkdown(content)
                            .foregroundStyle(Theme.textPrimary.opacity(0.7))
                    }
                    .padding(.leading, Theme.scaled(2))
                case .table(let rows):
                    tableView(rows)
                }
            }
        }
    }

    // MARK: – Inline markdown

    @ViewBuilder
    private func inlineMarkdown(_ content: String) -> some View {
        let processed = preprocessInline(content)
        if let attributed = try? AttributedString(
            markdown: processed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: fontSize))
                .tint(Theme.accent)
        } else {
            Text(content)
                .font(.system(size: fontSize))
        }
    }

    /// Pre-process inline markdown that AttributedString doesn't handle:
    /// ~~strikethrough~~ → ~text~ (CommonMark strikethrough)
    private func preprocessInline(_ text: String) -> String {
        guard text.contains("~~") else { return text }
        var result = text
        while let r = result.range(of: #"~~(.+?)~~"#, options: .regularExpression) {
            let inner = String(result[r]).dropFirst(2).dropLast(2)
            result.replaceSubrange(r, with: "~\(inner)~")
        }
        return result
    }

    // MARK: – Table view

    @ViewBuilder
    private func tableView(_ rows: [[String]]) -> some View {
        // Use a Grid (iOS 16+) so every column shares one width across all
        // rows — a per-row HStack sizes each cell independently, which made
        // columns drift out of alignment ("поехала"). Cells render inline
        // markdown so **bold**/`code` in a cell isn't shown as literal syntax.
        let colCount = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, cols in
                    GridRow {
                        ForEach(0..<colCount, id: \.self) { j in
                            tableCell(j < cols.count ? cols[j] : "", isHeader: i == 0, isLastCol: j == colCount - 1)
                        }
                    }
                    .background(i == 0 ? Theme.accent.opacity(0.06) : (i % 2 == 0 ? Theme.surface.opacity(0.4) : Color.clear))
                    if i < rows.count - 1 {
                        Divider().overlay(Theme.surfaceBorder).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.surfaceBorder, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func tableCell(_ cell: String, isHeader: Bool, isLastCol: Bool) -> some View {
        let size = max(fontSize - 2, 12)
        Group {
            if let attributed = try? AttributedString(
                markdown: preprocessInline(cell),
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
            } else {
                Text(cell)
            }
        }
        .font(.system(size: size))
        .fontWeight(isHeader ? .semibold : .regular)
        .foregroundStyle(isHeader ? Theme.accent.opacity(0.85) : Theme.textPrimary.opacity(0.85))
        .multilineTextAlignment(.leading)
        .tint(Theme.accent)
        .padding(.horizontal, Theme.scaled(10))
        .padding(.vertical, Theme.scaled(6))
        .frame(minWidth: Theme.scaled(64), alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if !isLastCol {
                Rectangle().frame(width: 0.5).foregroundStyle(Theme.surfaceBorder)
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return max(Theme.scaled(20), 19)
        case 2: return max(Theme.scaled(18), 17)
        default: return max(Theme.scaled(16), 15)
        }
    }

    // MARK: – Block parser

    private enum Block {
        case text(String)
        case code(String, language: String?)
        case heading(String, level: Int)
        case rule
        case bulletList([String])
        case orderedList([String])
        case blockquote(String)
        case table([[String]])
    }

    private func parseBlocks(_ input: String) -> [Block] {
        // First extract code fences
        let codeFencePattern = "```(\\w*)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: codeFencePattern) else {
            return parseTextBlocks(input)
        }

        let nsString = input as NSString
        var blocks: [Block] = []
        var lastEnd = 0
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            let matchStart = match.range.location
            if matchStart > lastEnd {
                let before = nsString.substring(with: NSRange(location: lastEnd, length: matchStart - lastEnd))
                blocks.append(contentsOf: parseTextBlocks(before))
            }
            let lang = match.range(at: 1).length > 0 ? nsString.substring(with: match.range(at: 1)) : nil
            let code = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .newlines)
            blocks.append(.code(code, language: lang?.isEmpty == true ? nil : lang))
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsString.length {
            let remaining = nsString.substring(from: lastEnd)
            blocks.append(contentsOf: parseTextBlocks(remaining))
        }

        if blocks.isEmpty { blocks.append(.text(input)) }
        return blocks
    }

    /// Parse a text segment (no code fences) into block elements.
    private func parseTextBlocks(_ input: String) -> [Block] {
        let lines = input.components(separatedBy: "\n")
        var blocks: [Block] = []
        var textLines: [String] = []
        var bulletItems: [String] = []
        var orderedItems: [String] = []
        var quoteLines: [String] = []
        var tableRows: [[String]] = []

        func flushText() {
            let joined = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.text(joined)) }
            textLines = []
        }
        func flushBullet() {
            if !bulletItems.isEmpty { blocks.append(.bulletList(bulletItems)); bulletItems = [] }
        }
        func flushOrdered() {
            if !orderedItems.isEmpty { blocks.append(.orderedList(orderedItems)); orderedItems = [] }
        }
        func flushQuote() {
            if !quoteLines.isEmpty {
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                quoteLines = []
            }
        }
        func flushTable() {
            if !tableRows.isEmpty {
                // Filter out separator rows (|---|---|)
                let filtered = tableRows.filter { row in
                    !row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }
                }
                if !filtered.isEmpty { blocks.append(.table(filtered)) }
                tableRows = []
            }
        }
        func flushAll() {
            flushText(); flushBullet(); flushOrdered(); flushQuote(); flushTable()
        }

        for line in lines {
            // Table row: starts and ends with |
            if line.hasPrefix("|") {
                flushText(); flushBullet(); flushOrdered(); flushQuote()
                let cols = line.split(separator: "|", omittingEmptySubsequences: false)
                    .dropFirst().dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                tableRows.append(Array(cols))
                continue
            }

            // Heading: # / ## / ###
            if line.hasPrefix("#") {
                flushAll()
                var level = 0
                var rest = line
                while rest.hasPrefix("#") { level += 1; rest = String(rest.dropFirst()) }
                let content = rest.trimmingCharacters(in: .whitespaces)
                if level <= 6 && !content.isEmpty {
                    blocks.append(.heading(content, level: min(level, 3)))
                    continue
                }
            }

            // Horizontal rule
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped == "---" || stripped == "***" || stripped == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            // Blockquote
            if line.hasPrefix("> ") || line == ">" {
                flushText(); flushBullet(); flushOrdered(); flushTable()
                let content = line.hasPrefix("> ") ? String(line.dropFirst(2)) : ""
                quoteLines.append(content)
                continue
            }

            // Bullet list
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushText(); flushOrdered(); flushQuote(); flushTable()
                bulletItems.append(String(line.dropFirst(2)))
                continue
            }

            // Ordered list: digits followed by ". "
            if let dotRange = line.range(of: #"^\d+\. "#, options: .regularExpression) {
                flushText(); flushBullet(); flushQuote(); flushTable()
                orderedItems.append(String(line[dotRange.upperBound...]))
                continue
            }

            // Plain text
            flushBullet(); flushOrdered(); flushQuote(); flushTable()
            textLines.append(line)
        }

        flushAll()
        return blocks
    }
}

// MARK: – Code Block View

private struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language + copy button
            HStack {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: Theme.fontSmall, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.accentMedium)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Theme.hapticSend()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1500))
                        copied = false
                    }
                } label: {
                    HStack(spacing: Theme.scaled(4)) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: Theme.scaled(11)))
                        Text(copied ? "Скопировано" : "Копировать")
                            .font(.system(size: Theme.scaled(11)))
                    }
                    .foregroundStyle(copied ? Theme.online : Theme.accent)
                    .padding(.horizontal, Theme.scaled(8))
                    .padding(.vertical, Theme.scaled(4))
                    .background(Theme.accent.opacity(0.08))
                    .clipShape(Capsule())
                }
                .frame(minHeight: Theme.scaled(28))
            }
            .padding(.horizontal, Theme.scaled(12))
            .padding(.top, Theme.scaled(8))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: max(Theme.fontBody - 2, 13), design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.scaled(12))
                    .padding(.vertical, Theme.scaled(10))
            }
        }
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.accent.opacity(0.08), lineWidth: 0.5)
        )
    }
}
