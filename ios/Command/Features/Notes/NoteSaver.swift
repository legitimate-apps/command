//
//  NoteSaver.swift
//  Command
//
//  The note editor's save engine, split out of NoteDetailView so its ordering rules are testable.
//
//  Two guarantees the editor relies on:
//   - Saves are SERIALIZED. A save requested while another is in flight waits for it, then saves
//     the LATEST text — so words typed while a brand-new note's create is on the wire land on the
//     created note (as an update) instead of being dropped or double-creating.
//   - A failed save is never mistaken for a saved one. `lastSavedText` only advances on success,
//     so the text stays "unsaved" (and the editor keeps it) until a retry lands or the user
//     explicitly discards it.
//
//  The network work runs in an unstructured Task, so cancelling the caller (the editor's debounce
//  task, or a view going away) never cancels a request that's already on the wire.
//

import Foundation
import Observation

@MainActor
@Observable
final class NoteSaver {
    enum State: Equatable { case idle, saving, saved, failed(String) }

    /// The two server operations a save needs, supplied per call (the view builds them from its
    /// environment's store + client; tests supply fakes). Both throw on failure.
    struct Ops {
        /// Create a note from (title, full text); returns its id.
        var create: @MainActor (_ title: String?, _ body: String) async throws -> Int
        /// Update note `id` with (title, full text).
        var update: @MainActor (_ id: Int, _ title: String, _ body: String) async throws -> Void
    }

    /// The editor's current text. The view writes every keystroke here; a save always sends the
    /// value current when it STARTS, never a stale snapshot captured while it was queued.
    var text: String
    private(set) var noteId: Int?
    private(set) var state: State = .idle
    /// Trimmed text of the last successful save (or of the note as loaded).
    private(set) var lastSavedText: String

    private var inFlight: Task<Bool, Never>?

    init(noteId: Int?, text: String) {
        self.noteId = noteId
        self.text = text
        self.lastSavedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True while the text holds content the server doesn't have. An all-whitespace field never
    /// counts — a blank field is far more likely an accidental select-all-delete than an intent to
    /// erase (Delete is the explicit way to remove a note), so it is never persisted over content.
    var hasUnsavedChanges: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != lastSavedText
    }

    var isFailed: Bool { if case .failed = state { return true } else { return false } }

    /// Save the current text once (create the note the first time, update it after). Waits for any
    /// save already in flight first. Returns false only if THIS attempt failed; true when it
    /// succeeded or there was nothing to save.
    @discardableResult
    func save(using ops: Ops) async -> Bool {
        // Whoever sees the running save finish clears it. Awaiting an already-finished task's value
        // needn't suspend, so looping on a stale `inFlight` until its owner resumed to clear it
        // could spin the main actor forever (the owner never got to run).
        while let running = inFlight {
            _ = await running.value
            if inFlight == running { inFlight = nil }
        }
        guard hasUnsavedChanges else { return true }
        let full = text
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = Note.firstLine(of: full)
        let id = noteId
        state = .saving
        let task = Task { @MainActor () -> Bool in
            do {
                if let id {
                    try await ops.update(id, title, full)
                } else {
                    self.noteId = try await ops.create(title.isEmpty ? nil : title, full)
                }
                self.lastSavedText = trimmed
                self.state = .saved
                return true
            } catch {
                self.state = .failed(Self.describe(error))
                return false
            }
        }
        inFlight = task
        let ok = await task.value
        if inFlight == task { inFlight = nil }
        return ok
    }

    /// Save until nothing unsaved remains (text typed during a save gets its own follow-up save).
    /// Returns false if a save failed — the caller must keep the text, not close over it.
    func flush(using ops: Ops) async -> Bool {
        repeat {
            guard await save(using: ops) else { return false }
        } while hasUnsavedChanges
        return true
    }

    /// Mark `text` as what the server now holds (e.g. after restoring a revision).
    func markSaved(_ text: String) {
        self.text = text
        lastSavedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .saved
    }

    /// Typing after a save resets the indicator (a failure stays visible until a save succeeds).
    func textDidChange() {
        if state == .saved { state = .idle }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// An error carrying a store's already-described message (the stores report failures through
/// `errorMessage` rather than throwing).
struct NoteSaveError: LocalizedError {
    let message: String?
    var errorDescription: String? { message ?? "Couldn't save the note." }
}
