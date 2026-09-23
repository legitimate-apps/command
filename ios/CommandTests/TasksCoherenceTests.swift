//
//  TasksCoherenceTests.swift
//  CommandTests
//
//  Keeping the Tasks list, the calendar, and the detail column coherent after a delete, an
//  archive, or a detail-page edit.
//

import XCTest
@testable import Command

@MainActor
final class TasksCoherenceTests: XCTestCase {
    func test_detailEditFoldsIntoTheTasksList() {
        let store = TasksStore()
        store.assignments = [.fixture(id: 1), .fixture(id: 2)]
        let edited = Assignment(id: 2, accountId: 1, goalId: nil, title: "Renamed",
                                details: nil, assigneeId: nil, scheduleKind: "sporadic", rrule: nil,
                                scheduledStart: nil, scheduledEnd: nil, timezone: nil, leadTimeMinutes: nil,
                                status: "todo", priority: 0, hidden: false, archivedAt: nil, notes: "n", origin: "manual",
                                createdAt: "2026-06-26T00:00:00Z", updatedAt: "2026-06-27T00:00:00Z")
        store.apply(edited)
        XCTAssertEqual(store.assignments.map(\.title), ["Assignment 1", "Renamed"])
    }

    func test_removedAssignmentClosesItsDetailOnly() {
        let nav = Navigator()
        nav.select(.assignment(.fixture(id: 5)))
        nav.assignmentRemoved(id: 6)
        XCTAssertNotNil(nav.detail, "another assignment's removal leaves this page open")
        nav.assignmentRemoved(id: 5)
        XCTAssertNil(nav.detail)
    }

    func test_calendarPrunesARemovedAssignmentsOccurrences() {
        let cal = CalendarStore()
        cal.occurrences = [
            Occurrence(assignmentId: 1, title: "Gone", occursAt: "2026-08-10T09:00:00Z", status: "todo",
                       assigneeId: nil, scheduleKind: "routine", hidden: false),
            Occurrence(assignmentId: 1, title: "Gone", occursAt: "2026-08-11T09:00:00Z", status: "todo",
                       assigneeId: nil, scheduleKind: "routine", hidden: false),
            Occurrence(assignmentId: 2, title: "Stays", occursAt: "2026-08-10T10:00:00Z", status: "todo",
                       assigneeId: nil, scheduleKind: "sporadic", hidden: false),
        ]
        cal.removeOccurrences(ofAssignment: 1)
        XCTAssertEqual(cal.occurrences.map(\.title), ["Stays"])
    }
}
