//
//  NoteHistoryView.swift
//  Command
//
//  A note's backup history: the current version on top, then up to 5 snapshots
//  (one per close, newest first). Restore rolls the note back to a version (the
//  current state is backed up first, so it's undoable); Duplicate copies any
//  version — including the current one — into a brand-new note you name.
//

import SwiftUI

struct NoteHistoryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let noteId: Int
    let liveBody: String
    let onRestore: (Note) -> Void

    @State private var revisions: [NoteRevision] = []
    @State private var loading = true
    @State private var restoreTarget: NoteRevision?
    @State private var dup: DuplicateContext?
    @State private var showDuplicate = false

    private struct DuplicateContext { let defaultName: String; let body: String }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                if loading {
                    ProgressView().controlSize(.large)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            currentCard
                            if revisions.isEmpty {
                                emptyHint
                            } else {
                                ForEach(revisions) { revisionCard($0) }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.accent)
                }
            }
            .task { await load() }
            .confirmationDialog(
                "Restore this version?",
                isPresented: Binding(get: { restoreTarget != nil },
                                     set: { if !$0 { restoreTarget = nil } }),
                titleVisibility: .visible,
                presenting: restoreTarget
            ) { rev in
                Button("Restore", role: .destructive) { restore(rev) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Your current version is backed up first, so this is undoable.")
            }
            .overlay {
                if showDuplicate, let dup {
                    NamePrompt(prompt: "Name the copy",
                               defaultName: dup.defaultName,
                               isPresented: $showDuplicate) { name in
                        Task { await app.notes.duplicate(title: name, body: dup.body, client: app.client) }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showDuplicate)
        }
    }

    // MARK: Cards

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            tag("CURRENT", color: Palette.accent)
            Text(currentTitle).font(Typeface.display(18)).foregroundStyle(Palette.ink)
            Text(liveBody)
                .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                actionButton("Duplicate", icon: "doc.on.doc") {
                    startDuplicate(name: currentTitle, body: liveBody)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }

    private func revisionCard(_ rev: NoteRevision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            tag(RelativeTime.ago(rev.createdAt), color: Palette.inkSecondary)
            Text(rev.title?.isEmpty == false ? rev.title! : Note.firstLine(of: rev.body))
                .font(Typeface.display(18)).foregroundStyle(Palette.ink)
            Text(rev.body)
                .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                actionButton("Duplicate", icon: "doc.on.doc") {
                    let base = rev.title?.isEmpty == false ? rev.title! : Note.firstLine(of: rev.body)
                    startDuplicate(name: base, body: rev.body)
                }
                actionButton("Restore", icon: "arrow.uturn.backward", prominent: true) {
                    restoreTarget = rev
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }

    private var emptyHint: some View {
        Text("No earlier versions yet. A backup is saved each time you close a note.")
            .font(Typeface.body(13))
            .foregroundStyle(Palette.inkSecondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
    }

    private func actionButton(_ label: String, icon: String, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(Typeface.body(13, .semibold))
                .foregroundStyle(prominent ? .white : Palette.accent)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .frame(minHeight: 44)
                .background(prominent ? Palette.accent : Palette.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

    private var currentTitle: String {
        if let n = app.notes.notes.first(where: { $0.id == noteId }), n.hasTitle { return n.title ?? "" }
        return Note.firstLine(of: liveBody)
    }

    private func load() async {
        revisions = await app.notes.revisions(id: noteId, client: app.client)
        loading = false
    }

    private func restore(_ rev: NoteRevision) {
        Task {
            if let restored = await app.notes.restore(noteId: noteId, revisionId: rev.id, client: app.client) {
                onRestore(restored)
                dismiss()
            }
        }
    }

    private func startDuplicate(name: String, body: String) {
        dup = DuplicateContext(defaultName: name.isEmpty ? "Note copy" : "\(name) copy", body: body)
        showDuplicate = true
    }
}
