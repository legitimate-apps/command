//
//  MyWorkSectionsTests.swift
//  CommandTests
//
//  My Work sectioning. The old filters had no home for an unfinished occurrence from a past day
//  (not today, not upcoming, not done), so overdue work silently vanished from the screen.
//

import XCTest
@testable import Command

final class MyWorkSectionsTests: XCTestCase {
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func occ(_ id: Int, _ at: String, _ status: String) -> Occurrence {
        Occurrence(assignmentId: id, title: "A\(id)", occursAt: at, status: status,
                   assigneeId: nil, scheduleKind: "sporadic", hidden: false)
    }

    func test_pastUnfinishedWorkIsOverdue_notDropped() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-10T12:00:00Z"))
        let items = [
            occ(1, "2026-08-08T09:00:00Z", "todo"),        // two days ago, never done
            occ(2, "2026-08-10T09:00:00Z", "todo"),        // earlier today
            occ(3, "2026-08-12T09:00:00Z", "scheduled"),   // later this week
            occ(4, "2026-08-07T09:00:00Z", "done"),
            occ(5, "2026-08-09T09:00:00Z", "cancelled"),   // cancelled is closed, not overdue
            occ(6, "2026-08-11T09:00:00Z", "done"),        // finished early — still shown as done
        ]
        let s = MyWorkSections(items, now: now, calendar: utc)
        XCTAssertEqual(s.overdue.map(\.assignmentId), [1])
        XCTAssertEqual(s.today.map(\.assignmentId), [2])
        XCTAssertEqual(s.upcoming.map(\.assignmentId), [3])
        XCTAssertEqual(s.doneRecently.map(\.assignmentId), [6, 5, 4])
        let placed = s.overdue.count + s.today.count + s.upcoming.count + s.doneRecently.count
        XCTAssertEqual(placed, items.count, "every occurrence lands in exactly one section")
        XCTAssertTrue(MyWorkSections.isFinished("cancelled"))
    }
}
