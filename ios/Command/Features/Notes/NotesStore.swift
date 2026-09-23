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

    struct UnsavedNoteEdit: Identifiable, Equatable {
        let id = UUID()
        let noteId: Int?
        let text: String
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
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let note = try await client.createNote(body: body, source: "typed", hidden: hidden)
            notes.insert(note, at: 0)
            draft = ""
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
    func create(title: String?, body: String, client: APIClient) async -> Note? {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return nil }
        do {
            let note = try await client.createNote(body: b, source: "typed", title: title)
            notes.insert(note, at: 0)
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
            notes.insert(note, at: 0)
            errorMessage = nil
            pollTitleIfNeeded(note, client: client)
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
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
            notes.insert(note, at: 0); errorMessage = nil; return note
        } catch {
            errorMessage = describe(error); return nil
        }
    }

    /// Keep an edit the closing editor couldn't save. A newer edit of the same note replaces the
    /// older one (it contains it — the editor holds the whole note).
    func park(noteId: Int?, text: String) {
        if let noteId { unsavedEdits.removeAll { $0.noteId == noteId } }
        unsavedEdits.append(UnsavedNoteEdit(noteId: noteId, text: text))
    }

    /// Retry every parked edit; the ones that still fail stay parked.
    func retryUnsavedEdits(client: APIClient) async {
        for edit in unsavedEdits {
            let title = Note.firstLine(of: edit.text)
            let saved: Note?
            if let id = edit.noteId {
                saved = await update(id: id, title: title, body: edit.text, client: client)
            } else {
                saved = await create(title: title.isEmpty ? nil : title, body: edit.text, client: client)
            }
            if saved != nil { unsavedEdits.removeAll { $0.id == edit.id } }
        }
    }

    func discardUnsavedEdits() { unsavedEdits.removeAll() }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
