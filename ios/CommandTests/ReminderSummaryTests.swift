//
//  ReminderSummaryTests.swift
//  Command
//
//  The reminder engine fires correctly (proven server-side across DST and volume); what was
//  missing was any way to *see* the resulting reminder or set the offset per assignment. The
//  detail page showed a bare "Lead time 0", which reads as broken on a self-assigned item.
//  These lock the wording + the arithmetic to the server's rule: remind_at = occurs_at - lead.
//

import XCTest
@testable import Command

final class ReminderSummaryTests: XCTestCase {
    /// Mirrors the server: a one-off's reminder lands `lead` before the scheduled instant.
    func testOneOffSubtractsTheLeadFromTheDueTime() {
        let s = PlannerFormat.reminderSummary(
            scheduleKind: "sporadic", scheduledStart: "2026-07-02T09:00:00Z", status: "todo",
            effectiveLead: 1440)
        XCTAssertTrue(s.contains("Jul 1, 2026"), "1 day before Jul 2 is Jul 1 — got: \(s)")
        XCTAssertTrue(s.contains("1 day before it's due"), s)
    }

    func testZeroLeadRemindsAtTheDueTime() {
        let s = PlannerFormat.reminderSummary(
            scheduleKind: "sporadic", scheduledStart: "2026-07-02T09:00:00Z", status: "todo",
            effectiveLead: 0)
        XCTAssertTrue(s.contains("Jul 2, 2026"), s)
        XCTAssertFalse(s.contains("before it's due"), "a 0 lead fires at the due time: \(s)")
    }

    /// The inherited case is what testers hit: notice came only from the delegatee's window and
    /// nothing said so.
    func testNamesTheDelegateeWhenTheOffsetIsInherited() {
        let s = PlannerFormat.reminderSummary(
            scheduleKind: "sporadic", scheduledStart: "2026-07-02T09:00:00Z", status: "todo",
            effectiveLead: 1440, sourceName: "Dana Whitlock")
        XCTAssertTrue(s.contains("from Dana Whitlock"), s)
    }

    func testOmitsTheSourceWhenSetOnTheAssignment() {
        let s = PlannerFormat.reminderSummary(
            scheduleKind: "sporadic", scheduledStart: "2026-07-02T09:00:00Z", status: "todo",
            effectiveLead: 1440, sourceName: nil)
        XCTAssertFalse(s.contains("from "), s)
    }

    func testRoutineDescribesEachOccurrence() {
        let lead = PlannerFormat.reminderSummary(
            scheduleKind: "routine", scheduledStart: nil, status: "todo", effectiveLead: 120)
        XCTAssertTrue(lead.contains("before each occurrence"), lead)

        let none = PlannerFormat.reminderSummary(
            scheduleKind: "routine", scheduledStart: nil, status: "todo", effectiveLead: 0)
        XCTAssertTrue(none.contains("at each occurrence"), none)
    }

    /// An unscheduled item silently has no reminder — say so rather than imply one is coming.
    func testUnscheduledSaysNoReminderWillFire() {
        let s = PlannerFormat.reminderSummary(
            scheduleKind: "sporadic", scheduledStart: nil, status: "todo", effectiveLead: 60)
        XCTAssertTrue(s.contains("Not scheduled"), s)
    }

    /// Matches the server, which skips done/cancelled when computing reminders.
    func testDoneAndCancelledWillNotFire() {
        for status in ["done", "cancelled"] {
            let s = PlannerFormat.reminderSummary(
                scheduleKind: "sporadic", scheduledStart: "2026-07-02T09:00:00Z", status: status,
                effectiveLead: 60)
            XCTAssertTrue(s.contains("no reminder will fire"), "\(status): \(s)")
        }
    }

    /// A week's notice is a real preset; make sure the label doesn't degrade to "7 days"/"10080m".
    func testWeekLeadReadsAsAWeek() {
        let s = PlannerFormat.reminderSummary(
            scheduleKind: "sporadic", scheduledStart: "2026-07-15T09:00:00Z", status: "todo",
            effectiveLead: 10080)
        XCTAssertTrue(s.contains("1 week before it's due"), s)
        XCTAssertTrue(s.contains("Jul 8, 2026"), "a week before Jul 15 is Jul 8 — got: \(s)")
    }
}
