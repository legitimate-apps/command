//
//  NotesStore.swift
//  Command
//
//  Shared observable notes state — one instance lives on AppState so the capture
//  bar (on the Calendar tab) and the Notes list stay in sync without a reload.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class NotesStore {
    var notes: [Note] = []
    var draft = ""
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    /// Note edits whose save failed after their editor had already gone away (sheet swiped down,
    /// another note selected in the detail column). Parked here — never dropped — until a retry
    /// lands or the user explicitly discards them; the Notes list surfaces them.
    var unsavedEdits: [UnsavedNoteEdit] = []
    private(set) var isRetrying = false

    struct UnsavedNoteEdit: Identifiable, Equatable {
        let saver: NoteSaver
        var id: UUID { saver.id }
        @MainActor var noteId: Int? { saver.noteId }
        @MainActor var text: String { saver.text }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    func load(client: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.drainAll { limit, cursor in
                try await client.searchNotes(limit: limit, cursor: cursor)
            }
            withAnimation(.snappy) { notes = fresh }
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Save the current draft as a typed note. Returns true on success.
    @discardableResult
    func saveDraft(hidden: Bool = false, client: APIClient) async -> Bool {
        guard !isSaving else { return false }
        let sentDraft = draft
        let body = sentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let note = try await client.createNote(body: body, source: "typed", hidden: hidden)
            insertCreated(note)
            if draft == sentDraft { draft = "" }
            errorMessage = nil
            pollTitleIfNeeded(note, client: client)
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// Create a note from the comprehensive composer (the + button) and put it at the
    /// top of the list. A nil title lets the server generate one (AI titling).
    @discardableResult
    func create(title: String?, body: String, idempotencyKey: UUID? = nil, client: APIClient) async -> Note? {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return nil }
        do {
            let note = try await client.createNote(body: b, source: "typed", title: title, idempotencyKey: idempotencyKey?.uuidString)
            insertCreated(note)
            errorMessage = nil
            pollTitleIfNeeded(note, client: client)
            return note
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// Save a transcribed voice note. Returns true once it's on the server; false (with
    /// `errorMessage` set) otherwise, so the recording sheet can keep the transcript for a retry.
    @discardableResult
    func saveVoiceNote(_ text: String, engine: String, locale: String?, client: APIClient) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        do {
            let note = try await client.createNote(body: body, source: "voice", engine: engine, locale: locale)
            insertCreated(note)
            errorMessage = nil
            pollTitleIfNeeded(note, client: client)
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// A load can observe the committed POST before its response reaches us. Merge by id so
    /// SwiftUI never receives two rows with the same identity.
    private func insertCreated(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        notes.insert(note, at: 0)
    }

    /// Replace a note in the list in place (keeps the list reactive after an edit).
    private func replace(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
    }

    /// Patch title and/or body, syncing the row.
    @discardableResult
    func update(id: Int, title: String? = nil, body: String? = nil, client: APIClient) async -> Note? {
        do {
            let note = try await client.updateNote(id: id, title: title, body: body)
            replace(note); errorMessage = nil; return note
        } catch {
            errorMessage = describe(error); return nil
        }
    }

    /// Redact (hide) or unredact (reveal) a note, syncing the row so the veil updates live.
    @discardableResult
    func setHidden(id: Int, hidden: Bool, client: APIClient) async -> Bool {
        do {
            let note = try await client.setNoteHidden(id: id, hidden: hidden)
            replace(note); errorMessage = nil; return true
        } catch {
            errorMessage = describe(error); return false
        }
    }

    /// Delete = archive: hide from the list but keep it (and its backups) recoverable.
    func archive(id: Int, client: APIClient) async {
        do {
            _ = try await client.archiveNote(id: id, archived: true)
            notes.removeAll { $0.id == id }
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    /// The user closed the note: snapshot a backup + (maybe) start an AI title, then
    /// poll briefly so the row updates with the generated title.
    func close(id: Int, client: APIClient) async {
        do {
            let note = try await client.closeNote(id: id)
            replace(note)
            if note.titleStatus == "generating" { await pollTitle(id: id, client: client) }
        } catch {
            errorMessage = describe(error)
        }
    }

    /// If the backend is generating a title for this note, poll for it in the
    /// background so the row updates from "Titling…" to the real title.
    private func pollTitleIfNeeded(_ note: Note, client: APIClient) {
        guard note.titleStatus == "generating" else { return }
        Task { await pollTitle(id: note.id, client: client) }
    }

    private func pollTitle(id: Int, client: APIClient) async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(1200))
            guard let note = try? await client.getNote(id: id) else { continue }
            replace(note)
            if note.titleStatus != "generating" { return }
        }
    }

    func revisions(id: Int, client: APIClient) async -> [NoteRevision] {
        do { return try await client.noteRevisions(id: id) }
        catch { errorMessage = describe(error); return [] }
    }

    @discardableResult
    func restore(noteId: Int, revisionId: Int, client: APIClient) async -> Note? {
        do {
            let note = try await client.restoreNoteRevision(noteId: noteId, revisionId: revisionId)
            replace(note); errorMessage = nil; return note
        } catch {
            errorMessage = describe(error); return nil
        }
    }

    /// Duplicate a note's body into a brand-new note with the given name (title).
    @discardableResult
    func duplicate(title: String, body: String, client: APIClient) async -> Note? {
        do {
            let note = try await client.createNote(body: body, source: "typed", title: title)
            insertCreated(note); errorMessage = nil; return note
        } catch {
            errorMessage = describe(error); return nil
        }
    }

    /// Keep an edit the closing editor couldn't save. A newer edit of the same note replaces the
    /// older one (it contains it — the editor holds the whole note).
    func park(noteId: Int?, text: String) {
        let saver = NoteSaver(noteId: noteId, text: "")
        saver.text = text
        park(saver: saver)
    }

    /// Retain the original saver, including a successful create followed by a failed PATCH,
    /// and its stable session identity. Retrying must never manufacture a fresh create owner.
    func park(saver: NoteSaver) {
        unsavedEdits.removeAll { $0.id == saver.id || (saver.noteId != nil && $0.noteId == saver.noteId) }
        unsavedEdits.append(UnsavedNoteEdit(saver: saver))
    }

    /// Only one retry pass runs at a time. Edits parked during a
    /// retry remain in the queue. Only the exact session successfully flushed is removed.
    func retryUnsavedEdits(client: APIClient) async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        for edit in unsavedEdits {
            let ops = NoteSaver.Ops(
                create: { title, body, key in
                    guard let note = await self.create(title: title, body: body, idempotencyKey: key, client: client) else {
                        throw NoteSaveError(message: self.errorMessage)
                    }
                    return note.id
                },
                update: { id, title, body in
                    guard await self.update(id: id, title: title, body: body, client: client) != nil else {
                        throw NoteSaveError(message: self.errorMessage)
                    }
                })
            if await edit.saver.flush(using: ops) { unsavedEdits.removeAll { $0.id == edit.id } }
        }
    }

    func discardUnsavedEdits() { unsavedEdits.removeAll() }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
