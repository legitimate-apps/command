//
//  MarkdownTextView.swift
//  Command
//
//  The live-styled markdown editor surface: a `UITextView` that restyles itself as you type, so
//  `# Heading` reads as a heading WHILE the source stays plain markdown text.
//
//  Why UIKit and not SwiftUI's `TextEditor`:
//  `TextEditor` takes a `String` and one uniform `.font`. It has no attributed-text binding on
//  iOS 17 (that arrived later and still can't do per-range typing attributes), no access to the
//  text storage, no key-command hooks, and no caret/selection API. Every requirement here — style
//  per range, continue a list on Return, ⌘B on a selection, tap a checkbox — needs the text
//  storage and the delegate. So: one `UIViewRepresentable`, deliberately small.
//
//  The storage stays PLAIN MARKDOWN at all times. Attributes are presentation only and are
//  recomputed from the text; nothing is ever persisted as rich text. That is what keeps the server,
//  the MCP tools, FTS search and the agent surface working untouched.
//
//  Platforms: iPhone, iPad and Mac Catalyst all run this same UIKit view. The differences are
//  chrome (see MarkdownEditorToolbar), not engine.
//

import SwiftUI
import UIKit

// MARK: - The controller the SwiftUI chrome talks to

/// A handle the toolbar / keyboard shortcuts use to drive the text view without owning it.
///
/// SwiftUI can't call into a `UIViewRepresentable`'s view directly, and passing closures down for
/// every command gets unwieldy fast. One small reference type, handed to the representable on make
/// and to the toolbar as a plain object, keeps the wiring honest.
@MainActor
final class MarkdownEditorController {
    fileprivate weak var textView: UITextView?

    /// True when there's a live text view to act on (drives toolbar enablement).
    var isAttached: Bool { textView != nil }

    // MARK: Inline wrapping

    /// Wrap the selection in `token` (or unwrap it if it's already wrapped). With no selection,
    /// insert the pair and place the caret between them, so ⌘B then typing produces bold text —
    /// the behaviour every writing app has.
    func toggleWrap(_ token: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let sel = tv.selectedRange
        let tokenLen = (token as NSString).length

        // Already wrapped? Unwrap — checking just outside the selection first, then just inside.
        let outer = NSRange(location: sel.location - tokenLen, length: sel.length + tokenLen * 2)
        if sel.location >= tokenLen,
           NSMaxRange(outer) <= ns.length,
           ns.substring(with: NSRange(location: outer.location, length: tokenLen)) == token,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: tokenLen)) == token {
            replace(NSRange(location: NSMaxRange(sel), length: tokenLen), with: "")
            replace(NSRange(location: outer.location, length: tokenLen), with: "")
            tv.selectedRange = NSRange(location: sel.location - tokenLen, length: sel.length)
            return
        }

        let selected = ns.substring(with: sel)
        replace(sel, with: token + selected + token)
        tv.selectedRange = selected.isEmpty
            ? NSRange(location: sel.location + tokenLen, length: 0)               // caret between
            : NSRange(location: sel.location + tokenLen, length: sel.length)      // keep selection
    }

    /// Prefix every line the selection touches with `prefix` — or strip it if every line already
    /// has it. Used by the heading / quote / list buttons.
    func toggleLinePrefix(_ prefix: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let lines = lineRangesCoveringSelection(in: ns, selection: tv.selectedRange)
        guard !lines.isEmpty else { return }

        let allHavePrefix = lines.allSatisfy { ns.substring(with: $0).hasPrefix(prefix) }
        var delta = 0
        let caret = tv.selectedRange

        // Back to front so earlier ranges stay valid as we mutate.
        for line in lines.reversed() {
            if allHavePrefix {
                replace(NSRange(location: line.location, length: (prefix as NSString).length), with: "")
                delta -= (prefix as NSString).length
            } else if !ns.substring(with: line).hasPrefix(prefix) {
                replace(NSRange(location: line.location, length: 0), with: prefix)
                delta += (prefix as NSString).length
            }
        }
        let newLocation = max(0, caret.location + (allHavePrefix ? -(prefix as NSString).length : (prefix as NSString).length))
        tv.selectedRange = NSRange(location: min(newLocation, (tv.text as NSString).length), length: 0)
        _ = delta
    }

    /// Insert a link scaffold. With text selected, the selection becomes the label and the caret
    /// lands in the URL slot — the fastest path from "I have a phrase" to "it's a link".
    func insertLink() {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let sel = tv.selectedRange
        let label = ns.substring(with: sel)
        let inserted = "[\(label)](url)"
        replace(sel, with: inserted)
        // Select the literal "url" so typing replaces it.
        let urlStart = sel.location + (label as NSString).length + 3
        tv.selectedRange = NSRange(location: urlStart, length: 3)
    }

    /// Wrap the selection in a fenced code block on its own lines.
    func insertCodeBlock() {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let sel = tv.selectedRange
        let body = ns.substring(with: sel)
        let needsLeadingBreak = sel.location > 0 && ns.substring(with: NSRange(location: sel.location - 1, length: 1)) != "\n"
        let text = (needsLeadingBreak ? "\n" : "") + "```\n" + body + "\n```\n"
        replace(sel, with: text)
        let caret = sel.location + (needsLeadingBreak ? 1 : 0) + 4 + (body as NSString).length
        tv.selectedRange = NSRange(location: min(caret, (tv.text as NSString).length), length: 0)
    }

    /// Indent / outdent the touched lines by two spaces (markdown's nesting unit here).
    func indent(by amount: Int) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let lines = lineRangesCoveringSelection(in: ns, selection: tv.selectedRange)
        let caret = tv.selectedRange
        for line in lines.reversed() {
            if amount > 0 {
                replace(NSRange(location: line.location, length: 0), with: "  ")
            } else {
                let text = ns.substring(with: line)
                let strip = text.hasPrefix("  ") ? 2 : (text.hasPrefix(" ") ? 1 : 0)
                if strip > 0 { replace(NSRange(location: line.location, length: strip), with: "") }
            }
        }
        let shift = amount > 0 ? 2 : -2
        tv.selectedRange = NSRange(location: max(0, min(caret.location + shift, (tv.text as NSString).length)),
                                   length: 0)
    }

    /// Set the caret's line to a heading of `level` (1…3), or to body text with `level == 0`.
    ///
    /// This REPLACES any existing `#` run rather than prefixing one, because a toggle-style prefix
    /// would turn `# Title` into `## # Title` the second time you used it.
    func setHeading(_ level: Int) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        guard ns.length > 0 || level > 0 else { return }
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                        for: NSRange(location: min(tv.selectedRange.location, ns.length), length: 0))
        let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))

        // Measure the existing `###` + its single space, so we can swap it wholesale.
        var existing = 0
        for c in line where c == "#" { existing += 1 }
        var stripLength = existing
        if existing > 0, line.count > existing, Array(line)[existing] == " " { stripLength += 1 }

        let replacement = level > 0 ? String(repeating: "#", count: level) + " " : ""
        let caret = tv.selectedRange
        replace(NSRange(location: lineStart, length: stripLength), with: replacement)
        let shift = (replacement as NSString).length - stripLength
        tv.selectedRange = NSRange(location: max(lineStart, min(caret.location + shift,
                                                               (tv.text as NSString).length)),
                                   length: 0)
    }

    /// Insert a 3×3 GitHub-flavoured table skeleton on its own lines, caret in the first cell.
    func insertTable() {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let sel = tv.selectedRange
        let needsLeadingBreak = sel.location > 0
            && ns.substring(with: NSRange(location: sel.location - 1, length: 1)) != "\n"
        let table = (needsLeadingBreak ? "\n" : "")
            + "|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n"
        replace(sel, with: table)
        let caret = sel.location + (needsLeadingBreak ? 1 : 0) + 2   // inside the first cell
        tv.selectedRange = NSRange(location: min(caret, (tv.text as NSString).length), length: 0)
    }

    /// Toggle the checkbox on the caret's line, if it's a task item.
    func toggleTask() {
        guard let tv = textView,
              let toggle = MarkdownSyntax.taskToggle(forLineAt: tv.selectedRange.location,
                                                     in: tv.text as NSString) else { return }
        let caret = tv.selectedRange
        replace(toggle.range, with: toggle.replacement)
        tv.selectedRange = caret
    }

    // MARK: Plumbing

    /// Every mutation goes through `UITextView`'s own text-input path so the native undo stack,
    /// autocorrect state and delegate callbacks all stay coherent. Mutating `textStorage` directly
    /// is the classic way to end up with an editor whose ⌘Z does nothing.
    private func replace(_ range: NSRange, with string: String) {
        guard let tv = textView,
              let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: range.length),
              let textRange = tv.textRange(from: start, to: end) else { return }
        tv.replace(textRange, withText: string)
    }

    private func lineRangesCoveringSelection(in ns: NSString, selection: NSRange) -> [NSRange] {
        guard ns.length > 0 else { return [] }
        var result: [NSRange] = []
        var index = selection.location
        let limit = max(NSMaxRange(selection), selection.location)
        repeat {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: min(index, ns.length), length: 0))
            result.append(NSRange(location: lineStart, length: contentsEnd - lineStart))
            if lineEnd <= index { break }
            index = lineEnd
        } while index <= limit && index < ns.length
        return result
    }
}

// MARK: - The representable

struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var controller: MarkdownEditorController
    /// Content inset applied around the text, so the caller controls the "page" margins per platform.
    var contentInset: UIEdgeInsets
    var onFocusChange: (Bool) -> Void

    func makeUIView(context: Context) -> MarkdownUITextView {
        let view = MarkdownUITextView()
        view.delegate = context.coordinator
        view.markdownCoordinator = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = contentInset
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.tintColor = MarkdownTheme.caretTint
        view.autocorrectionType = .yes
        view.autocapitalizationType = .sentences
        // Smart quotes turn `"` into `"` and would corrupt code spans and link URLs the moment a
        // user types one. A markdown editor must stay literal.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.text = text
        controller.textView = view
        context.coordinator.restyle(view)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: MarkdownUITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = view

        // Only touch the text when it genuinely diverges (an external restore, a history revert).
        // Assigning `text` unconditionally would fight the user's caret on every keystroke.
        if view.text != text {
            let caret = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(caret.location, (text as NSString).length),
                                         length: 0)
            context.coordinator.restyle(view)
        }
        if view.textContainerInset != contentInset { view.textContainerInset = contentInset }

        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: MarkdownTextView

        init(parent: MarkdownTextView) {
            self.parent = parent
        }

        // MARK: Styling

        /// Recompute every attribute from the plain text. Called after each edit.
        ///
        /// It rebuilds the whole document's attributes rather than diffing. That sounds wasteful,
        /// but tokenizing is linear and `NSTextStorage` coalesces the work between
        /// `beginEditing`/`endEditing` into a single layout pass — and a diffing scheme would have
        /// to reason about edits that change block structure far from the caret (typing the third
        /// backtick of a fence restyles everything below it). Correctness first; the tokenizer has
        /// a performance test guarding the hot path.
        func restyle(_ view: UITextView) {
            let storage = view.textStorage
            let ns = storage.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard full.length > 0 else {
                view.typingAttributes = MarkdownTheme.attributes(for: .body)
                return
            }

            let selection = view.selectedRange
            storage.beginEditing()
            storage.setAttributes(MarkdownTheme.attributes(for: .body), range: full)

            for span in MarkdownSyntax.spans(in: ns) {
                guard span.range.location >= 0, NSMaxRange(span.range) <= ns.length else { continue }
                apply(span, to: storage)
            }
            storage.endEditing()
            // `setAttributes` doesn't move the caret, but restoring guards against any layout
            // pass that would.
            if view.selectedRange != selection { view.selectedRange = selection }
        }

        /// One span → attributes.
        ///
        /// Three kinds deliberately do NOT take the theme's whole dictionary, because doing so
        /// would replace the font they sit on:
        ///  - emphasis is applied as a font TRAIT, so `## a **bold** word` keeps the heading's
        ///    size and gains weight instead of collapsing to body size;
        ///  - the decorations (strikethrough, done-task text) add only their decoration + colour;
        ///  - syntax markers INHERIT their surrounding attributes and merely recolour, so dimming
        ///    a `**` can never change a glyph advance and reflow the line under the caret.
        private func apply(_ span: MDSpan, to storage: NSTextStorage) {
            switch span.kind {
            case .bold:
                addTrait(.traitBold, range: span.range, storage: storage)
            case .italic:
                addTrait(.traitItalic, range: span.range, storage: storage)
            case .boldItalic:
                addTrait([.traitBold, .traitItalic], range: span.range, storage: storage)
            case .strikethrough:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .strikethroughColor: MarkdownTheme.inkSecondary,
                                       .foregroundColor: MarkdownTheme.inkSecondary],
                                      range: span.range)
            case .taskCheckedText:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .strikethroughColor: MarkdownTheme.inkSecondary.withAlphaComponent(0.6),
                                       .foregroundColor: MarkdownTheme.inkSecondary],
                                      range: span.range)
            case .syntaxMarker:
                applyMarker(span.range, to: storage)
            default:
                storage.addAttributes(MarkdownTheme.attributes(for: span.kind, level: span.level),
                                      range: span.range)
            }
        }

        /// Recolour markers while inheriting whatever font/indent they already carry. Attributes
        /// are collected before being written — mutating a text storage inside its own
        /// `enumerateAttributes` is undefined behaviour.
        private func applyMarker(_ range: NSRange, to storage: NSTextStorage) {
            var pending: [(NSRange, [NSAttributedString.Key: Any])] = []
            storage.enumerateAttributes(in: range, options: []) { base, subrange, _ in
                pending.append((subrange, MarkdownTheme.syntaxMarkerAttributes(base: base,
                                                                               activeLine: false)))
            }
            for (subrange, attributes) in pending {
                storage.setAttributes(attributes, range: subrange)
            }
        }

        private func addTrait(_ trait: UIFontDescriptor.SymbolicTraits,
                              range: NSRange,
                              storage: NSTextStorage) {
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                guard let font = value as? UIFont else { return }
                let traits = font.fontDescriptor.symbolicTraits.union(trait)
                guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return }
                storage.addAttribute(.font,
                                     value: UIFont(descriptor: descriptor, size: font.pointSize),
                                     range: subrange)
            }
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            restyle(textView)
            parent.text = textView.text
            // Keep newly typed characters on the body style; the restyle pass corrects the rest.
            textView.typingAttributes = MarkdownTheme.attributes(for: .body)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard replacement == "\n" else { return true }
            let ns = textView.text as NSString

            // Return on a list line continues the list; Return on an EMPTY list item ends it
            // (deletes the orphan marker) — the standard behaviour from every notes app.
            guard let continuation = MarkdownSyntax.listContinuation(forLineAt: range.location, in: ns)
            else { return true }

            if continuation.isEmpty {
                if let marker = MarkdownSyntax.listMarkerRange(forLineAt: range.location, in: ns),
                   let start = textView.position(from: textView.beginningOfDocument, offset: marker.location),
                   let end = textView.position(from: start, offset: marker.length),
                   let textRange = textView.textRange(from: start, to: end) {
                    textView.replace(textRange, withText: "")
                    return false
                }
                return true
            }
            textView.insertText("\n" + continuation)
            return false
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.onFocusChange(true) }
        func textViewDidEndEditing(_ textView: UITextView) { parent.onFocusChange(false) }

        // MARK: Checkbox tapping

        /// Tapping directly on a `- [ ]` box toggles it instead of just placing the caret. The hit
        /// area is the marker's glyph range, so a tap on the item's TEXT still positions the caret
        /// normally — tapping to edit must keep working.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            let point = gesture.location(in: view)
            let inset = view.textContainerInset
            let adjusted = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
            let index = view.layoutManager.characterIndex(for: adjusted,
                                                          in: view.textContainer,
                                                          fractionOfDistanceBetweenInsertionPoints: nil)
            let ns = view.text as NSString
            guard index < ns.length else { return }

            // Only inside the marker itself.
            let markerSpans = MarkdownSyntax.spans(in: ns).filter {
                $0.kind == .taskBoxChecked || $0.kind == .taskBoxUnchecked
            }
            guard markerSpans.contains(where: { NSLocationInRange(index, $0.range) }),
                  let toggle = MarkdownSyntax.taskToggle(forLineAt: index, in: ns),
                  let start = view.position(from: view.beginningOfDocument, offset: toggle.range.location),
                  let end = view.position(from: start, offset: toggle.range.length),
                  let textRange = view.textRange(from: start, to: end) else { return }

            let caret = view.selectedRange
            view.replace(textRange, withText: toggle.replacement)
            view.selectedRange = caret
            Haptics.light()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true   // never fight the text view's own tap-to-position recognizer
        }
    }
}

// MARK: - The UITextView subclass (key commands)

/// `UIKeyCommand`s live on the responder, which is why this is a subclass rather than configuration.
/// They give the Mac build real menu-grade shortcuts and make an iPad hardware keyboard behave the
/// way a writer expects.
final class MarkdownUITextView: UITextView {
    weak var markdownCoordinator: MarkdownTextView.Coordinator?

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "Bold", action: #selector(mdBold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Italic", action: #selector(mdItalic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Code", action: #selector(mdCode), input: "e", modifierFlags: .command),
            UIKeyCommand(title: "Link", action: #selector(mdLink), input: "k", modifierFlags: .command),
            UIKeyCommand(title: "Strikethrough", action: #selector(mdStrike), input: "x",
                         modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Toggle Task", action: #selector(mdTask), input: "t",
                         modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Indent", action: #selector(mdIndent), input: "\t", modifierFlags: []),
            UIKeyCommand(title: "Outdent", action: #selector(mdOutdent), input: "\t",
                         modifierFlags: .shift),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    /// The controller is reachable through the coordinator's parent, so the subclass stays a thin
    /// responder shim rather than a second owner of editing logic.
    private var controller: MarkdownEditorController? { markdownCoordinator?.parent.controller }

    @objc private func mdBold() { controller?.toggleWrap("**") }
    @objc private func mdItalic() { controller?.toggleWrap("*") }
    @objc private func mdCode() { controller?.toggleWrap("`") }
    @objc private func mdStrike() { controller?.toggleWrap("~~") }
    @objc private func mdLink() { controller?.insertLink() }
    @objc private func mdTask() { controller?.toggleTask() }
    @objc private func mdIndent() { controller?.indent(by: 1) }
    @objc private func mdOutdent() { controller?.indent(by: -1) }
}
