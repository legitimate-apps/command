//
//  PlanIntents.swift
//  Command
//
//  Turning capture into a plan: create a delegated assignment, or open a goal. These
//  write straight through `core/` via REST, mirroring the app's own capture→plan→delegate
//  flow (create, then optionally assign so the server applies the delegatee's lead time
//  and returns the human "give them more notice" warning).
//

import AppIntents
import Foundation

/// Create an assignment and (optionally) delegate it to someone on the roster.
struct DelegateAssignmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Assignment"
    static var description = IntentDescription(
        "Create a task in Command and optionally delegate it, schedule it, and file it under a goal.",
        categoryName: "Plan",
        searchKeywords: ["task", "assignment", "delegate", "assign", "todo", "schedule"]
    )
    static var openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var title: String

    @Parameter(title: "Delegate to", description: "A person or AI model on your roster.")
    var assignee: PersonEntity?

    @Parameter(title: "Cadence", default: .sporadic)
    var cadence: AssignmentCadence

    @Parameter(title: "Scheduled for", description: "When it should happen (or the recurrence start).")
    var when: Date?

    @Parameter(title: "Goal", description: "An optional goal to file this under.")
    var goal: GoalEntity?

    @Parameter(title: "Details")
    var details: String?

    @Parameter(title: "Visibility", default: .visible)
    var visibility: CaptureVisibility

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to Command") {
            \.$assignee
            \.$when
            \.$cadence
            \.$goal
            \.$details
            \.$visibility
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<AssignmentEntity> & ProvidesDialog {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommandIntentError.emptyInput("a task title") }

        // A routine assignment needs a start instant (the recurrence anchor). If the user
        // picked "Routine" but gave no date, ask for one rather than failing server-side.
        if cadence == .routine, when == nil {
            throw $when.needsValueError("When should this routine start?")
        }

        let startISO = when.map { IntentFormat.iso.string(from: $0) }
        let cleanDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = AssignmentCreateBody(title: text)
        body.details = (cleanDetails?.isEmpty == false) ? cleanDetails : nil
        body.goalId = goal?.id
        body.scheduleKind = cadence.wireValue
        body.rrule = cadence == .routine ? "FREQ=WEEKLY" : nil   // sensible default; refine in-app
        body.scheduledStart = startISO
        body.timezone = when != nil ? TimeZone.current.identifier : nil
        body.status = when != nil ? "scheduled" : "todo"
        body.hidden = visibility.isHidden

        let (assignment, warning) = try await IntentAPI.run { client -> (Assignment, String?) in
            let created = try await client.createAssignment(body)
            guard let slug = assignee?.slug else { return (created, nil) }
            let result = try await client.assign(assignmentId: created.id, assigneeSlug: slug)
            return (result.assignment, result.leadTimeWarning)
        }
        let entity = AssignmentEntity(assignment)
        await ShortcutNavigation.shared.assignmentCreated(assignment)
        await AssistantSchemaDonations.assignmentCreated(assignment)

        let baseline = assignee.map { "Added and delegated to \($0.name)." } ?? "Added to Command."
        let dialogText = warning.map { "\(baseline) \($0)" } ?? baseline
        let dialog = IntentDialog("\(dialogText)")
        return .result(value: entity, dialog: dialog)
    }
}

/// Open a new goal — the intent behind a cluster of work.
struct CreateGoalIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Goal"
    static var description = IntentDescription(
        "Start a new goal in Command to organize your assignments toward an outcome.",
        categoryName: "Plan",
        searchKeywords: ["goal", "objective", "outcome", "project"]
    )
    static var openAppWhenRun = false

    @Parameter(title: "Goal", requestValueDialog: "What's the goal?")
    var title: String

    @Parameter(title: "Target date")
    var targetDate: Date?

    @Parameter(title: "Description")
    var goalDescription: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create goal \(\.$title) in Command") {
            \.$targetDate
            \.$goalDescription
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<GoalEntity> & ProvidesDialog {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommandIntentError.emptyInput("a goal title") }

        let dateString = targetDate.map { Self.dayFormatter.string(from: $0) }
        let cleanDescription = goalDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = try await IntentAPI.run { client in
            try await client.createGoal(
                title: text,
                description: (cleanDescription?.isEmpty == false) ? cleanDescription : nil,
                targetDate: dateString
            )
        }
        let entity = GoalEntity(goal)
        await ShortcutNavigation.shared.goalCreated(goal)

        let dialog: IntentDialog = targetDate.map {
            IntentDialog("New goal set in Command, targeting \(IntentFormat.dayLabel($0)).")
        } ?? "New goal set in Command."
        return .result(value: entity, dialog: dialog)
    }

    /// Goals carry a plain calendar date (no time-of-day), stored as `yyyy-MM-dd`.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
