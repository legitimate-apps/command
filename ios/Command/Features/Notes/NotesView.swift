//
//  NotesView.swift
//  Command
//

import SwiftUI

struct NotesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.navigator) private var nav
    @State private var selectedNote: Note?
    @State private var composing = false
    @State private var searchText = ""
    @State private var searchActive = false   // search field is hidden until the 🔍 button reveals it
    @State private var confirmDiscardUnsaved = false

    /// iPad/Mac shell (Navigator present) → the shared detail column; iPhone → sheet.
    private func open(_ note: Note) {
        if let nav, nav.hasDetailColumn { nav.selectedNoteId = note.id }
        else { selectedNote = note }
    }

    /// Client-side filter over the already-loaded notes. `localizedStandardContains`
    /// is the user-facing search predicate (case- and diacritic-insensitive,
    /// locale-aware — what Notes/Finder use). Hidden notes are never
    /// surfaced — that would leak hidden plaintext.
    private var filteredNotes: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return app.notes.notes }
        return app.notes.notes.filter { note in
            guard !(note.hidden ?? false) else { return false }
            return note.displayTitle.localizedStandardContains(q) || note.body.localizedStandardContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(spacing: 0) {
                    if searchActive {
                        InlineSearchBar(text: $searchText, prompt: "Search notes") {
                            withAnimation(.easeOut(duration: 0.2)) { searchActive = false }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !app.notes.unsavedEdits.isEmpty { unsavedEditsBanner }
                    content
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { searchActive = true } } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                    }
                    .tint(Palette.accent)
                    .accessibilityLabel("Search notes")
                    .disabled(app.notes.notes.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: {
                        Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                    }
                    .tint(Palette.accent)
                    .accessibilityLabel("New note")
                }
            }
            .task { await app.notes.load(client: app.client) }
            .refreshable { await app.notes.load(client: app.client) }
            .sheet(item: $selectedNote) { NoteDetailView(note: $0).macSheet(.page).privacyChallenge() }
            .sheet(isPresented: $composing) { NoteDetailView().macSheet(.page) }
            // ⌘N / "New Note" from the Mac/iPad menu opens the composer. `initial: true` so a
            // cross-section ⌘N (which show(.notes) mounts this view fresh with the flag already
            // set) still consumes it — plain onChange skips the value present at mount.
            .onChange(of: nav?.composeNote, initial: true) { _, want in
                if want == true { composing = true; nav?.composeNote = false }
            }
            // ⌘F / "Find" reveals the hidden search field.
            .onChange(of: nav?.focusSearch, initial: true) { _, want in
                if want == true { withAnimation(.easeOut(duration: 0.2)) { searchActive = true }; nav?.focusSearch = false }
            }
            #if DEBUG
            // Screenshot hook: launch with `-COMMAND_PREVIEW_SEARCH <query>` to open
            // search pre-filled (so the revealed/filtered state can be captured).
            .onAppear {
                if let q = UserDefaults.standard.string(forKey: "COMMAND_PREVIEW_SEARCH"), !q.isEmpty {
                    searchText = q; searchActive = true
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.notes.notes.isEmpty {
            if app.notes.isLoading {
                SkeletonList(count: 4)
                    .accessibilityLabel("Loading notes")
            } else if let error = app.notes.errorMessage {
                ErrorBanner(message: error) {
                    Task { await app.notes.load(client: app.client) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            } else {
                emptyState
            }
        } else {
            let notes = filteredNotes
            if notes.isEmpty {
                noResults
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(notes) { note in
                            NoteRow(note: note).tappableRow { open(note) }.hoverEffect()
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    /// Edits an editor couldn't save before it went away (see NotesStore.unsavedEdits). Retry
    /// re-sends them; Discard is confirmed, since it's the only way they're ever dropped.
    private var unsavedEditsBanner: some View {
        let count = app.notes.unsavedEdits.count
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.danger)
                .accessibilityHidden(true)
            Text(count == 1 ? "1 note edit couldn't be saved." : "\(count) note edits couldn't be saved.")
                .font(Typeface.body(13))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            Button("Discard", role: .destructive) { confirmDiscardUnsaved = true }
                .font(Typeface.body(13, .semibold))
            Button("Retry") { Task { await app.notes.retryUnsavedEdits(client: app.client) } }
                .font(Typeface.body(13, .semibold))
                .tint(Palette.accent)
        }
        .padding(12)
        .background(Palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .confirmationDialog("Discard unsaved edits?", isPresented: $confirmDiscardUnsaved, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { app.notes.discardUnsavedEdits() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These edits never reached the server and will be lost.")
        }
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36)).foregroundStyle(Palette.inkSecondary.opacity(0.5))
                .accessibilityHidden(true)
            Text("No matches").font(Typeface.display(20)).foregroundStyle(Palette.ink)
            Text("No notes match “\(searchText)”.")
                .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyState: some View {
        CommandEmptyState(
            icon: "tray",
            title: "Nothing jotted yet",
            message: "Capture a quick thought on the Calendar tab — typed or spoken — or start a longer one here.",
            actionLabel: "New note"
        ) { composing = true }
    }
}

struct NoteRow: View {
    @Environment(AppState.self) private var app
    let note: Note
    @State private var confirmHide = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: note.source == "voice" ? "waveform" : "text.alignleft")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.accent)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                if note.isTitlePending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Titling…")
                            .font(Typeface.display(16))
                            .foregroundStyle(Palette.inkSecondary)
                    }
                } else {
                    Text(note.displayTitle)
                        .font(Typeface.display(17))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }

                let preview = note.isTitlePending ? note.body : note.listPreview
                if !preview.isEmpty {
                    Text(preview)
                        .font(Typeface.body(14))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Text(RelativeTime.ago(note.createdAt))
                        .font(Typeface.body(12))
                        .foregroundStyle(Palette.inkSecondary.opacity(0.8))
                    if note.processedAt != nil {
                        Label("planned", systemImage: "checkmark.seal.fill")
                            .font(Typeface.body(11, .medium))
                            .foregroundStyle(Palette.sage)
                    }
                }
            }
            .hiddenVeil(hidden: note.hidden ?? false)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.inkSecondary.opacity(0.4))
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        .contentShape(Rectangle())
        .contextMenu {
            HideMenuItems(isHidden: note.hidden ?? false, reason: "Reveal this note",
                            setHidden: { hide in
                await app.notes.setHidden(id: note.id, hidden: hide, client: app.client)
            }, requestHide: { confirmHide = true })
        }
        .hideConfirmation(isPresented: $confirmHide, what: "note") {
            Task { await app.notes.setHidden(id: note.id, hidden: true, client: app.client) }
        }
    }
}
