//
//  AssistantSurfacesTests.swift
//  CommandTests
//
//  Pure contracts behind Track 3. UI rendering, microphone capture, WidgetKit placement,
//  and Siri routing are system surfaces and are reported separately as non-unit-testable.
//

import XCTest
@testable import Command

final class AssistantSurfacesTests: XCTestCase {
    // `testVoiceFeatureGatesStayOffBeforeTheirDeclaredOS` was removed with
    // `AssistantSurfaceAvailability` on 2026-08-03. It asserted `26 >= 26` against a helper the
    // app never called, so it was green whatever the real `#available` gates did — a passing
    // test that verified nothing is worse than no test, because it reads like coverage.

    func testPreparedVoiceLaunchNeverPromptsFromHardwareEntry() {
        XCTAssertEqual(VoiceLaunchPolicy.decision(for: .authorized), .beginListening)
        XCTAssertEqual(VoiceLaunchPolicy.decision(for: .undetermined), .explainBeforeRequesting)
        XCTAssertEqual(VoiceLaunchPolicy.decision(for: .denied), .openSettings)
    }

    func testAskCommandValidationTrimsAndRejectsBlankInput() throws {
        XCTAssertEqual(try VoiceInputValidator.cleaned("  What is next?\n"), "What is next?")
        XCTAssertThrowsError(try VoiceInputValidator.cleaned(" \n\t "))
    }

    func testAgendaBuilderOrdersTodayAndFindsNextUp() throws {
        let cal = fixedCalendar
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T14:00:00Z"))
        let occurrences = [
            AgendaOccurrenceInput(assignmentId: 3, title: "Evening review", occursAt: "2026-08-02T18:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false),
            AgendaOccurrenceInput(assignmentId: 1, title: "Morning notes", occursAt: "2026-08-02T09:00:00Z", status: "done", scheduleKind: "sporadic", hidden: false),
            AgendaOccurrenceInput(assignmentId: 2, title: "Afternoon call", occursAt: "2026-08-02T15:30:00Z", status: "scheduled", scheduleKind: "sporadic", hidden: false),
            AgendaOccurrenceInput(assignmentId: 4, title: "Hidden", occursAt: "2026-08-02T16:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: true),
        ]

        let snapshot = WidgetAgendaBuilder.make(
            occurrences: occurrences, assignments: [], now: now, calendar: cal
        )

        XCTAssertEqual(snapshot.today.map(\.title), ["Morning notes", "Afternoon call", "Evening review"])
        XCTAssertEqual(snapshot.nextUp?.title, "Afternoon call")
    }

    func testAgendaBuilderCountsOnlyVisibleOverdueSporadicAssignments() throws {
        let cal = fixedCalendar
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T14:00:00Z"))
        let assignments = [
            AgendaAssignmentInput(id: 1, title: "Late", scheduledStart: "2026-08-01T12:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false, archived: false),
            AgendaAssignmentInput(id: 2, title: "Routine", scheduledStart: "2026-08-01T12:00:00Z", status: "todo", scheduleKind: "routine", hidden: false, archived: false),
            AgendaAssignmentInput(id: 3, title: "Done", scheduledStart: "2026-08-01T12:00:00Z", status: "done", scheduleKind: "sporadic", hidden: false, archived: false),
            AgendaAssignmentInput(id: 4, title: "Hidden", scheduledStart: "2026-08-01T12:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: true, archived: false),
            AgendaAssignmentInput(id: 5, title: "Archived", scheduledStart: "2026-08-01T12:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false, archived: true),
            AgendaAssignmentInput(id: 6, title: "Future", scheduledStart: "2026-08-03T12:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false, archived: false),
        ]

        let snapshot = WidgetAgendaBuilder.make(
            occurrences: [], assignments: assignments, now: now, calendar: cal
        )

        XCTAssertEqual(snapshot.overdueCount, 1)
    }

    func testAgendaBuilderFormatsEmptyStateAndCountSummary() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T14:00:00Z"))
        let empty = WidgetAgendaBuilder.make(occurrences: [], assignments: [], now: now, calendar: fixedCalendar)
        XCTAssertEqual(empty.summary, "Nothing scheduled today")

        let occurrence = AgendaOccurrenceInput(
            assignmentId: 1, title: "One thing", occursAt: "2026-08-02T18:00:00Z",
            status: "todo", scheduleKind: "sporadic", hidden: false
        )
        let populated = WidgetAgendaBuilder.make(
            occurrences: [occurrence], assignments: [], now: now, calendar: fixedCalendar
        )
        XCTAssertEqual(populated.summary, "1 item today")
    }

    func testWidgetRecomputesTodayNextUpAndOverdueForTheRenderInstant() throws {
        // The snapshot used to bake today / next-up / overdue at write time, so the widget kept
        // showing yesterday after midnight, a started item stayed "next up", and nothing ever
        // turned overdue until the app wrote again. It now stores the window and recomputes.
        let iso = ISO8601DateFormatter()
        let written = try XCTUnwrap(iso.date(from: "2026-08-02T14:00:00Z"))
        let occurrences = [
            AgendaOccurrenceInput(assignmentId: 1, title: "Call", occursAt: "2026-08-02T15:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false),
            AgendaOccurrenceInput(assignmentId: 2, title: "Review", occursAt: "2026-08-02T17:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false),
            AgendaOccurrenceInput(assignmentId: 3, title: "Tomorrow gym", occursAt: "2026-08-03T07:00:00Z", status: "todo", scheduleKind: "routine", hidden: false),
            AgendaOccurrenceInput(assignmentId: 4, title: "Last week", occursAt: "2026-07-25T07:00:00Z", status: "todo", scheduleKind: "routine", hidden: false),
        ]
        let assignments = [
            AgendaAssignmentInput(id: 2, title: "Review", scheduledStart: "2026-08-02T17:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false, archived: false),
        ]
        let snapshot = WidgetAgendaBuilder.make(occurrences: occurrences, assignments: assignments,
                                                now: written, calendar: fixedCalendar)
        XCTAssertEqual(snapshot.items.map(\.title), ["Call", "Review", "Tomorrow gym"],
                       "the window keeps the coming days (and drops the past), not just today")

        let atWrite = snapshot.agenda(at: written, calendar: fixedCalendar)
        XCTAssertEqual(atWrite.nextUp?.title, "Call")
        XCTAssertEqual(atWrite.overdueCount, 0)

        let afterCall = snapshot.agenda(at: try XCTUnwrap(iso.date(from: "2026-08-02T15:30:00Z")), calendar: fixedCalendar)
        XCTAssertEqual(afterCall.nextUp?.title, "Review", "a started item stops being next up")

        let evening = snapshot.agenda(at: try XCTUnwrap(iso.date(from: "2026-08-02T18:00:00Z")), calendar: fixedCalendar)
        XCTAssertEqual(evening.overdueCount, 1, "a one-off whose start passed becomes overdue")

        let nextMorning = snapshot.agenda(at: try XCTUnwrap(iso.date(from: "2026-08-03T06:00:00Z")), calendar: fixedCalendar)
        XCTAssertEqual(nextMorning.today.map(\.title), ["Tomorrow gym"], "after midnight, today is the new day")
        XCTAssertEqual(nextMorning.nextUp?.title, "Tomorrow gym")
    }

    func testWidgetTimelineHasAnEntryAtEveryChangeWithinTheDay() throws {
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-08-02T14:00:00Z"))
        let snapshot = WidgetAgendaBuilder.make(
            occurrences: [
                AgendaOccurrenceInput(assignmentId: 1, title: "Call", occursAt: "2026-08-02T15:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false),
                AgendaOccurrenceInput(assignmentId: 2, title: "Done", occursAt: "2026-08-02T16:00:00Z", status: "done", scheduleKind: "sporadic", hidden: false),
                AgendaOccurrenceInput(assignmentId: 3, title: "Far", occursAt: "2026-08-05T09:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false),
            ],
            assignments: [
                AgendaAssignmentInput(id: 1, title: "Call", scheduledStart: "2026-08-02T15:00:00Z", status: "todo", scheduleKind: "sporadic", hidden: false, archived: false),
            ],
            now: now, calendar: fixedCalendar)
        let dates = snapshot.timelineDates(after: now, calendar: fixedCalendar).map { iso.string(from: $0) }
        XCTAssertEqual(dates, [
            "2026-08-02T15:00:00Z",   // the one-off's start → overdue ticks up
            "2026-08-02T15:00:01Z",   // just past the start → next up moves on
            "2026-08-03T00:00:00Z",   // midnight → a new today
        ])
    }

    func testFingerprintIgnoresGeneratedAtSoUnchangedAgendasDontSpendAReloadBudget() throws {
        // WidgetKit meters timeline reloads. The app rebuilds this snapshot on every planner
        // mutation, so if a rebuild at a later instant looked "new" we would spend the day's
        // whole budget in minutes and the widget would silently stop updating.
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T15:00:00Z"))
        let occurrence = AgendaOccurrenceInput(
            assignmentId: 1, title: "Standup", occursAt: "2026-08-02T15:00:00Z",
            status: "pending", scheduleKind: "routine", hidden: false
        )
        let earlier = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T09:00:00Z"))
        let later = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T09:04:31Z"))

        let a = WidgetAgendaBuilder.make(
            occurrences: [occurrence], assignments: [], now: earlier, calendar: fixedCalendar
        )
        let b = WidgetAgendaBuilder.make(
            occurrences: [occurrence], assignments: [], now: later, calendar: fixedCalendar
        )
        XCTAssertNotEqual(a, b, "generatedAt moved, so plain equality must not be the gate")
        XCTAssertEqual(a.contentFingerprint, b.contentFingerprint)

        // Anything the widget actually draws still counts as a change.
        let renamed = AgendaOccurrenceInput(
            assignmentId: 1, title: "Standup (moved)", occursAt: "2026-08-02T15:00:00Z",
            status: "pending", scheduleKind: "routine", hidden: false
        )
        let retitled = WidgetAgendaBuilder.make(
            occurrences: [renamed], assignments: [], now: earlier, calendar: fixedCalendar
        )
        XCTAssertNotEqual(a.contentFingerprint, retitled.contentFingerprint)

        let done = AgendaOccurrenceInput(
            assignmentId: 1, title: "Standup", occursAt: "2026-08-02T15:00:00Z",
            status: "done", scheduleKind: "routine", hidden: false
        )
        let completed = WidgetAgendaBuilder.make(
            occurrences: [done], assignments: [], now: earlier, calendar: fixedCalendar
        )
        XCTAssertNotEqual(a.contentFingerprint, completed.contentFingerprint)
        XCTAssertNotEqual(a.contentFingerprint, WidgetAgendaSnapshot.empty(at: start).contentFingerprint)
    }

    private var fixedCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    func testSignOutClearsTheWidgetSnapshotSoItStopsShowingThePreviousAccount() throws {
        // The widget is a separate process rendering from the App Group; it never observes a
        // sign-out. `AppState.tearDownSession` clears every in-app store, but nothing reached
        // this, so the previous account's assignment titles stayed on the home screen — after
        // an account deletion, permanently.
        try XCTSkipIf(UserDefaults(suiteName: WidgetAgendaStore.appGroup) == nil,
                      "App Group container is unavailable in this environment")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T09:00:00Z"))
        let occurrence = AgendaOccurrenceInput(
            assignmentId: 1, title: "Dentist", occursAt: "2026-08-02T15:00:00Z",
            status: "pending", scheduleKind: "sporadic", hidden: false
        )
        WidgetAgendaStore.save(WidgetAgendaBuilder.make(
            occurrences: [occurrence], assignments: [], now: now, calendar: fixedCalendar
        ))
        XCTAssertEqual(WidgetAgendaStore.load(now: now).today.map(\.title), ["Dentist"],
                       "precondition: the snapshot the widget would draw")

        XCTAssertTrue(WidgetAgendaStore.clear(), "there was a snapshot, so a reload is warranted")
        XCTAssertEqual(WidgetAgendaStore.load(now: now), .empty(at: now),
                       "the signed-out widget must fall back to the empty state")
        XCTAssertFalse(WidgetAgendaStore.clear(),
                       "nothing left to clear — must not spend metered reload budget")
    }

    @MainActor
    func testTheSignOutPathItselfClearsTheWidgetNotJustTheHelper() async throws {
        // The defect was a MISSING CALL SITE, so a test that only exercises `clear()` would
        // stay green if the call were dropped from `tearDownSession` again. This drives the
        // real path. `forgetDeletedAccount()` is the account-deleted sign-out — the case where
        // leftover data would persist forever — and it runs the same `tearDownSession` as
        // `logout()` while touching neither the network nor push registration.
        try XCTSkipIf(UserDefaults(suiteName: WidgetAgendaStore.appGroup) == nil,
                      "App Group container is unavailable in this environment")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T09:00:00Z"))
        let occurrence = AgendaOccurrenceInput(
            assignmentId: 7, title: "Board review", occursAt: "2026-08-02T16:00:00Z",
            status: "pending", scheduleKind: "sporadic", hidden: false
        )
        WidgetAgendaStore.save(WidgetAgendaBuilder.make(
            occurrences: [occurrence], assignments: [], now: now, calendar: fixedCalendar
        ))
        XCTAssertEqual(WidgetAgendaStore.load(now: now).today.map(\.title), ["Board review"],
                       "precondition: the widget is holding this account's agenda")

        await AppState().forgetDeletedAccount()

        XCTAssertEqual(WidgetAgendaStore.load(now: now), .empty(at: now),
                       "signing out must leave the widget nothing to draw")
    }
}
