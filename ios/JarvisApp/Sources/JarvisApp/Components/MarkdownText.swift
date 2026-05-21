import SwiftUI
import UIKit

/// Lightweight Markdown renderer for chat bubbles.
/// Supports: **bold**, *italic*, `code`, [links](url), and ```code blocks``` with copy button.
struct MarkdownText: View {
    let text: String
    let fontSize: CGFloat

    init(_ text: String, fontSize: CGFloat = 16) {
        self.text = text
        self.fontSize = fontSize
    }

    var body: some View {
        let parts = parseBlocks(text)
        VStack(alignment: .leading, spacing: Theme.scaled(8)) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let content):
                    inlineMarkdown(content)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                }
            }
        }
    }

    @ViewBuilder
    private func inlineMarkdown(_ content: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: content,
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

    // MARK: – Block parser

    private enum Block {
        case text(String)
        case code(String, language: String?)
    }

    private func parseBlocks(_ input: String) -> [Block] {
        var blocks: [Block] = []
        let pattern = "```(\\w*)\\n([\\s\\S]*?)```"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(input)]
        }

        let nsString = input as NSString
        var lastEnd = 0

        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            let matchStart = match.range.location

            // Text before code block
            if matchStart > lastEnd {
                let before = nsString.substring(with: NSRange(location: lastEnd, length: matchStart - lastEnd))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty {
                    blocks.append(.text(before))
                }
            }

            // Language
            let lang = match.range(at: 1).length > 0
                ? nsString.substring(with: match.range(at: 1))
                : nil

            // Code content
            let code = nsString.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .newlines)

            blocks.append(.code(code, language: lang?.isEmpty == true ? nil : lang))

            lastEnd = match.range.location + match.range.length
        }

        // Remaining text
        if lastEnd < nsString.length {
            let remaining = nsString.substring(from: lastEnd)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                blocks.append(.text(remaining))
            }
        }

        if blocks.isEmpty {
            blocks.append(.text(input))
        }

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
                        .foregroundStyle(Theme.accent.opacity(0.5))
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Theme.hapticSend()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: Theme.scaled(4)) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: Theme.scaled(11)))
                        Text(copied ? "Скопировано" : "Копировать")
                            .font(.system(size: Theme.scaled(11)))
                    }
                    .foregroundStyle(copied ? Theme.online : Theme.accent.opacity(0.6))
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
