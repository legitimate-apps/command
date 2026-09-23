//
//  MarkdownView.swift
//  Command
//
//  A lightweight, in-house block-markdown renderer for assistant replies. Real answers
//  lean on tables, headings, bullet/number lists, fenced code, block quotes, and rules —
//  none of which `AttributedString`'s inline-only parser renders (it leaves the raw pipes,
//  `###`, and `|---|` on screen). This parses the message into blocks and lays them out in
//  the app's paper-and-ink language, using `AttributedString` for the *inline* span inside
//  each block (bold / italic / `code` / links).
//
//  Design constraints (see the E-workstream spec):
//   • No heavy SPM dependency — this is a few hundred lines, offline, no project.yml churn.
//   • Degrades gracefully: any line that isn't a recognized block becomes a paragraph, and a
//     failed inline parse falls back to the plain string. It never throws.
//   • Streams smoothly: parsing is a pure function over the full text, cheap to re-run as
//     deltas arrive. Half-typed structures (an unclosed code fence, a table whose separator
//     row hasn't streamed yet) render as sensible text until the rest lands, then snap in.
//

import SwiftUI

// MARK: - Block model (internal so unit tests can assert the parse)

enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])          // each element is one item's inline markdown
    case orderedList([String])         // ditto; rendered with a running 1. 2. 3. …
    case code(String)                  // fenced or indented; shown verbatim, monospaced
    case quote(String)                 // one or more `>` lines, joined
    case rule
    case table(header: [String], rows: [[String]])
}

// MARK: - Parser (pure, testable)

enum MarkdownParser {
    /// Parse Markdown text into a flat list of blocks. Never throws; unknown input degrades
    /// to paragraphs.
    static func parse(_ text: String) -> [MDBlock] {
        // Normalize line endings; keep empty lines (they separate paragraphs).
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var i = 0
        let n = lines.count

        func flushParagraph(_ buf: inout [String]) {
            guard !buf.isEmpty else { return }
            let joined = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            buf.removeAll(keepingCapacity: true)
        }

        var para: [String] = []

        while i < n {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block: ``` (or ~~~). Consume until the matching closing fence, or —
            // mid-stream — to the end of input so streamed code renders as code immediately.
            if let fence = codeFence(line) {
                flushParagraph(&para)
                var body: [String] = []
                i += 1
                while i < n {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if codeFence(l) == fence { i += 1; break }   // closing fence
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            // Blank line: paragraph boundary.
            if line.isEmpty {
                flushParagraph(&para)
                i += 1
                continue
            }

            // Horizontal rule: --- / *** / ___ (≥3, only that char + spaces). Guard against a
            // table separator (has pipes) and a bullet ("- x").
            if isRule(line) {
                flushParagraph(&para)
                blocks.append(.rule)
                i += 1
                continue
            }

            // GitHub pipe table: a header line containing a pipe, immediately followed by a
            // separator row (only -, :, |, spaces, with at least one dash).
            if line.contains("|"), i + 1 < n, isTableSeparator(lines[i + 1]) {
                flushParagraph(&para)
                let header = tableCells(line)
                var rows: [[String]] = []
                i += 2   // skip header + separator
                while i < n {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.contains("|"), !l.isEmpty else { break }
                    rows.append(tableCells(l))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // ATX heading: 1–6 leading '#' then a space.
            if let h = heading(line) {
                flushParagraph(&para)
                blocks.append(h)
                i += 1
                continue
            }

            // Block quote: consecutive `>` lines.
            if line.hasPrefix(">") {
                flushParagraph(&para)
                var quoted: [String] = []
                while i < n {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    quoted.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // Unordered list: -, *, or + then a space.
            if isBullet(line) {
                flushParagraph(&para)
                var items: [String] = []
                while i < n {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isBullet(l) else { break }
                    items.append(String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list: "1." or "1)" then a space.
            if isOrdered(line) {
                flushParagraph(&para)
                var items: [String] = []
                while i < n {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let item = orderedItem(l) else { break }
                    items.append(item)
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Plain text — accumulate into the current paragraph.
            para.append(line)
            i += 1
        }
        flushParagraph(&para)
        return blocks
    }

    // MARK: line classifiers

    private static func codeFence(_ line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let s = line.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3 else { return false }
        return s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" }
    }

    private static func heading(_ line: String) -> MDBlock? {
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }
        let first = line.first!
        guard first == "-" || first == "*" || first == "+" else { return false }
        return line[line.index(line.startIndex, offsetBy: 1)] == " "
    }

    private static func isOrdered(_ line: String) -> Bool { orderedItem(line) != nil }

    /// The text after an ordered-list marker ("1. foo" → "foo"), or nil if the line isn't one.
    private static func orderedItem(_ line: String) -> String? {
        var idx = line.startIndex
        var digits = 0
        while idx < line.endIndex, line[idx].isNumber { idx = line.index(after: idx); digits += 1 }
        guard digits > 0, idx < line.endIndex else { return nil }
        let delim = line[idx]
        guard delim == "." || delim == ")" else { return nil }
        let after = line.index(after: idx)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableSeparator(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("-") else { return false }
        // Only pipes, dashes, colons, and spaces — and at least one dash.
        return line.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Split a pipe-table row into trimmed cells, dropping the leading/trailing empties that
    /// come from the optional outer pipes (`| a | b |`).
    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }
}

// MARK: - Inline (bold / italic / code / links) → AttributedString

enum MarkdownInline {
    /// Parse a single block's inline markdown into a styled `AttributedString`. SwiftUI's
    /// `Text` natively renders the strong/emphasis/strikethrough/link intents; we additionally
    /// give inline `code` a monospaced font + faint surface so it reads as code. Falls back to
    /// the plain string if the (rare) inline parse fails.
    static func attributed(_ s: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)

        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].font = .system(.callout, design: .monospaced)
            attr[run.range].backgroundColor = Palette.hairline
        }
        return attr
    }
}

// MARK: - View

/// Render a Markdown string in the paper-and-ink language. Drop-in for a plain `Text`.
struct MarkdownView: View {
    let text: String
    /// The base ink; failed/error bubbles pass red so the whole reply reads as failed.
    var tint: Color = Palette.ink

    private var blocks: [MDBlock] { MarkdownParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text))
                .font(Typeface.display(headingSize(level)))
                .foregroundStyle(tint)
                .padding(.top, level <= 2 ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .font(Typeface.body(16))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: Text("•").foregroundStyle(Palette.accent).accessibilityHidden(true), item)
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    listRow(
                        marker: Text("\(idx + 1).")
                            .font(Typeface.body(15, .semibold))
                            .foregroundStyle(Palette.accent),
                        item)
                }
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3)
                Text(MarkdownInline.attributed(text))
                    .font(Typeface.body(15))
                    .italic()
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 4)

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, tint: tint)
        }
    }

    private func listRow(marker: some View, _ item: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            marker.frame(minWidth: 16, alignment: .trailing)
            Text(MarkdownInline.attributed(item))
                .font(Typeface.body(16))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 19
        case 3: return 17
        default: return 15
        }
    }
}

// MARK: - Table

/// A pipe table rendered with hairline borders + zebra rows, scrollable horizontally so a
/// wide table never forces the chat bubble (or the page) to scroll sideways.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let tint: Color

    private var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { c in
                        cell(header[safe: c] ?? "", weight: .semibold)
                            .background(Palette.accentSoft)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { c in
                            cell(row[safe: c] ?? "", weight: .regular)
                                .background(r.isMultiple(of: 2) ? Palette.surface : Color.clear)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func cell(_ text: String, weight: Font.Weight) -> some View {
        Text(MarkdownInline.attributed(text))
            .font(Typeface.body(14, weight))
            .foregroundStyle(tint)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 64, maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .overlay(Rectangle().stroke(Palette.hairline, lineWidth: 0.5))
    }
}

private extension Array {
    /// Bounds-checked subscript — a ragged table row (fewer cells than the header) reads as
    /// empty rather than crashing.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
