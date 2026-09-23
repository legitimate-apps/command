//
//  NavigatorTests.swift
//  CommandTests
//
//  Pure-logic tests for the iPad/Mac shell's cross-column selection model.
//

import XCTest
@testable import Command

@MainActor
final class NavigatorTests: XCTestCase {

    func test_show_changesDestination_andClearsDetailAndSelections() {
        let nav = Navigator()
        nav.detail = .goal(.fixture(id: 1))
        nav.selectedNoteId = 9
        nav.selectedPersonId = 3

        nav.show(.notes)

        XCTAssertEqual(nav.destination, .notes)
        XCTAssertNil(nav.detail)
        XCTAssertNil(nav.selectedNoteId)
        XCTAssertNil(nav.selectedPersonId)
    }

    func test_select_assignment_setsDetail_andSyncsToTasks() {
        let nav = Navigator()
        nav.show(.calendar)

        nav.select(.assignment(.fixture(id: 5)))

        XCTAssertEqual(nav.destination, .tasks)
        if case .assignment(let a)? = nav.detail {
            XCTAssertEqual(a.id, 5)
        } else {
            XCTFail("expected an assignment detail")
        }
    }

    // Regression (B13): opening a subject via select() must clear the other columns'
    // per-section selections, exactly like show(). Otherwise a leftover selectedPersonId
    // survives behind `detail`, and once the subject is closed the detail column falls
    // through to that stale id — rendering a person while the sidebar/content show Tasks.
    func test_select_clearsStalePerSectionSelections() {
        let nav = Navigator()
        nav.show(.people)
        nav.selectedPersonId = 42
        nav.selectedNoteId = 7

        nav.select(.assignment(.fixture(id: 5)))

        XCTAssertEqual(nav.destination, .tasks)
        XCTAssertNil(nav.selectedPersonId)
        XCTAssertNil(nav.selectedNoteId)
        if case .assignment(let a)? = nav.detail { XCTAssertEqual(a.id, 5) }
        else { XCTFail("expected an assignment detail") }
    }

    func test_select_goal_syncsToTasks() {
        let nav = Navigator()
        nav.select(.goal(.fixture(id: 7)))
        XCTAssertEqual(nav.destination, .tasks)
    }

    func test_select_log_syncsToCalendar() {
        let nav = Navigator()
        nav.show(.people)
        nav.select(.log(.fixture(id: 2)))
        XCTAssertEqual(nav.destination, .calendar)
    }

    func test_requestCapture_setsFlag() {
        let nav = Navigator()
        XCTAssertFalse(nav.focusCapture)
        nav.requestCapture()
        XCTAssertTrue(nav.focusCapture)
    }

    func test_appDestination_primary_excludesAccount_andHasFiveSections() {
        XCTAssertEqual(AppDestination.primary,
                       [.calendar, .notes, .assistant, .tasks, .people])
        XCTAssertFalse(AppDestination.primary.contains(.account))
    }

    func test_appDestination_shortcutNumbers() {
        XCTAssertEqual(AppDestination.calendar.shortcutNumber, 1)
        XCTAssertEqual(AppDestination.people.shortcutNumber, 5)
        XCTAssertNil(AppDestination.account.shortcutNumber)
    }

    // B8: the split shell's Navigator has a detail column by default; the compact tab
    // shell injects one WITHOUT (hasDetailColumn == false). The section views branch on
    // this — so compose/find intents still fire in the tab shell, but entity taps fall
    // through to sheets instead of routing to a nonexistent detail column.
    func test_hasDetailColumn_defaultsTrueForSplitShell() {
        XCTAssertTrue(Navigator().hasDetailColumn)
    }

    func test_composeOnlyNavigator_carriesIntents_withoutDetailColumn() {
        let nav = Navigator(hasDetailColumn: false)
        XCTAssertFalse(nav.hasDetailColumn)
        // The one-shot compose channel still works (this is what makes ⌘N/⌘⇧N/⌘⌥N reach
        // the tab shell's section views).
        nav.show(.notes); nav.composeNote = true
        XCTAssertEqual(nav.destination, .notes)
        XCTAssertTrue(nav.composeNote)
        nav.show(.tasks); nav.composeAssignment = true
        XCTAssertEqual(nav.destination, .tasks)
        XCTAssertTrue(nav.composeAssignment)
    }
}

// MARK: - Minimal fixtures (only the fields the tests read matter; the rest are
// neutral placeholders so the memberwise initializers compile).

extension Goal {
    static func fixture(id: Int) -> Goal {
        Goal(id: id, accountId: 1, title: "Goal \(id)", description: nil,
             status: "open", targetDate: nil, notes: nil,
             createdAt: "2026-06-26T00:00:00Z", updatedAt: "2026-06-26T00:00:00Z")
    }
}

extension Assignment {
    static func fixture(id: Int) -> Assignment {
        Assignment(id: id, accountId: 1, goalId: nil, title: "Assignment \(id)",
                   details: nil, assigneeId: nil, scheduleKind: "sporadic", rrule: nil,
                   scheduledStart: nil, scheduledEnd: nil, timezone: nil, leadTimeMinutes: nil,
                   status: "todo", priority: 0, hidden: false, archivedAt: nil, notes: nil, origin: "manual",
                   createdAt: "2026-06-26T00:00:00Z", updatedAt: "2026-06-26T00:00:00Z")
    }
}

extension Activity {
    static func fixture(id: Int) -> Activity {
        Activity(id: id, accountId: 1, actorId: nil, actorSlug: nil, actorName: nil,
                 title: "Activity \(id)", details: nil, category: nil,
                 occurredAt: "2026-06-26T00:00:00Z", durationMinutes: nil, goalId: nil,
                 assignmentId: nil, occurrenceDate: nil, source: "manual", hidden: false,
                 createdAt: "2026-06-26T00:00:00Z", updatedAt: "2026-06-26T00:00:00Z")
    }
}
