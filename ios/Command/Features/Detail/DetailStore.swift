//
//  DetailStore.swift
//  Command
//
//  Backs the entity detail page: the persistent notes field (debounced save) and the checklist
//  (`task_items`) for one parent — an assignment, goal, or logged activity. The notes save routes
//  to the right endpoint per parent type; the checklist is the generic /api/items surface.
//

import Foundation
import Observation

@MainActor
@Observable
final class DetailStore {
    let parentType: String   // "assignment" | "goal" | "activity"
    let parentId: Int

    var title: String
    var notes: String
    var status: String
    var items: [TaskItem] = []
    var errorMessage: String?
    var savingNotes = false

    /// Handed the server's copy after every successful title / notes / status save, so the page's
    /// host can fold it into the shared lists (the Tasks list otherwise kept the old title until a
    /// manual refresh). Set by EntityDetailView.
    var onAssignmentSaved: ((Assignment) -> Void)?
    var onGoalSaved: ((Goal) -> Void)?

    private var saveTask: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    private var lastSavedTitle: String
    private var lastSavedNotes: String

    init(parentType: String, parentId: Int, title: String, notes: String, status: String = "") {
        self.parentType = parentType
        self.parentId = parentId
        self.title = title
        self.notes = notes
        self.status = status
        self.lastSavedTitle = title
        self.lastSavedNotes = notes
    }

    // MARK: Status (goals + assignments)

    /// Persist a new status. Optimistic: the UI reflects it immediately and reverts on failure.
    /// Goals PATCH /api/goals/{id}; assignments POST /api/assignments/{id}/status.
    func updateStatus(_ newStatus: String, client: APIClient) async {
        guard newStatus != status else { return }
        let previous = status
        status = newStatus
        do {
            switch parentType {
            case "goal":       saved(try await client.updateGoalStatus(id: parentId, status: newStatus))
            case "assignment": saved(try await client.setAssignmentStatus(id: parentId, status: newStatus))
            default:           return
            }
            errorMessage = nil
        } catch {
            status = previous
            errorMessage = describe(error)
        }
    }

    // MARK: Checklist + server-authoritative refresh

    func load(client: APIClient) async {
        await refresh(client: client)
        if let list = try? await client.listItems(parentType: parentType, parentId: parentId) {
            items = list
        }
    }

    /// Whether to adopt a server-fetched value: only when the local field has no unsaved edits
    /// (current == last-saved) and the server actually differs. Pure so it's unit-testable.
    static func shouldAdopt(fetched: String, current: String, lastSaved: String) -> Bool {
        current == lastSaved && fetched != current
    }

    /// Re-read the entity's title + notes from the server (the source of truth) so reopening the
    /// detail never shows a stale snapshot — the bug where typed notes appeared to vanish on
    /// leave-and-return was the view re-initializing from a parent's cached entity the save never
    /// updated. Adopt each field ONLY when it has no unsaved local edits (so a slow fetch can't
    /// clobber typing), and never writes anything back, so it can't accidentally blank a field.
    func refresh(client: APIClient) async {
        // Only fetch if at least one field is clean and could be refreshed.
        guard title == lastSavedTitle || notes == lastSavedNotes else { return }
        // Snapshot the saved baselines BEFORE the await: if a debounced save completes
        // during the in-flight GET, lastSaved advances to the just-saved value while the
        // fetched value still predates that save — adopting it would revert the user's
        // saved edit. So we only adopt a field whose baseline didn't move mid-fetch.
        let savedNotesBefore = lastSavedNotes
        let savedTitleBefore = lastSavedTitle
        let fetchedTitle: String
        let fetchedNotes: String
        do {
            switch parentType {
            case "assignment":
                let a = try await client.assignment(id: parentId); fetchedTitle = a.title; fetchedNotes = a.notes ?? ""
            case "goal":
                let g = try await client.goal(id: parentId); fetchedTitle = g.title; fetchedNotes = g.notes ?? ""
            default:
                let l = try await client.activity(id: parentId); fetchedTitle = l.title; fetchedNotes = l.details ?? ""
            }
        } catch {
            return   // offline / transient — keep what we have, never blank it
        }
        // Adopt only when the field is unedited AND no save landed during the fetch.
        if notes == lastSavedNotes && lastSavedNotes == savedNotesBefore {
            if Self.shouldAdopt(fetched: fetchedNotes, current: notes, lastSaved: lastSavedNotes) { notes = fetchedNotes }
            lastSavedNotes = fetchedNotes
        }
        if title == lastSavedTitle && lastSavedTitle == savedTitleBefore {
            if Self.shouldAdopt(fetched: fetchedTitle, current: title, lastSaved: lastSavedTitle) { title = fetchedTitle }
            lastSavedTitle = fetchedTitle
        }
    }

    func add(_ text: String, client: APIClient) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        do {
            let item = try await client.addItem(parentType: parentType, parentId: parentId, text: t)
            items.append(item)
            errorMessage = nil
        } catch { errorMessage = describe(error) }
    }

    /// Write `item` back over the row with the same id, wherever it now sits.
    ///
    /// An index captured BEFORE an `await` must never be reused after it. The list can change
    /// while a request is in flight — a concurrent `load()`, another toggle, an `add`, a
    /// `delete` — and then the stale index addresses a different row, or none at all. On the
    /// success path that was an unguarded `items[i] = …`, which on a shrunken array is an
    /// out-of-bounds assignment: a crash, not a glitch. Re-finding by id is also what makes
    /// "the row was deleted mid-request" correct — this quietly does nothing rather than
    /// resurrecting it. `NotesStore.replace(_:)` has always done it this way.
    private func replace(id: Int, with replacement: TaskItem) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i] = replacement
    }

    func toggle(_ item: TaskItem, client: APIClient) async {
        guard let i = items.firstIndex(of: item) else { return }
        let target = !item.done
        items[i] = mutate(item, done: target)   // optimistic; index is still valid here
        do {
            replace(id: item.id, with: try await client.updateItem(id: item.id, done: target))
            errorMessage = nil
        } catch {
            // Don't leave the UI showing a toggle the server never saved. Revert + report.
            replace(id: item.id, with: item)
            errorMessage = describe(error)
        }
    }

    func rename(_ item: TaskItem, to text: String, client: APIClient) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != item.text, items.contains(item) else { return }
        do {
            replace(id: item.id, with: try await client.updateItem(id: item.id, text: t))
            errorMessage = nil
        } catch { errorMessage = describe(error) }
    }

    func delete(at offsets: IndexSet, client: APIClient) async {
        let removed = offsets.map { items[$0] }
        items.remove(atOffsets: offsets)   // optimistic
        do {
            for item in removed { _ = try await client.deleteItem(id: item.id) }
            errorMessage = nil
        } catch {
            // A failed delete would silently reappear on the next reload — resync with server
            // truth now and surface the error rather than diverging quietly.
            errorMessage = describe(error)
            await load(client: client)
        }
    }

    func move(from source: IndexSet, to destination: Int, client: APIClient) async {
        let previous = items
        items.move(fromOffsets: source, toOffset: destination)   // optimistic
        let ids = items.map(\.id)
        do {
            items = try await client.reorderItems(parentType: parentType, parentId: parentId, orderedIds: ids)
            errorMessage = nil
        } catch {
            items = previous   // revert to the pre-move order the server still holds
            errorMessage = describe(error)
        }
    }

    // MARK: Title + notes (debounced save)

    func notesChanged(client: APIClient) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await flushNotes(client: client)
        }
    }

    func flushNotes(client: APIClient) async {
        let n = notes
        guard n != lastSavedNotes else { return }
        savingNotes = true
        defer { savingNotes = false }
        do {
            switch parentType {
            case "assignment": saved(try await client.updateAssignmentNotes(id: parentId, notes: n))
            case "goal":       saved(try await client.updateGoalNotes(id: parentId, notes: n))
            default:           _ = try await client.updateActivity(id: parentId, ActivityUpdateBody(details: n))
            }
            lastSavedNotes = n
            errorMessage = nil
        } catch { errorMessage = describe(error) }
    }

    func titleChanged(client: APIClient) {
        titleTask?.cancel()
        titleTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            await flushTitle(client: client)
        }
    }

    func flushTitle(client: APIClient) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never persist an empty title over a real one — a title is an entity's identity. If the
        // user clears it, keep the last saved value rather than blanking the record.
        guard !t.isEmpty, t != lastSavedTitle else { return }
        do {
            switch parentType {
            case "assignment": saved(try await client.updateAssignmentTitle(id: parentId, title: t))
            case "goal":       saved(try await client.updateGoalTitle(id: parentId, title: t))
            default:           _ = try await client.updateActivity(id: parentId, ActivityUpdateBody(title: t))
            }
            lastSavedTitle = t
            errorMessage = nil
        } catch { errorMessage = describe(error) }
    }

    private func saved(_ assignment: Assignment) { onAssignmentSaved?(assignment) }
    private func saved(_ goal: Goal) { onGoalSaved?(goal) }

    /// Persist any pending title + notes now (on disappear / app-background), so nothing is lost.
    func flushAll(client: APIClient) async {
        await flushNotes(client: client)
        await flushTitle(client: client)
    }

    private func mutate(_ item: TaskItem, done: Bool) -> TaskItem {
        TaskItem(id: item.id, parentType: item.parentType, parentId: item.parentId, text: item.text,
                 done: done, source: item.source, position: item.position,
                 createdAt: item.createdAt, updatedAt: item.updatedAt)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
