//
//  GoalTargetDateTests.swift
//  Command
//
//  Regression tests for a goal's `target_date`.
//
//  The bug these lock down: the MCP + agent tools document
//  `target_date` as an "ISO date" and write it date-only ("2026-10-21"), but the
//  detail page parsed it with `PlannerFormat.parse` (ISO8601DateFormatter), which
//  returns nil for a date-only string. The Target row was gated on that parse
//  succeeding, so an agent-created goal's target date never rendered at all.
//

import XCTest
@testable import Command

final class GoalTargetDateTests: XCTestCase {
    private var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current   // a target date is a wall-clock day, not an instant
        return c
    }

    /// Documents *why* `parseDay` exists: the ISO8601-based parser cannot read a date-only value.
    /// If this ever starts passing, `parseDay`'s date-only branch may be redundant.
    func testISO8601ParserCannotReadDateOnly() {
        XCTAssertNil(PlannerFormat.parse("2026-10-21"))
        XCTAssertNotNil(PlannerFormat.parse("2026-10-21T00:00:00Z"))
    }

    func testParseDayReadsDateOnly() throws {
        let d = try XCTUnwrap(PlannerFormat.parseDay("2026-10-21"), "date-only target must parse")
        let parts = gregorian.dateComponents([.year, .month, .day], from: d)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 10)
        XCTAssertEqual(parts.day, 21)
    }

    /// The app's own assignment timestamps are full ISO; parseDay must keep handling those.
    func testParseDayStillReadsFullISO() throws {
        let d = try XCTUnwrap(PlannerFormat.parseDay("2026-10-21T09:30:00Z"))
        XCTAssertEqual(d, PlannerFormat.parse("2026-10-21T09:30:00Z"))
    }

    /// A date-only value exactly as the agent tools write it.
    func testDateOnlyGoalTargetRenders() {
        let label = PlannerFormat.dayLabel("2026-10-21")
        XCTAssertNotEqual(label, "2026-10-21", "should be humanized, not the raw stored string")
        XCTAssertTrue(label.contains("2026"), "got \(label)")
        XCTAssertTrue(label.contains("21"), "got \(label)")
    }

    /// Never silently drop the user's data: an unparseable value falls back to the raw string
    /// rather than rendering nothing (which is what the original bug did).
    func testDayLabelFallsBackToRawStringInsteadOfHiding() {
        XCTAssertEqual(PlannerFormat.dayLabel("someday"), "someday")
        XCTAssertEqual(PlannerFormat.dayLabel("Q3"), "Q3")
    }

    /// What the create sheet writes must be what the parser reads back.
    func testDayStringRoundTrips() throws {
        let now = Date()
        let round = try XCTUnwrap(PlannerFormat.parseDay(PlannerFormat.dayString(now)))
        let a = gregorian.dateComponents([.year, .month, .day], from: now)
        let b = gregorian.dateComponents([.year, .month, .day], from: round)
        XCTAssertEqual(a, b)
    }

    /// The serialized form must be the date-only shape the server + agent tools expect.
    func testDayStringIsDateOnlyISO() {
        let s = PlannerFormat.dayString(Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertEqual(s.count, 10, "expected yyyy-MM-dd, got \(s)")
        XCTAssertNil(s.firstIndex(of: "T"), "must not carry a time component: \(s)")
    }
}
