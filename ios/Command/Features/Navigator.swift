//
//  Navigator.swift
//  Command
//
//  Cross-column selection + one-shot menu intents for the regular-width
//  (iPad / Mac) shell. Lives in the environment so scene `.commands` — which sit
//  outside the view tree — can drive the three columns. Selection logic is pure
//  so it can be unit-tested without a running UI. Never allocated on the compact
//  (iPhone) path, which keeps using `MainTabView` untouched.
//

import Foundation
import Observation

@MainActor
@Observable
final class Navigator {
    /// Whether this shell actually has a **detail column** to route entity taps into.
    /// The iPad/Mac split shell does (true). The compact tab shell injects a Navigator
    /// with this **false**: it carries the one-shot compose/find/capture intents so ⌘N /
    /// ⌘F / ⌘⇧C work with a hardware keyboard, but entity taps still open sheets (a tab
    /// shell has nowhere to show a third column). Section views test this — not merely
    /// `nav != nil` — before routing a tap to `select`/`selectedNoteId`/etc.
    let hasDetailColumn: Bool

    init(hasDetailColumn: Bool = true) {
        self.hasDetailColumn = hasDetailColumn
    }

    /// Column 1 ↔ column 2: which primary section is showing.
    var destination: AppDestination = .calendar
    /// Column 3: an assignment / goal / log opened as a detail page.
    var detail: DetailSubject?
    /// Column 3 alternates for sections whose detail isn't a `DetailSubject`.
    var selectedNoteId: Int?
    var selectedPersonId: Int?
    /// The calendar's selected day (drives the agenda column).
    var selectedDay: Date?
    /// One-shot intents fired by the Mac/iPad menu commands; the relevant view
    /// consumes each and resets it to false. (`focusCapture` ← ⌘⇧C; `composeNote`
    /// ← ⌘N; `composeAssignment` ← ⌘⇧N; `startNewChat` ← ⌘⌥N; `focusSearch` ← ⌘F.)
    var focusCapture = false
    var composeNote = false
    var composeAssignment = false
    var startNewChat = false
    /// Text to pre-fill the assistant's composer with, set by an "Ask the assistant" action
    /// elsewhere in the app. Deliberately a DRAFT rather than an auto-send: the user reads and
    /// edits it before spending a turn, so a stray tap never costs them budget.
    var assistantSeed: String?
    var startVoiceConversation = false
    var focusSearch = false   // ⌘F — reveals the active list's search field

    /// Switch the primary section. Selecting a new section drops stale detail and
    /// per-section selections so column 3 never shows a leftover from elsewhere.
    func show(_ dest: AppDestination) {
        destination = dest
        detail = nil
        selectedNoteId = nil
        selectedPersonId = nil
    }

    /// Open an entity in the detail column, syncing the section it belongs to so
    /// the sidebar selection and content column stay coherent.
    func select(_ subject: DetailSubject) {
        switch subject {
        case .assignment, .goal: destination = .tasks
        case .log:               destination = .calendar
        }
        // Clear the other columns' per-section selections (as `show` does). Otherwise a leftover
        // selectedPersonId/NoteId survives behind `detail`, and once this subject is closed
        // (detail = nil) `DetailColumn` falls through to that stale id — rendering, say, a person's
        // detail while the sidebar and content column show Tasks.
        selectedNoteId = nil
        selectedPersonId = nil
        detail = subject
    }

    /// An assignment was deleted or archived: close its detail page if column 3 is showing it,
    /// so the removed item doesn't linger (still editable) after it left the lists.
    func assignmentRemoved(id: Int) {
        if case .assignment(let a) = detail, a.id == id { detail = nil }
    }

    /// Request the capture bar take focus (consumed + reset by the bar).
    func requestCapture() { focusCapture = true }
}
