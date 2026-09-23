//
//  NoteDetailView.swift
//  Command
//
//  One paper editor for a note — a SINGLE field (Apple-Notes style): the first line is the note's
//  title, the rest is its body. Open it two ways:
//   - tap a row on the Notes list to edit an existing note (auto-saves as you type, on background,
//     and on dismiss, so nothing is lost), or
//   - tap + on the Notes page to compose a new one. A new note is created as soon as it has content
//     AND is auto-created on background/dismiss, so a mid-compose app kill never loses it.
//  An existing note also offers History (restore), Duplicate, and Delete.
//

import PhotosUI
import SwiftUI

struct NoteDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigator) private var nav
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private let initialNote: Note?
    /// True when hosted at the root of the iPad/Mac detail column (where `dismiss()` is a no-op);
    /// false when presented as an iPhone sheet. Drives how "Done" / delete close the editor.
    private let inDetailColumn: Bool

    /// Owns the note's text (one editable string — first line is the title, the rest is the body),
    /// its id once created, and the serialized save path. See NoteSaver.
    @State private var saver: NoteSaver
    @State private var saveTask: Task<Void, Never>?
    @State private var finished = false
    /// Set when a Close couldn't save: the editor stays open with Retry / Discard instead of
    /// closing over the unsaved text.
    @State private var closeBlocked = false
    @State private var showDiscard = false
    @State private var showHistory = false
    @State private var showDelete = false
    @State private var showDuplicate = false
    @State private var revealedOverride = false   // set true after a gated unredact, to edit in place
    // Attachments: created once the note has an id (a brand-new note has nothing to attach to).
    // The add buttons live in the top-left navbar; the bottom strip only DISPLAYS chips.
    @State private var attachStore: AttachmentsStore?
    @State private var photoPick: PhotosPickerItem?
    @State private var showFileImporter = false
    /// Mirrors the editor's real first-responder state. It's plain `@State`, not `@FocusState`,
    /// because focus lives in the `MarkdownTextView`'s UITextView, not a SwiftUI-focusable view —
    /// the text view reports focus in/out via `onFocusChange`, and we drive it back by toggling
    /// this (updateUIView calls become/resignFirstResponder). A `@FocusState` with nothing bound
    /// to it would silently revert to false.
    @State private var focused: Bool = false
    /// Drives the live-styled markdown editor. Owns the UITextView; the toolbar and ⌘-shortcuts
    /// act through it. One per editor instance.
    @State private var markdown = MarkdownEditorController()

    /// `note == nil` opens the composer for a brand-new note (the + button). `inDetailColumn` is
    /// set by the iPad/Mac detail-column host so "Done"/delete clear the selection instead of
    /// calling the inert `dismiss()`.
    init(note: Note? = nil, inDetailColumn: Bool = false) {
        self.initialNote = note
        self.inDetailColumn = inDetailColumn
        _saver = State(initialValue: NoteSaver(noteId: note?.id, text: Self.combined(note)))
    }

    /// Reconstruct the single-field text from a note losslessly. Body holds the full content; a
    /// legacy note whose title is distinct from its first body line gets the title prepended once.
    private static func combined(_ note: Note?) -> String {
        guard let note else { return "" }
        let title = (note.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return note.body }
        if Note.firstLine(of: note.body) == title { return note.body }   // title already == first line
        return note.body.isEmpty ? title : title + "\n" + note.body
    }

    private var client: APIClient { app.client }
    private var store: NotesStore { app.notes }
    private var noteId: Int? { saver.noteId }
    private var text: String { saver.text }
    private var isNew: Bool { noteId == nil }

    /// The store-backed create/update the saver runs. The stores report failures via
    /// `errorMessage`, so a nil result is rethrown carrying that message.
    private var saveOps: NoteSaver.Ops {
        let store = store, client = client
        return NoteSaver.Ops(
            create: { title, body in
                guard let note = await store.create(title: title, body: body, client: client) else {
                    throw NoteSaveError(message: store.errorMessage)
                }
                return note.id
            },
            update: { id, title, body in
                guard await store.update(id: id, title: title, body: body, client: client) != nil else {
                    throw NoteSaveError(message: store.errorMessage)
                }
            })
    }

    /// A hidden note opens censored: shown but covered, so it never reveals plaintext on
    /// tap. In "Rub to reveal" the reader can rub it to peek; "Reveal all" lifts the cover
    /// and restores normal editing.
    private var isHidden: Bool { !revealedOverride && (initialNote?.hidden ?? false) && app.hiddenRevealMode != .revealAll }

    var body: some View {
        NavigationStack {
            Group {
                if isHidden { hiddenReader } else { editor }
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let store = attachStore, !isHidden {
                    ToolbarItem(placement: .topBarLeading) {
                        PhotosPicker(selection: $photoPick, matching: .images) {
                            Image(systemName: "photo.badge.plus")
                                .foregroundStyle(Palette.accent)
                        }
                        .accessibilityLabel("Add photo")
                        .disabled(store.uploading)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showFileImporter = true } label: {
                            Image(systemName: "paperclip")
                                .foregroundStyle(Palette.accent)
                        }
                        .accessibilityLabel("Add file")
                        .disabled(store.uploading)
                    }
                }
                ToolbarItem(placement: .principal) { if isHidden { hiddenStatus } else { saveStatus } }
                if noteId != nil {
                    ToolbarItem(placement: .topBarTrailing) { actionsMenu }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Editing → bold "Done" (just unfocuses; edits auto-save). Idle → "Close"
                    // (closes the editor). Operator feedback 2026-07-20.
                    Button(focused ? "Done" : "Close") { if focused { focused = false } else { finish() } }
                        .fontWeight(focused ? .bold : .regular).tint(Palette.accent)
                }
            }
            .task(id: noteId) {
                if let id = noteId, attachStore == nil {
                    attachStore = AttachmentsStore(entityKind: "note", entityId: id)
                }
            }
            .onChange(of: photoPick) { _, item in
                guard let item, let store = attachStore else { return }
                photoPick = nil
                Task { await store.importPhoto(item, client: app.client) }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result, let store = attachStore {
                    Task { await store.importFile(url, client: app.client) }
                }
            }
            .sheet(isPresented: $showHistory) {
                if let id = noteId {
                    NoteHistoryView(noteId: id, liveBody: text) { restored in
                        apply(restored)
                    }
                    .macSheet(.page)
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteNote() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It moves to your archive — recoverable later, not erased.")
            }
            .overlay {
                if showDuplicate {
                    NamePrompt(prompt: "Name the copy",
                               defaultName: duplicateDefaultName,
                               isPresented: $showDuplicate) { name in
                        Task { await store.duplicate(title: name, body: text, client: client) }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showDuplicate)
            .onChange(of: saver.text) { _, _ in saver.textDidChange(); scheduleSave() }
            .onChange(of: scenePhase) { _, phase in
                // Background/kill: persist immediately (create the new note if it has content), so a
                // mid-compose restart never loses work — the debounce Task doesn't survive suspension.
                if phase != .active { saveTask?.cancel(); Task { _ = await saver.flush(using: saveOps) } }
            }
            // A sheet can't be swiped away while its last save failed — the Retry / Discard banner
            // is the way out, so unsaved text is never silently dropped.
            .interactiveDismissDisabled(saver.isFailed)
            .confirmationDialog("Discard unsaved changes?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { discardAndClose() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your latest edits to this note haven't been saved.")
            }
            .onDisappear { finishOnDisappear() }
            .task {
                if isNew {
                    try? await Task.sleep(for: .milliseconds(350))
                    focused = true
                }
            }
        }
    }

    /// The single-field note editor: one flowing text surface that styles markdown live as you
    /// type, no title/body separator, no edit mode. Storage stays plain markdown — the styling is
    /// presentation only (see MarkdownTextView).
    private var editor: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Title, then your note…")
                        .font(Typeface.body(17))
                        .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                        .padding(.leading, editorInset(for: geo.size.width).left + 5)
                        .padding(.top, editorInset(for: geo.size.width).top)
                        .allowsHitTesting(false)
                }
                MarkdownTextView(text: Bindable(saver).text,
                                 isFocused: focused,
                                 controller: markdown,
                                 contentInset: editorInset(for: geo.size.width),
                                 onFocusChange: { focused = $0 })
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .failed(let message) = saver.state { saveFailedBanner(message) }
        }
        // The formatting toolbar + existing attachment chips ride below the editor. The strip
        // renders nothing while the note has none (adding happens from the navbar buttons).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let store = attachStore {
                    AttachmentsStrip(store: store)
                }
                if focused {
                    MarkdownEditorToolbar(controller: markdown,
                                          isFocused: focused,
                                          onDismissKeyboard: { focused = false })
                    .transition(AnyTransition.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: focused)
        }
        // Hand the focused editor to the Mac menu bar's Format menu (FormatCommands). Nil while
        // the editor isn't focused, which is exactly what greys those menu items out.
        .focusedSceneValue(\.markdownEditor, focused ? markdown : nil)
    }

    /// Per-platform "page" margins (design spec §4). The text column caps at a comfortable
    /// ~68-char measure and CENTERS on wide iPad/Mac windows instead of running to the window edge —
    /// long-form notes must not sprawl to 1400pt on a Mac.
    private func editorInset(for width: CGFloat) -> UIEdgeInsets {
        let maxColumn = MarkdownTheme.Metrics.maxColumnWidth
        let compact = MarkdownTheme.Metrics.compactMargin
        let regular = MarkdownTheme.Metrics.regularMargin
        let bottom = MarkdownTheme.Metrics.bottomInset

        let sides: CGFloat
        #if targetEnvironment(macCatalyst)
        sides = max(regular, (width - maxColumn) / 2)
        #else
        if hSizeClass == .regular {
            sides = max(regular, (width - maxColumn) / 2)
        } else {
            sides = compact
        }
        #endif
        return UIEdgeInsets(top: 12, left: sides, bottom: bottom, right: sides)
    }

    /// A hidden note, censored: rendered read-only under the hidden veil, so tapping into it
    /// never exposes plaintext. The reader rubs to peek (in "Rub to reveal" mode).
    private var hiddenReader: some View {
        ScrollView {
            Text(Self.combined(initialNote).isEmpty ? "Hidden note" : Self.combined(initialNote))
                .font(Typeface.body(17))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .hiddenVeil(hidden: true)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hidden note")
    }

    private var hiddenStatus: some View {
        Label(app.hiddenRevealMode == .rubToReveal ? "Hidden · rub to reveal" : "Hidden",
              systemImage: "eye.slash.fill")
            .font(Typeface.body(12, .medium))
            .foregroundStyle(Palette.inkSecondary)
    }

    /// Shown while the latest save failed. Retry re-sends the current text; once the user has tried
    /// to close, Discard offers the explicit (confirmed) way to drop the unsaved edits.
    private func saveFailedBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.danger)
                .accessibilityHidden(true)
            Text("Not saved — \(message)")
                .font(Typeface.body(13))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            if closeBlocked {
                Button("Discard", role: .destructive) { showDiscard = true }
                    .font(Typeface.body(13, .semibold))
            }
            Button("Retry") { retrySave() }
                .font(Typeface.body(13, .semibold))
                .tint(Palette.accent)
                .disabled(saver.state == .saving)
        }
        .padding(12)
        .background(Palette.danger.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch saver.state {
        case .saving:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Saving…").font(Typeface.body(12))
            }
            .foregroundStyle(Palette.inkSecondary)
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .font(Typeface.body(12, .medium))
                .foregroundStyle(Palette.sage)
        case .failed:
            Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                .font(Typeface.body(12, .medium))
                .foregroundStyle(Palette.danger)
        case .idle:
            if isNew {
                Text("New note")
                    .font(Typeface.body(13, .medium))
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                EmptyView()
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            if isHidden {
                revealButton
            } else {
                Button { focused = false; showHistory = true } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button { focused = false; showDuplicate = true } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                Divider()
                hideButton
                Divider()
                Button(role: .destructive) { showDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").tint(Palette.accent)
        }
        .accessibilityLabel("Actions")
    }

    /// Hide the note, save any pending edits, and dismiss — reopening shows it hidden.
    private var hideButton: some View {
        Button {
            guard let id = noteId else { return }
            focused = false
            Task {
                await app.notes.setHidden(id: id, hidden: true, client: client)
                finish()
            }
        } label: { Label("Hide", systemImage: "eye.slash") }
    }

    /// Reveal a hidden note in place after passing the passcode/biometric gate.
    private var revealButton: some View {
        Button {
            guard let id = noteId else { return }
            Task {
                if await app.privacy.authenticate(reason: "Reveal this note"),
                   await app.notes.setHidden(id: id, hidden: false, client: client) {
                    revealedOverride = true
                }
            }
        } label: { Label("Reveal", systemImage: "eye") }
    }

    private var duplicateDefaultName: String {
        let name = Note.firstLine(of: text)
        return name.isEmpty ? "Note copy" : "\(name) copy"
    }

    // MARK: Save / close

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            await saver.save(using: saveOps)
        }
    }

    /// Close requested by the user (Close / Hide): save everything, then close. If the save fails
    /// the editor STAYS OPEN with the error and Retry / Discard — never closes over unsaved text.
    private func finish() {
        guard !finished else { return }
        finished = true
        saveTask?.cancel()
        Task {
            if await saver.flush(using: saveOps) {
                closeBlocked = false
                if let id = noteId { await store.close(id: id, client: client) }   // snapshot backup + refresh
                close()
            } else {
                finished = false
                closeBlocked = true
            }
        }
    }

    /// The editor went away without a Close (sheet swiped down, another note selected in the
    /// detail column, section switched). Save what's pending; if that fails the view is already
    /// gone, so park the text on the store (the Notes list offers Retry) rather than lose it.
    private func finishOnDisappear() {
        guard !finished else { return }
        finished = true
        saveTask?.cancel()
        Task {
            if await saver.flush(using: saveOps) {
                if let id = noteId { await store.close(id: id, client: client) }
                close()
            } else {
                store.park(noteId: saver.noteId, text: saver.text)
            }
        }
    }

    private func retrySave() {
        saveTask?.cancel()
        if closeBlocked { finish() } else { Task { await saver.save(using: saveOps) } }
    }

    /// The user confirmed dropping the unsaved edits: close without saving. An existing note keeps
    /// its last saved content; a never-created note simply isn't created.
    private func discardAndClose() {
        finished = true
        saveTask?.cancel()
        close()
    }

    /// Dismiss the sheet (iPhone) or clear the detail-column note selection (iPad/Mac, where
    /// `dismiss()` is inert at the column root). The selection is cleared only while it is still
    /// THIS note: a disappearing editor finishes its save asynchronously, and by then the user may
    /// have selected another note — nil-ing that would close the note they just opened.
    private func close() {
        if inDetailColumn {
            if let nav, nav.selectedNoteId == noteId { nav.selectedNoteId = nil }
        } else {
            dismiss()
        }
    }

    private func deleteNote() {
        finished = true  // skip the auto-save/close path; we're archiving
        guard let id = noteId else { close(); return }
        Haptics.delete()
        Task { await store.archive(id: id, client: client) }
        close()
    }

    private func apply(_ restored: Note) {
        saver.markSaved(Self.combined(restored))
    }
}
