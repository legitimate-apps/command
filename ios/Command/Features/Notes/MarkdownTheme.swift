//
//  MarkdownTheme.swift
//  Command
//
//  The live markdown editor's stylesheet, encoded as `NSAttributedString` attributes for the
//  UITextView at the heart of the note editor. The design rationale and the chrome (toolbar)
//  spec live in docs/design/2026-07-21-markdown-editor-design.md — this file is the values,
//  each with the WHY, in the same voice as Theme.swift.
//
//  Ground rules:
//   • Colors MIRROR Palette's sRGB triples as trait-resolving UIColors. `UIColor(Palette.ink)`
//     freezes whichever variant is current at the call site; the dynamic-provider initializer
//     keeps light AND dark correct when the system flips traits under a live editor.
//   • Fonts scale through `UIFontMetrics(forTextStyle: .body)` exactly like Typeface, so the
//     editor honors Dynamic Type, bounded by RootView's app-wide clamp. An attributed string
//     holds concrete font instances, so the ENGINE re-applies these attributes when the
//     content size category changes — `adjustsFontForContentSizeCategory` does not reach
//     inside an existing text storage.
//   • Inline kinds carry font + color (+ decoration) only; BLOCK kinds add a paragraph style.
//     Layering an inline span over its line's block attributes is the engine's job — an
//     inline range must never fight the paragraph for indentation.
//

import SwiftUI
import UIKit

enum MarkdownTheme {

    // NOTE: the style vocabulary (`MDStyleKind`) is declared once, next to the tokenizer that
    // emits it, in MarkdownSyntax.swift. Theme and tokenizer MUST agree on it, so it has exactly
    // one definition; this file supplies the values for each case.

    // MARK: - Colors (Palette mirrored as trait-resolving UIColors)

    /// Palette.paper — the editor background (also exported to SwiftUI below).
    static let paper = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.102, green: 0.090, blue: 0.078, alpha: 1)
            : UIColor(red: 0.965, green: 0.949, blue: 0.918, alpha: 1)
    }

    /// Palette.ink — primary text.
    static let ink = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.925, green: 0.890, blue: 0.839, alpha: 1)
            : UIColor(red: 0.129, green: 0.110, blue: 0.086, alpha: 1)
    }

    /// Palette.inkSecondary — quotes, metadata, struck/done text.
    static let inkSecondary = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.663, green: 0.620, blue: 0.549, alpha: 1)
            : UIColor(red: 0.420, green: 0.384, blue: 0.325, alpha: 1)
    }

    /// Palette.accent — the one accent, burnt amber. Caret, list markers, links, task boxes.
    static let accent = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.878, green: 0.518, blue: 0.227, alpha: 1)
            : UIColor(red: 0.706, green: 0.345, blue: 0.086, alpha: 1)
    }

    /// Palette.surface — raised paper; the code-block wash.
    static let surface = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.125, blue: 0.098, alpha: 1)
            : UIColor(red: 0.988, green: 0.980, blue: 0.965, alpha: 1)
    }

    /// Palette.sage — done states (checked task boxes).
    static let sage = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.560, green: 0.660, blue: 0.525, alpha: 1)
            : UIColor(red: 0.360, green: 0.450, blue: 0.330, alpha: 1)
    }

    /// Palette.hairline — 9% ink, the inline-code background wash (matches the chat renderer).
    static let hairline = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.09)
            : UIColor(white: 0, alpha: 0.09)
    }

    /// Palette.accentSoft — the amber wash behind table header rows / toggle fills.
    /// `withAlphaComponent` on a dynamic color stays dynamic, so this adapts too.
    static let accentSoft = accent.withAlphaComponent(0.12)

    /// Syntax-marker inks: machine-only characters (`**`, backticks, `>`, `[…](…)`) fade so
    /// the styled content owns the line, but NEVER disappear — the screen must keep telling
    /// the truth about what's stored (storage is plain markdown, and line 1 is the title by
    /// convention: hiding characters would hide the model from the user). 45% idle; 75% on
    /// the caret's line, where precise edits need a crisp target.
    static let syntax = inkSecondary.withAlphaComponent(0.45)
    static let syntaxActive = inkSecondary.withAlphaComponent(0.75)

    /// The rule line's ink — faint enough to read as one pencil line once letterspaced.
    static let ruleInk = ink.withAlphaComponent(0.16)

    // MARK: - Fonts (Typeface's recipe, as UIFonts)

    /// Editorial display serif (New York) at a reference size, Dynamic-Type scaled — the same
    /// construction as `Typeface.display`, kept here so the editor never round-trips through a
    /// SwiftUI `Font`. Semibold is the display default, as in Theme.swift.
    static func display(_ size: CGFloat, _ weight: UIFont.Weight = .semibold) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let serif = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: serif)
    }

    /// Primary sans for content the user reads and writes — `Typeface.body`'s twin.
    static func body(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    /// Monospaced for code. Sized a touch under body (15 vs 17) because SF Mono's large
    /// x-height makes same-size mono shout next to prose.
    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: weight))
    }

    /// Add the italic trait WITHOUT losing metrics scaling — deriving from the already-scaled
    /// font preserves its point size, so italics stay Dynamic-Type correct. (Weight is a
    /// `systemFont` parameter, but italic only exists as a symbolic trait.)
    private static func italicized(_ font: UIFont) -> UIFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    // MARK: - Attributes

    /// The attribute dictionary for one range, at reference (default Dynamic Type) sizes —
    /// UIFontMetrics scales from there. Block kinds include a paragraph style; inline kinds
    /// deliberately don't: they layer over the line's block attributes.
    static func attributes(for kind: MDStyleKind, level: Int = 1) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .title:
            // 28pt serif — clearly the page's name, but a note, not a billboard: well clear of
            // H1 so a `#` typed in the body never outranks line 1.
            return [.font: display(28),
                    .foregroundColor: ink,
                    .paragraphStyle: paragraph(lineSpacing: 2, after: 10)]

        case .heading:
            let level = max(1, min(3, level))
            // 24/20/17 — the chat renderer's 22/19/17 grown one step for a full-page canvas.
            // H3 sits AT body size on purpose: serif + semibold + spacing carry it, the same
            // move Bear/Obsidian make for deep headings in notes.
            let size, before, after: CGFloat
            switch level {
            case 1:  size = 24; before = 14; after = 6
            case 2:  size = 20; before = 12; after = 4
            default: size = 17; before = 10; after = 3
            }
            return [.font: display(size),
                    .foregroundColor: ink,
                    .paragraphStyle: paragraph(lineSpacing: 2, before: before, after: after)]

        case .body:
            // 17pt with 5pt leading ≈ 1.3 line height — notebook airiness. A gentle 4pt after
            // keeps hard-wrapped lines one visual block while lists of thoughts don't crowd.
            return [.font: body(17),
                    .foregroundColor: ink,
                    .paragraphStyle: paragraph(lineSpacing: 5, after: 4)]

        case .bold:
            return [.font: body(17, .bold), .foregroundColor: ink]

        case .italic:
            return [.font: italicized(body(17)), .foregroundColor: ink]

        case .boldItalic:
            return [.font: italicized(body(17, .bold)), .foregroundColor: ink]

        case .inlineCode:
            // Hairline wash matches MarkdownView's inline code, so chat and editor speak
            // one language.
            return [.font: mono(15),
                    .foregroundColor: ink,
                    .backgroundColor: hairline]

        case .codeBlock:
            // Surface wash + 12pt insets read as the chat code card. NSBackgroundColor fills
            // line boxes, so the rounded corners are the engine's (optional) decoration pass;
            // the tail inset keeps long lines off the wash's right edge.
            return [.font: mono(15),
                    .foregroundColor: ink,
                    .backgroundColor: surface,
                    .paragraphStyle: paragraph(lineSpacing: 3,
                                               headIndent: Metrics.codeInset,
                                               tailIndent: -Metrics.codeInset)]

        case .codeFence:
            // Fences are 12pt dimmed mono and CARRY the block's outer spacing (10pt above the
            // opening fence, 10 below the closing one) so code lines inside stay tight while
            // the block as a whole still breathes against prose.
            let opening = level != 2
            return [.font: mono(12),
                    .foregroundColor: syntax,
                    .backgroundColor: surface,
                    .paragraphStyle: paragraph(lineSpacing: 3,
                                               before: opening ? 10 : 0,
                                               after: opening ? 0 : 10,
                                               headIndent: Metrics.codeInset,
                                               tailIndent: -Metrics.codeInset)]

        case .blockquote:
            // The app's quote voice — italic secondary ink, as in the chat renderer — at 16pt
            // because quotes here are AUTHORED, not just read: composing in chat's 15pt italic
            // is tiring. The 16pt gutter leaves room for the 3pt amber bar the engine draws.
            return [.font: italicized(body(16)),
                    .foregroundColor: inkSecondary,
                    .paragraphStyle: paragraph(lineSpacing: 4, before: 4, after: 4,
                                               headIndent: Metrics.quoteIndent,
                                               firstLineHeadIndent: Metrics.quoteIndent)]

        case .listItem:
            let level = max(1, min(3, level))
            // Hanging indent: the marker owns the gutter, wrapped lines align to the text —
            // 24pt per nest level (L1: marker 0 / text 24, L2: 24/48, L3: 48/72).
            let textX = Metrics.listIndent * CGFloat(level)
            let markerX = Metrics.listIndent * CGFloat(level - 1)
            return [.font: body(17),
                    .foregroundColor: ink,
                    .paragraphStyle: paragraph(lineSpacing: 5, after: 2,
                                               headIndent: textX,
                                               firstLineHeadIndent: markerX)]

        case .bulletMarker:
            // Elevated, not dimmed: the literal `-` IS the bullet on the rendered page.
            return [.font: body(17), .foregroundColor: accent]

        case .orderedMarker:
            return [.font: body(17, .semibold), .foregroundColor: accent]

        case .taskBoxUnchecked:
            return [.font: body(17), .foregroundColor: accent]

        case .taskBoxChecked:
            return [.font: body(17), .foregroundColor: sage]

        case .taskCheckedText:
            return [.font: body(17),
                    .foregroundColor: inkSecondary,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: inkSecondary.withAlphaComponent(0.6)]

        case .link:
            // The underline is load-bearing, not decorative: light-mode amber computes to
            // ≈4.3:1 on paper — under the 4.5 AA line for small text — so the link must never
            // rely on color alone.
            return [.font: body(17),
                    .foregroundColor: accent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: accent.withAlphaComponent(0.5)]

        case .strikethrough:
            return [.font: body(17),
                    .foregroundColor: inkSecondary,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue]

        case .rule:
            // Letterspacing stretches the three dashes toward a continuous pencil rule; the
            // 16% ink keeps it a divider, not content. The dashes stay literal — honest text.
            return [.font: body(17),
                    .foregroundColor: ruleInk,
                    .kern: 4,
                    .paragraphStyle: paragraph(before: 6, after: 6)]

        case .tableHeader:
            // 15pt like the chat table's cells (grown from 14 for the page), accentSoft wash
            // exactly like the chat table's header.
            return [.font: body(15, .semibold),
                    .foregroundColor: ink,
                    .backgroundColor: accentSoft,
                    .paragraphStyle: paragraph(lineSpacing: 4, before: 8)]

        case .tableCell:
            return [.font: body(15),
                    .foregroundColor: ink,
                    .paragraphStyle: paragraph(lineSpacing: 4)]

        case .tableSeparator:
            // Collapsed: a 6pt row of dimmed pipes/dashes reads as the divider under the
            // header while staying honest, editable text. Its 8pt after is the table's
            // bottom margin.
            return [.font: body(6),
                    .foregroundColor: syntax,
                    .paragraphStyle: paragraph(after: 8)]

        case .syntaxMarker:
            // The engine normally styles markers via `syntaxMarkerAttributes(base:activeLine:)`,
            // which INHERITS the surrounding font so dimming can never reflow the line. This
            // standalone entry is the fallback for non-editor callers (previews, tests) that ask
            // for a marker's attributes without a base to inherit.
            return [.font: body(17), .foregroundColor: syntax]
        }
    }

    // MARK: - Syntax markers

    /// Marker treatment for one range: inherit the range's font and indent (so applying the
    /// dim NEVER reflows — same glyph advances, same line breaks, the caret never jumps),
    /// recolor to the syntax ink, and strip decorations a marker shouldn't wear (a `~~`
    /// shouldn't strike itself, a backtick shouldn't wear the code wash).
    ///
    /// `activeLine` is true when the caret sits in the marker's paragraph: markers firm up to
    /// 75% there so precise edits have a crisp target. The engine applies this on
    /// `textViewDidChangeSelection` to the old and new active paragraphs only — a two-line
    /// restyle, never a full pass.
    static func syntaxMarkerAttributes(base: [NSAttributedString.Key: Any],
                                       activeLine: Bool) -> [NSAttributedString.Key: Any] {
        var attrs = base
        attrs[.foregroundColor] = activeLine ? syntaxActive : syntax
        attrs.removeValue(forKey: .backgroundColor)
        attrs.removeValue(forKey: .strikethroughStyle)
        attrs.removeValue(forKey: .underlineStyle)
        attrs.removeValue(forKey: .kern)
        return attrs
    }

    // MARK: - Metrics (shared by the engine's layout and decoration passes)

    enum Metrics {
        /// Maximum text column on iPad/Mac — ≈68–72 characters of 17pt prose, the comfortable
        /// reading measure. Wider than that the column pins at 640 and CENTERS on the paper
        /// (flat — no page card; this is a notebook, not a skeuomorphic sheet).
        static let maxColumnWidth: CGFloat = 640
        /// Side margin on iPhone (and any window narrower than 640 + 2×regularMargin).
        static let compactMargin: CGFloat = 20
        /// Side margin on iPad/Mac until the 640 column takes over.
        static let regularMargin: CGFloat = 28
        /// Bottom breathing room so the last line clears the accessory bar.
        static let bottomInset: CGFloat = 48
        /// Per-level list indent — the marker gutter and wrapped-text alignment unit.
        static let listIndent: CGFloat = 24
        /// Code-block horizontal inset (head, and negated for tail).
        static let codeInset: CGFloat = 12
        /// Blockquote text indent — the gutter the amber bar sits in.
        static let quoteIndent: CGFloat = 16
        /// The quote bar's width (engine-drawn, in `accent`).
        static let quoteBarWidth: CGFloat = 3
    }

    // MARK: - SwiftUI bridge

    /// Paper background for the host view, from the same UIColor so trait changes track.
    static var paperColor: Color { Color(uiColor: paper) }

    /// The UITextView's `tintColor`: system caret renders amber, and the selection highlight
    /// is the system's tint-at-~20% derived from it. (Find-highlight, if added later, should
    /// use `accentSoft` at 12% so matches never masquerade as a selection.)
    static var caretTint: UIColor { accent }

    // MARK: - Paragraph styles

    /// One builder so every kind above states its spacing declaratively. `firstLineHeadIndent`
    /// defaults to `headIndent` (a plain block); list items pass both to hang the marker.
    private static func paragraph(lineSpacing: CGFloat = 0,
                                  before: CGFloat = 0,
                                  after: CGFloat = 0,
                                  headIndent: CGFloat = 0,
                                  firstLineHeadIndent: CGFloat? = nil,
                                  tailIndent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHeadIndent ?? headIndent
        style.tailIndent = tailIndent
        return style
    }
}
