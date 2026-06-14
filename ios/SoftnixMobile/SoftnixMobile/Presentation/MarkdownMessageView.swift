import SwiftUI

struct MarkdownMessageView: View {
    private let blocks: [MarkdownBlock]

    init(_ source: String) {
        blocks = MarkdownParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(text)
                .font(headingFont(level))
                .foregroundStyle(level == 1 ? SoftnixTheme.deepBlue : .primary)
                .padding(.top, level == 1 ? 2 : 4)
        case .paragraph(let text):
            InlineMarkdownText(text)
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(SoftnixTheme.blue)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        InlineMarkdownText(item)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.subheadline.bold())
                            .foregroundStyle(SoftnixTheme.blue)
                            .frame(minWidth: 20, alignment: .trailing)
                        InlineMarkdownText(item)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(SoftnixTheme.blue.opacity(0.7))
                    .frame(width: 3)
                InlineMarkdownText(text)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.vertical, 2)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language?.isEmpty == false ? language! : "Code")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = code
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemFill))
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(12)
                }
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.separator).opacity(0.45))
            }
        case .table(let rows):
            MarkdownTable(rows: rows)
        case .divider:
            Divider().padding(.vertical, 3)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.bold()
        case 2: .headline
        default: .subheadline.bold()
        }
    }
}

private struct InlineMarkdownText: View {
    let attributed: AttributedString

    init(_ source: String) {
        attributed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }

    var body: some View {
        Text(attributed)
            .tint(SoftnixTheme.blue)
    }
}

private struct MarkdownTable: View {
    let rows: [[String]]
    private var columnCount: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            InlineMarkdownText(column < row.count ? row[column] : "")
                                .font(rowIndex == 0 ? .caption.bold() : .caption)
                                .frame(minWidth: 110, maxWidth: 190, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(rowIndex == 0 ? SoftnixTheme.blue.opacity(0.12) : .clear)
                                .overlay(alignment: .bottom) {
                                    Divider()
                                }
                        }
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.separator).opacity(0.45))
            }
        }
        .scrollIndicators(.visible)
    }
}

private enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case code(String?, String)
    case table([[String]])
    case divider
}

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language.nilIfEmpty, code.joined(separator: "\n")))
                index += 1
                continue
            }
            if let heading = heading(from: line) {
                flushParagraph()
                blocks.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }
            if isDivider(line) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }
            if isTableStart(lines: lines, index: index) {
                flushParagraph()
                var rows: [[String]] = [tableCells(line)]
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).contains("|"),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }
            if isBullet(line) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isBullet(candidate) else { break }
                    items.append(String(candidate.dropFirst(2)))
                    index += 1
                }
                blocks.append(.bullets(items))
                continue
            }
            if numberedText(line) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = numberedText(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.numbered(items))
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (min(hashes, 3), String(line.dropFirst(hashes + 1)))
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func numberedText(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."),
              line[..<dot].allSatisfy(\.isNumber),
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " " else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "_" })
    }

    private static func isTableStart(lines: [String], index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let separator = tableCells(lines[index + 1])
        return !separator.isEmpty && separator.allSatisfy {
            let compact = $0.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "")
            return compact.count >= 3 && compact.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
