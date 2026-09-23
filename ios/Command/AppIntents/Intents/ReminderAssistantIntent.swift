//
//  ReminderAssistantIntent.swift
//  Command
//
//  Compiled only by Swift 6.4 / the iOS 27 SDK. This keeps the shipping iOS 17 target and
//  Xcode 26 build intact while adopting Apple's reminders assistant schema on iOS 27.
//
//  READ THIS BEFORE BELIEVING IT WORKS. The toolchain here is Swift 6.3.3 (Xcode 26.6), so
//  `#if compiler(>=6.4)` excludes this whole file: it is NOT compiled, NOT tested, and ships
//  nothing today. Its first real compile will be on whatever Xcode brings Swift 6.4, and that
//  build is where any drift in the symbols below surfaces. Checked by hand 2026-08-03 —
//  `AssignmentCreateBody` (+ scheduleKind/scheduledStart/timezone/status), `IntentFormat.iso`,
//  `IntentAPI.run`, `ShortcutNavigation.shared.assignmentCreated` and `VoiceInputValidator`
//  all still exist with these shapes.
//
//  It deliberately does NOT call `AssistantSchemaDonations.assignmentCreated`, unlike
//  `PlanIntents` and `TasksStore`. Donation teaches the system about an intent the user
//  performed *through the app*; when the system itself ran the intent, as here, it already
//  knows. Adding the call would be a redundant self-donation, not a missing one.
//

#if compiler(>=6.4)
import AppIntents
import Foundation

@available(iOS 27.0, *)
@AssistantIntent(schema: .reminders.createReminder)
struct CreateCommandReminderAssistantIntent {
    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Due Date")
    var dueDate: Date?

    func perform() async throws -> some IntentResult {
        let cleaned = try VoiceInputValidator.cleaned(title)
        var body = AssignmentCreateBody(title: cleaned)
        body.scheduleKind = "sporadic"
        body.scheduledStart = dueDate.map { IntentFormat.iso.string(from: $0) }
        body.timezone = dueDate == nil ? nil : TimeZone.current.identifier
        body.status = dueDate == nil ? "todo" : "scheduled"
        let assignment = try await IntentAPI.run { try await $0.createAssignment(body) }
        await ShortcutNavigation.shared.assignmentCreated(assignment)
        return .result()
    }
}
#endif
