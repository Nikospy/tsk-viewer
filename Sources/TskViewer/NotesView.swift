import SwiftUI
import TskCore

/// Preserve paragraph/list boundaries; SwiftUI's inline markdown handles emphasis and inline code.
struct NotesView: View {
    let source: String

    private struct Block: Identifiable {
        let id: Int
        let text: String
        let marker: String?
        let isCode: Bool
        var isReply = false
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String] = []
        var insideFence = false
        for line in source.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if insideFence {
                    result.append(Block(id: result.count, text: code.joined(separator: "\n"), marker: nil, isCode: true))
                    code = []
                }
                insideFence.toggle()
            } else if insideFence {
                code.append(line)
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Replies written in either language stay recognizable after switching.
                if let prefix = Language.allCases.map(\.replyPrefix).first(where: { trimmed.hasPrefix($0) }) {
                    let text = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    result.append(Block(id: result.count, text: text, marker: nil, isCode: false, isReply: true))
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                    result.append(Block(id: result.count, text: String(trimmed.dropFirst(2)), marker: "–", isCode: false))
                } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                    result.append(Block(id: result.count, text: String(trimmed[range.upperBound...]), marker: String(trimmed[range]).trimmingCharacters(in: .whitespaces), isCode: false))
                } else {
                    result.append(Block(id: result.count, text: line, marker: nil, isCode: false))
                }
            }
        }
        if insideFence {
            result.append(Block(id: result.count, text: code.joined(separator: "\n"), marker: nil, isCode: true))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(blocks) { block in
                if block.isReply {
                    reply(block.text)
                } else if block.isCode {
                    ScrollView(.horizontal) {
                        Text(block.text).font(Theme.mono(12)).padding(10)
                    }
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if block.text.isEmpty {
                    Color.clear.frame(height: 6)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let marker = block.marker { Text(marker).foregroundStyle(Theme.faint) }
                        Text(inline(block.text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .lineSpacing(5)
                }
            }
        }
        .font(Theme.mono(13))
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
    }

    /// The user's own `Odp:` / `Reply:` lines read as prompt replies, not as note text.
    private func reply(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Theme.replyMarker).font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
            Text(inline(text)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.selection, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.vertical, 5)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
