//
//  CommandTests.swift
//  Command
//

import XCTest
@testable import Command

final class CommandTests: XCTestCase {
    func testJSONValueDecodesMixedObject() throws {
        let data = #"{"a":"x","b":2,"c":true,"d":null}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(v["a"], .string("x"))
        XCTAssertEqual(v["b"], .number(2))
        XCTAssertEqual(v["c"], .bool(true))
        XCTAssertEqual(v["d"], .null)
    }

    func testJSONValueDisplayString() {
        XCTAssertEqual(JSONValue.string("hi").displayString, "hi")
        XCTAssertEqual(JSONValue.number(3).displayString, "3")
        XCTAssertEqual(JSONValue.bool(false).displayString, "no")
    }

    func testOccurrenceIdentity() {
        let o = Occurrence(assignmentId: 7, title: "Standup", occursAt: "2026-06-15T09:00:00+00:00",
                           status: "todo", assigneeId: nil, scheduleKind: "routine", hidden: nil)
        XCTAssertEqual(o.id, "7@2026-06-15T09:00:00+00:00")
    }

    // Regression (B17): a day's occurrences must be ordered by their PARSED instant, not the raw
    // ISO string. "09:00:00-04:00" (13:00Z) string-sorts before "12:00:00+00:00" (12:00Z) though it
    // is chronologically later — so a naive string sort listed the agenda out of time order.
    @MainActor
    func testOccurrencesOnDay_orderByInstant_notString() {
        let store = CalendarStore()
        // 12:00Z (utc) is earlier than 13:00Z (eastern); string order is the reverse ("09" < "12").
        let utc = Occurrence(assignmentId: 1, title: "utc", occursAt: "2026-06-15T12:00:00+00:00",
                             status: "todo", assigneeId: nil, scheduleKind: "sporadic", hidden: nil)
        let eastern = Occurrence(assignmentId: 2, title: "eastern", occursAt: "2026-06-15T09:00:00-04:00",
                                 status: "todo", assigneeId: nil, scheduleKind: "sporadic", hidden: nil)
        store.occurrences = [eastern, utc]   // insertion order = the wrong (string) order
        let day = PlannerFormat.parse(utc.occursAt)!
        XCTAssertEqual(store.occurrences(on: day).map(\.title), ["utc", "eastern"])
    }

    // V5: overdue is a past-scheduled one-off that isn't done/cancelled; recurring items never count.
    // The detail page re-reads notes from the server on open; this guard decides when to adopt that
    // value. It must adopt a differing server value when there are no unsaved edits, and must NOT
    // clobber an in-progress edit or write when nothing changed.
    @MainActor
    func testDetailStoreShouldAdoptNotes() {
        XCTAssertTrue(DetailStore.shouldAdopt(fetched: "server text", current: "old", lastSaved: "old"))
        XCTAssertFalse(DetailStore.shouldAdopt(fetched: "server text", current: "typing…", lastSaved: "old"))
        XCTAssertFalse(DetailStore.shouldAdopt(fetched: "same", current: "same", lastSaved: "same"))
        XCTAssertTrue(DetailStore.shouldAdopt(fetched: "recovered", current: "", lastSaved: ""))  // stale-empty → server wins
    }

    func testIsOverdue() {
        let now = PlannerFormat.parse("2026-07-04T12:00:00+00:00")!
        func a(kind: String = "sporadic", status: String = "todo", start: String?) -> Assignment {
            Assignment(id: 1, accountId: 1, goalId: nil, title: "t", details: nil, assigneeId: nil,
                       scheduleKind: kind, rrule: kind == "routine" ? "FREQ=DAILY" : nil,
                       scheduledStart: start, scheduledEnd: nil, timezone: nil, leadTimeMinutes: nil,
                       status: status, priority: 0, hidden: false, archivedAt: nil, notes: nil, origin: "manual",
                       createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        }
        XCTAssertTrue(PlannerFormat.isOverdue(a(start: "2026-07-01T09:00:00+00:00"), now: now))   // past
        XCTAssertFalse(PlannerFormat.isOverdue(a(start: "2026-07-08T09:00:00+00:00"), now: now))  // future
        XCTAssertFalse(PlannerFormat.isOverdue(a(status: "done", start: "2026-07-01T09:00:00+00:00"), now: now))
        XCTAssertFalse(PlannerFormat.isOverdue(a(kind: "routine", start: "2026-01-01T09:00:00+00:00"), now: now))
        XCTAssertFalse(PlannerFormat.isOverdue(a(start: nil), now: now))   // unscheduled
    }
}
