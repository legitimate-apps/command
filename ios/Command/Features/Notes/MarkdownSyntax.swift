//
//  MarkdownSyntax.swift
//  Command
//
//  The tokenizer behind the live-styled note editor. It answers one question: for a given
//  plain-text note, which BYTE RANGES are which markdown element?
//
//  Why hand-rolled instead of a package:
//   - A live editor needs SOURCE RANGES back (to hand NSAttributedString attributes to a
//     UITextView's storage). Renderer libraries (MarkdownUI et al) throw source positions away —
//     they hand back a view tree, which is useless for styling text in place.
//   - cmark-based parsers (apple/swift-markdown) DO keep source ranges, but they pull a C target
//     into a Mac-Catalyst App Store build for a job that is a few hundred lines of scanning, and
//     their ranges are line/column pairs that have to be re-mapped to UTF-16 offsets anyway.
//   - Hard rule 3 (lean) + full control over the "notebook" look argued for engineering it.
//
//  Scope, stated honestly: this is NOT a CommonMark-compliant parser and does not try to be. It
//  covers the constructs people actually type in notes — headings, emphasis, code, quotes, lists,
//  task lists, links, rules, tables — and it degrades to plain body text on anything exotic
//  (reference links, setext headings, HTML blocks, nested emphasis edge cases). A note editor's
//  failure mode for an unrecognized construct is "it stays plain text", which is harmless.
//
//  Everything here is UTF-16 offset math (`NSRange`/`NSString`) because that is the coordinate
//  system `UITextView`/`NSTextStorage` speak. Using `String.Index` here and converting later is
//  how off-by-one styling bugs get in.
//
//  Pure Foundation on purpose: no UIKit import, so the whole thing is unit-testable on its own.
//

import Foundation

// MARK: - Vocabulary

/// The kinds of styled run the editor knows how to draw. Deliberately flat (no associated values)
/// so it can be a dictionary key and cheap to compare; nesting/heading depth rides alongside in
/// `MDSpan.level`.
enum MDStyleKind: Equatable, Hashable {
    /// Line 1 of a note — its title by the app's single-field convention (see NoteDetailView).
    case title
    /// `#`…`######`; depth in `level` (1…6, clamped to 3 by the theme).
    case heading
    /// Ordinary paragraph text.
    case body
    case bold
    case italic
    case boldItalic
    case strikethrough
    /// `` `code` `` inside a line.
    case inlineCode
    /// A line INSIDE a ``` fence.
    case codeBlock
    /// A fence line itself. `level` 1 = opening, 2 = closing — they carry the block's outer spacing.
    case codeFence
    /// A `>` quoted line; nesting depth in `level`.
    case blockquote
    /// The text of any list item (bullet / ordered / task); nest depth in `level` (1-based).
    /// Carries the hanging indent, which is why it is distinct from `.body`.
    case listItem
    /// The literal `-` / `*` / `+` of a bullet.
    case bulletMarker
    /// The literal `1.` of an ordered item.
    case orderedMarker
    /// An unchecked `[ ]` task box.
    case taskBoxUnchecked
    /// A checked `[x]` task box.
    case taskBoxChecked
    /// The text of a *checked* task item, so done work visibly retires.
    case taskCheckedText
    /// The visible label of `[label](url)`.
    case link
    /// A `---` / `***` horizontal rule line.
    case rule
    /// A table's header row (the row above the `|---|` separator).
    case tableHeader
    /// An ordinary table body row.
    case tableCell
    /// The `|---|---|` separator row, collapsed to a divider.
    case tableSeparator
    /// The literal markdown punctuation itself (`#`, `**`, backticks, `>`, a link's `(url)`…).
    /// Drawn dimmed so the document reads as prose while the syntax stays visible and editable.
    case syntaxMarker
}

/// One styled run: a range of the source and what it is.
///
/// Spans are emitted **block first, then inline, then markers**, and the editor applies them in
/// that order. Later spans intentionally override earlier ones on overlapping ranges (a `**bold**`
/// run inside a heading keeps the heading's size but gains bold; the `**` markers on top of it get
/// the dimmed marker colour). That layering is the whole styling model — keep the emission order.
struct MDSpan: Equatable {
    let range: NSRange
    /// `var` only so the table-header back-patch pass can promote a `.tableCell` once the
    /// separator row below it proves it was a header. Nothing else mutates a span.
    var kind: MDStyleKind
    var level: Int = 0
}

// MARK: - Tokenizer

enum MarkdownSyntax {

    /// A UTF-16 code unit for an ASCII literal. (`UInt8` has `init(ascii:)`; `UInt16` doesn't, and
    /// the whole tokenizer works in UTF-16 to match `NSString` offsets.)
    @inline(__always)
    private static func u16(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }

    /// Tokenize a whole note. Linear in the length of the text; safe to call on every keystroke for
    /// notes of ordinary size (the editor additionally debounces — see MarkdownTextView).
    static func spans(in text: NSString) -> [MDSpan] {
        var out: [MDSpan] = []
        out.reserveCapacity(64)

        var inFence = false
        let lines = lineRanges(of: text)
        for (index, line) in lines.enumerated() {
            scan(line: line, isFirstLine: index == 0, in: text, inFence: &inFence, into: &out)
        }
        promoteTableHeaders(in: &out, lines: lines)
        return out
    }

    /// A markdown table's header is defined by what FOLLOWS it (the `|---|---|` separator), so it
    /// can only be identified after the fact. One back-patch pass keeps the line scanner
    /// single-pass and stateless.
    private static func promoteTableHeaders(in out: inout [MDSpan], lines: [NSRange]) {
        let separatorLocations = Set(out.filter { $0.kind == .tableSeparator }.map(\.range.location))
        guard !separatorLocations.isEmpty else { return }

        // Map each separator line back to the line above it.
        var headerLocations = Set<Int>()
        for (index, line) in lines.enumerated() where separatorLocations.contains(line.location) {
            guard index > 0 else { continue }
            headerLocations.insert(lines[index - 1].location)
        }
        for i in out.indices where out[i].kind == .tableCell && headerLocations.contains(out[i].range.location) {
            out[i].kind = .tableHeader
        }
    }

    // MARK: Line splitting

    /// Content ranges of every line (the trailing newline is excluded, so styling a line never
    /// bleeds a background colour across the line break).
    static func lineRanges(of s: NSString) -> [NSRange] {
        var result: [NSRange] = []
        guard s.length > 0 else { return result }
        var index = 0
        while index < s.length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            s.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                           for: NSRange(location: index, length: 0))
            result.append(NSRange(location: lineStart, length: contentsEnd - lineStart))
            if lineEnd <= index { break }   // defensive: never spin
            index = lineEnd
        }
        return result
    }

    // MARK: Block classification

    private static func scan(line: NSRange,
                             isFirstLine: Bool,
                             in s: NSString,
                             inFence: inout Bool,
                             into out: inout [MDSpan]) {
        let text = s.substring(with: line)
        let indent = leadingSpaces(text)
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // ``` fences bracket a literal region: everything inside is code, no inline parsing.
        // The fence lines are their own kind (level 1 = opening, 2 = closing) because they carry
        // the block's outer spacing — the code lines between them stay tight.
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            out.append(MDSpan(range: line, kind: .codeFence, level: inFence ? 2 : 1))
            inFence.toggle()
            return
        }
        if inFence {
            out.append(MDSpan(range: line, kind: .codeBlock))
            return
        }

        // The note's first line is its title regardless of syntax — but a `# Heading` on line 1
        // still gets its marker dimmed, so the user isn't left staring at a stray `#`.
        if isFirstLine {
            out.append(MDSpan(range: line, kind: .title))
            if let hashes = headingHashes(trimmed) {
                let markerLen = min(hashes + 1, line.length - indent)
                if markerLen > 0 {
                    out.append(MDSpan(range: NSRange(location: line.location + indent, length: markerLen),
                                      kind: .syntaxMarker))
                }
            }
            inlineSpans(in: s, line: line, into: &out)
            return
        }

        if trimmed.isEmpty {
            out.append(MDSpan(range: line, kind: .body))
            return
        }

        // Horizontal rule: three or more of the same -, * or _ and nothing else.
        if isRule(trimmed) {
            out.append(MDSpan(range: line, kind: .rule))
            return
        }

        // ATX heading.
        if let hashes = headingHashes(trimmed) {
            out.append(MDSpan(range: line, kind: .heading, level: hashes))
            let markerLen = min(hashes + 1, line.length - indent)     // the #'s plus its space
            if markerLen > 0 {
                out.append(MDSpan(range: NSRange(location: line.location + indent, length: markerLen),
                                  kind: .syntaxMarker))
            }
            inlineSpans(in: s, line: line, into: &out)
            return
        }

        // Blockquote.
        if trimmed.hasPrefix(">") {
            let depth = quoteDepth(trimmed)
            out.append(MDSpan(range: line, kind: .blockquote, level: depth))
            let markerLen = min(quoteMarkerLength(text, from: indent), line.length - indent)
            if markerLen > 0 {
                out.append(MDSpan(range: NSRange(location: line.location + indent, length: markerLen),
                                  kind: .syntaxMarker))
            }
            inlineSpans(in: s, line: line, into: &out)
            return
        }

        // Every list line carries `.listItem` (which owns the hanging indent) plus a marker span.
        // Nest depth is 1-based: two leading spaces = one level in, matching the editor's Tab unit.
        let nestLevel = indent / 2 + 1

        // Task list item — checked before plain bullet, since `- [x] ` is also a bullet.
        if let task = taskItem(text, indent: indent) {
            out.append(MDSpan(range: line, kind: .listItem, level: nestLevel))
            out.append(MDSpan(range: NSRange(location: line.location + indent, length: task.markerLength),
                              kind: task.checked ? .taskBoxChecked : .taskBoxUnchecked, level: nestLevel))
            let contentStart = line.location + indent + task.markerLength
            if task.checked, contentStart < NSMaxRange(line) {
                out.append(MDSpan(range: NSRange(location: contentStart,
                                                 length: NSMaxRange(line) - contentStart),
                                  kind: .taskCheckedText))
            }
            inlineSpans(in: s, line: line, into: &out)
            return
        }

        // Bullet list.
        if let markerLen = bulletMarkerLength(text, indent: indent) {
            out.append(MDSpan(range: line, kind: .listItem, level: nestLevel))
            out.append(MDSpan(range: NSRange(location: line.location + indent, length: markerLen),
                              kind: .bulletMarker, level: nestLevel))
            inlineSpans(in: s, line: line, into: &out)
            return
        }

        // Ordered list.
        if let markerLen = orderedMarkerLength(text, indent: indent) {
            out.append(MDSpan(range: line, kind: .listItem, level: nestLevel))
            out.append(MDSpan(range: NSRange(location: line.location + indent, length: markerLen),
                              kind: .orderedMarker, level: nestLevel))
            inlineSpans(in: s, line: line, into: &out)
            return
        }

        // Table row: pipe-delimited. Cheap heuristic — leading pipe and at least two of them.
        // A `|---|:--:|` separator row is emitted as such; `spans(in:)` then promotes the row
        // ABOVE it to a header (which is the only way to know a row was a header — you have to
        // have seen the separator that follows it).
        if trimmed.hasPrefix("|"), trimmed.filter({ $0 == "|" }).count >= 2 {
            out.append(MDSpan(range: line, kind: isTableSeparator(trimmed) ? .tableSeparator : .tableCell))
            if !isTableSeparator(trimmed) { inlineSpans(in: s, line: line, into: &out) }
            return
        }

        out.append(MDSpan(range: line, kind: .body))
        inlineSpans(in: s, line: line, into: &out)
    }

    // MARK: Inline scanning

    /// Emphasis, code spans, strikethrough and links inside one line.
    ///
    /// Order matters: code spans are found first and claim their characters, so `` `**not bold**` ``
    /// stays literal. Links are next (their URL half must not be emphasis-scanned). Emphasis runs
    /// last over whatever is left.
    private static func inlineSpans(in s: NSString, line: NSRange, into out: inout [MDSpan]) {
        guard line.length > 0 else { return }
        let chars = Array(s.substring(with: line).utf16)
        var claimed = [Bool](repeating: false, count: chars.count)
        let base = line.location

        // --- code spans: `x`, ``x`` ---
        var i = 0
        while i < chars.count {
            if chars[i] == u16("`") {
                let runStart = i
                var run = 0
                while i < chars.count, chars[i] == u16("`") { run += 1; i += 1 }
                // find a closing run of exactly the same length
                var j = i
                while j < chars.count {
                    if chars[j] == u16("`") {
                        var closeRun = 0
                        let closeStart = j
                        while j < chars.count, chars[j] == u16("`") { closeRun += 1; j += 1 }
                        if closeRun == run {
                            let full = NSRange(location: base + runStart, length: j - runStart)
                            out.append(MDSpan(range: full, kind: .inlineCode))
                            out.append(MDSpan(range: NSRange(location: base + runStart, length: run),
                                              kind: .syntaxMarker))
                            out.append(MDSpan(range: NSRange(location: base + closeStart, length: run),
                                              kind: .syntaxMarker))
                            for k in runStart..<j { claimed[k] = true }
                            i = j
                            break
                        }
                    } else {
                        j += 1
                    }
                }
                if j >= chars.count { i = runStart + run }   // unterminated: leave it plain
            } else {
                i += 1
            }
        }

        // --- links: [label](url) ---
        i = 0
        while i < chars.count {
            guard !claimed[i], chars[i] == u16("[") else { i += 1; continue }
            guard let closeBracket = index(of: u16("]"), from: i + 1, chars, claimed),
                  closeBracket + 1 < chars.count,
                  chars[closeBracket + 1] == u16("("),
                  let closeParen = index(of: u16(")"), from: closeBracket + 2, chars, claimed)
            else { i += 1; continue }

            if closeBracket > i + 1 {
                out.append(MDSpan(range: NSRange(location: base + i + 1, length: closeBracket - i - 1),
                                  kind: .link))
            }
            out.append(MDSpan(range: NSRange(location: base + i, length: 1), kind: .syntaxMarker))
            out.append(MDSpan(range: NSRange(location: base + closeBracket, length: 1), kind: .syntaxMarker))
            // The `(url)` half is plumbing, not content — same dimmed treatment as `**` or `#`.
            out.append(MDSpan(range: NSRange(location: base + closeBracket + 1,
                                             length: closeParen - closeBracket),
                              kind: .syntaxMarker))
            for k in i...closeParen { claimed[k] = true }
            i = closeParen + 1
        }

        // --- strikethrough: ~~x~~ ---
        emphasis(marker: u16("~"), runLength: 2, kind: .strikethrough,
                 chars: chars, claimed: &claimed, base: base, out: &out)
        // --- bold+italic / bold / italic ---
        emphasis(marker: u16("*"), runLength: 3, kind: .boldItalic,
                 chars: chars, claimed: &claimed, base: base, out: &out)
        emphasis(marker: u16("*"), runLength: 2, kind: .bold,
                 chars: chars, claimed: &claimed, base: base, out: &out)
        emphasis(marker: u16("_"), runLength: 2, kind: .bold,
                 chars: chars, claimed: &claimed, base: base, out: &out)
        emphasis(marker: u16("*"), runLength: 1, kind: .italic,
                 chars: chars, claimed: &claimed, base: base, out: &out)
        emphasis(marker: u16("_"), runLength: 1, kind: .italic,
                 chars: chars, claimed: &claimed, base: base, out: &out)
    }

    /// Find `<marker×n> … <marker×n>` pairs that aren't already claimed, emit the content span plus
    /// dimmed marker spans, and claim the characters so a shorter run doesn't re-match inside.
    private static func emphasis(marker: UInt16,
                                 runLength: Int,
                                 kind: MDStyleKind,
                                 chars: [UInt16],
                                 claimed: inout [Bool],
                                 base: Int,
                                 out: inout [MDSpan]) {
        var i = 0
        while i + runLength * 2 <= chars.count {
            guard !claimed[i], matchesRun(chars, at: i, marker: marker, length: runLength, claimed: claimed)
            else { i += 1; continue }
            // An opening delimiter must be followed by content, not whitespace.
            let contentStart = i + runLength
            if contentStart >= chars.count || isSpace(chars[contentStart]) { i += 1; continue }

            var j = contentStart
            var found = -1
            while j + runLength <= chars.count {
                if !claimed[j], matchesRun(chars, at: j, marker: marker, length: runLength, claimed: claimed),
                   !isSpace(chars[j - 1]) {
                    found = j
                    break
                }
                j += 1
            }
            guard found > contentStart else { i += 1; continue }

            out.append(MDSpan(range: NSRange(location: base + contentStart, length: found - contentStart),
                              kind: kind))
            out.append(MDSpan(range: NSRange(location: base + i, length: runLength), kind: .syntaxMarker))
            out.append(MDSpan(range: NSRange(location: base + found, length: runLength), kind: .syntaxMarker))
            for k in i..<(found + runLength) { claimed[k] = true }
            i = found + runLength
        }
    }

    private static func matchesRun(_ chars: [UInt16], at i: Int, marker: UInt16,
                                   length: Int, claimed: [Bool]) -> Bool {
        guard i + length <= chars.count else { return false }
        for k in i..<(i + length) where chars[k] != marker || claimed[k] { return false }
        // Must not be part of a LONGER run of the same marker (so `**` doesn't match inside `***`).
        if i > 0, chars[i - 1] == marker { return false }
        if i + length < chars.count, chars[i + length] == marker { return false }
        return true
    }

    private static func index(of ch: UInt16, from: Int, _ chars: [UInt16], _ claimed: [Bool]) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == ch, !claimed[i] { return i }
            i += 1
        }
        return nil
    }

    private static func isSpace(_ c: UInt16) -> Bool {
        c == u16(" ") || c == u16("\t")
    }

    // MARK: Small line predicates

    private static func leadingSpaces(_ s: String) -> Int {
        var n = 0
        for c in s.utf16 {
            if c == u16(" ") { n += 1 }
            else if c == u16("\t") { n += 2 }
            else { break }
        }
        return n
    }

    /// Number of leading `#` if this is an ATX heading (`# ` … `###### `), else nil.
    private static func headingHashes(_ trimmed: String) -> Int? {
        var n = 0
        for c in trimmed {
            if c == "#" { n += 1; if n > 6 { return nil } } else { break }
        }
        guard n > 0 else { return nil }
        let rest = trimmed.dropFirst(n)
        guard rest.isEmpty || rest.first == " " else { return nil }   // `#tag` is not a heading
        return n
    }

    /// `|---|:---:|` — the row that separates a table's header from its body. Only pipes, dashes,
    /// colons and spaces.
    private static func isTableSeparator(_ trimmed: String) -> Bool {
        var sawDash = false
        for c in trimmed {
            switch c {
            case "-": sawDash = true
            case "|", ":", " ": continue
            default: return false
            }
        }
        return sawDash
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        var count = 0
        for c in trimmed {
            if c == first { count += 1 } else if c != " " { return false }
        }
        return count >= 3
    }

    private static func quoteDepth(_ trimmed: String) -> Int {
        var depth = 0
        for c in trimmed {
            if c == ">" { depth += 1 } else if c != " " { break }
        }
        return depth
    }

    /// Length of the `> ` / `>> ` run at the start of the line, including one trailing space.
    private static func quoteMarkerLength(_ line: String, from indent: Int) -> Int {
        let units = Array(line.utf16)
        var i = indent
        while i < units.count, units[i] == u16(">") || units[i] == u16(" ") {
            i += 1
        }
        return i - indent
    }

    /// `- `, `* `, `+ ` → length of the marker including its space.
    private static func bulletMarkerLength(_ line: String, indent: Int) -> Int? {
        let units = Array(line.utf16)
        guard indent < units.count else { return nil }
        let c = units[indent]
        guard c == u16("-") || c == u16("*") || c == u16("+") else { return nil }
        guard indent + 1 < units.count, units[indent + 1] == u16(" ") else { return nil }
        return 2
    }

    /// `1. ` / `12) ` → length of the marker including its space.
    private static func orderedMarkerLength(_ line: String, indent: Int) -> Int? {
        let units = Array(line.utf16)
        var i = indent
        var digits = 0
        while i < units.count, units[i] >= u16("0"), units[i] <= u16("9") {
            digits += 1; i += 1
        }
        guard digits > 0, i < units.count else { return nil }
        guard units[i] == u16(".") || units[i] == u16(")") else { return nil }
        i += 1
        guard i < units.count, units[i] == u16(" ") else { return nil }
        return i - indent + 1
    }

    /// `- [ ] ` / `- [x] ` → its length and checked state.
    private static func taskItem(_ line: String, indent: Int) -> (markerLength: Int, checked: Bool)? {
        guard bulletMarkerLength(line, indent: indent) != nil else { return nil }
        let units = Array(line.utf16)
        let boxStart = indent + 2
        guard boxStart + 2 < units.count,
              units[boxStart] == u16("["),
              units[boxStart + 2] == u16("]") else { return nil }
        let mark = units[boxStart + 1]
        let checked: Bool
        if mark == u16("x") || mark == u16("X") { checked = true }
        else if mark == u16(" ") { checked = false }
        else { return nil }
        // A just-typed `- [x]` has no trailing space yet; treat end-of-line as a valid terminator so
        // the box styles the moment it's closed rather than one keystroke later.
        let hasSpace = boxStart + 3 < units.count && units[boxStart + 3] == u16(" ")
        if boxStart + 3 < units.count && !hasSpace { return nil }
        return (boxStart + (hasSpace ? 4 : 3) - indent, checked)
    }
}

// MARK: - Plain text (list rows, previews, VoiceOver, share sheets)

extension MarkdownSyntax {
    /// Markdown source → the prose a human reads: syntax punctuation removed, content kept.
    ///
    /// Anywhere the app shows note text in a context that can't render styling — a list row's two
    /// line preview, an accessibility label, a share sheet — showing `## Plan` or `**urgent**`
    /// leaks the source at the user. This strips exactly the punctuation the editor draws dimmed
    /// (`#`, `**`, backticks, `>`, the `(url)` half of a link) and keeps everything else, including
    /// list bullets, which carry real structure.
    ///
    /// `singleLine` additionally collapses runs of whitespace, for one-line contexts.
    static func plainText(_ source: String, singleLine: Bool = false) -> String {
        let ns = source as NSString
        guard ns.length > 0 else { return "" }

        // Ranges to delete outright: the dimmed punctuation and link URLs.
        var drop = [Bool](repeating: false, count: ns.length)
        for span in spans(in: ns) {
            switch span.kind {
            case .syntaxMarker, .rule, .codeFence, .tableSeparator:
                // Dimmed punctuation, `---` rules and fence lines carry no prose.
                for i in span.range.location..<min(NSMaxRange(span.range), ns.length) { drop[i] = true }
            case .taskBoxChecked, .taskBoxUnchecked:
                // `- [x] ` → `- `, so the preview reads as a list rather than as source.
                let keep = span.range.location + 2      // the "- "
                for i in keep..<min(NSMaxRange(span.range), ns.length) { drop[i] = true }
            default:
                break
            }
        }

        var kept = [UInt16]()
        kept.reserveCapacity(ns.length)
        for i in 0..<ns.length where !drop[i] {
            kept.append(ns.character(at: i))
        }
        let stripped = String(utf16CodeUnits: kept, count: kept.count)

        guard singleLine else {
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Editing helpers used by the editor's keyboard behaviours

extension MarkdownSyntax {
    /// What a Return keypress should auto-insert to continue the current list, if anything.
    ///
    /// Typing a list is the single most common markdown interaction in a notes app; making the user
    /// re-type `- ` on every line is the difference between "supports markdown" and "good editor".
    /// Returns nil for a non-list line. Returns an EMPTY string for an empty list item, which the
    /// caller treats as "the user pressed Return on a blank bullet — end the list instead".
    static func listContinuation(forLineAt caret: Int, in s: NSString) -> String? {
        guard s.length > 0 else { return nil }
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        let probe = NSRange(location: min(caret, s.length), length: 0)
        s.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: probe)
        let line = s.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let indent = leadingSpaces(line)
        let pad = String(repeating: " ", count: indent)

        if let task = taskItem(line, indent: indent) {
            let contentLength = line.utf16.count - indent - task.markerLength
            return contentLength <= 0 ? "" : pad + "- [ ] "
        }
        if bulletMarkerLength(line, indent: indent) != nil {
            let units = Array(line.utf16)
            let bullet = String(utf16CodeUnits: [units[indent]], count: 1)
            let contentLength = units.count - indent - 2
            return contentLength <= 0 ? "" : pad + bullet + " "
        }
        if let markerLen = orderedMarkerLength(line, indent: indent) {
            let units = Array(line.utf16)
            var digits = ""
            var i = indent
            while i < units.count, units[i] >= u16("0"), units[i] <= u16("9") {
                digits.append(String(utf16CodeUnits: [units[i]], count: 1)); i += 1
            }
            let delimiter = String(utf16CodeUnits: [units[i]], count: 1)
            let contentLength = units.count - indent - markerLen
            if contentLength <= 0 { return "" }
            let next = (Int(digits) ?? 1) + 1
            return pad + "\(next)" + delimiter + " "
        }
        return nil
    }

    /// The range of the whole list marker on the line containing `caret` — what "end the list"
    /// deletes when Return is pressed on an empty bullet.
    static func listMarkerRange(forLineAt caret: Int, in s: NSString) -> NSRange? {
        guard s.length > 0 else { return nil }
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        s.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                       for: NSRange(location: min(caret, s.length), length: 0))
        let range = NSRange(location: lineStart, length: contentsEnd - lineStart)
        guard range.length > 0 else { return nil }
        let line = s.substring(with: range)
        let indent = leadingSpaces(line)
        if let task = taskItem(line, indent: indent) {
            return NSRange(location: lineStart, length: indent + task.markerLength)
        }
        if bulletMarkerLength(line, indent: indent) != nil {
            return NSRange(location: lineStart, length: indent + 2)
        }
        if let markerLen = orderedMarkerLength(line, indent: indent) {
            return NSRange(location: lineStart, length: indent + markerLen)
        }
        return nil
    }

    /// Toggle a `- [ ]` / `- [x]` checkbox on the line containing `caret`.
    /// Returns the range of the single character to replace and its replacement, or nil if the
    /// line isn't a task item.
    static func taskToggle(forLineAt caret: Int, in s: NSString) -> (range: NSRange, replacement: String)? {
        guard s.length > 0 else { return nil }
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        s.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                       for: NSRange(location: min(caret, s.length), length: 0))
        let line = s.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let indent = leadingSpaces(line)
        guard let task = taskItem(line, indent: indent) else { return nil }
        let markChar = lineStart + indent + 3          // "- [" is 3 units past the indent
        _ = task
        let current = s.substring(with: NSRange(location: markChar, length: 1))
        return (NSRange(location: markChar, length: 1), current == " " ? "x" : " ")
    }
}
