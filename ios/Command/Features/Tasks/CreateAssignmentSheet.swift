//
//  CreateAssignmentSheet.swift
//  Command
//
//  Create an assignment — one-off or routine — and (optionally) delegate it. The
//  assignee picker finds existing delegatees OR adds a new one inline. A live
//  lead-time warning appears when work is scheduled inside the assignee's window.
//

import SwiftUI

struct CreateAssignmentSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var scheduleKind = "sporadic"
    @State private var hasDate = true
    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var routineDays: Set<String> = []
    @State private var routineFreq = "weekly"   // "daily" | "weekly" | "monthly"
    @State private var priority = 0             // 0 normal · 1 high
    @State private var assignee: Delegatee?
    @State private var showAssigneePicker = false
    @State private var goal: Goal?
    @State private var showGoalPicker = false
    /// nil = inherit the assignee's notice window (or fire at the scheduled time when unassigned).
    @State private var leadMinutes: Int?
    @State private var saving = false
    @State private var errorMessage: String?

    /// States when the reminder actually lands — the same wording (and the same helper) the detail
    /// page uses, so the promise made at creation matches what you see afterwards.
    private var reminderFooter: String {
        PlannerFormat.reminderSummary(
            scheduleKind: scheduleKind,
            scheduledStart: scheduledStartISO,
            status: "todo",
            effectiveLead: leadMinutes ?? assignee?.leadTimeMinutes ?? 0,
            sourceName: leadMinutes == nil ? assignee?.name : nil)
    }

    private var scheduledStartISO: String? {
        (scheduleKind == "routine" || hasDate) ? Self.iso.string(from: date) : nil
    }
    private var rrule: String? {
        guard scheduleKind == "routine" else { return nil }
        if routineFreq == "daily" { return "FREQ=DAILY" }
        if routineFreq == "monthly" { return "FREQ=MONTHLY" }
        let days = Self.orderedDays(routineDays)
        return days.isEmpty ? "FREQ=WEEKLY" : "FREQ=WEEKLY;BYDAY=" + days.joined(separator: ",")
    }
    private var liveWarning: String? {
        guard let a = assignee else { return nil }
        return PlannerFormat.leadWarning(scheduledStart: scheduledStartISO, leadMinutes: a.leadTimeMinutes, name: a.name)
    }

    private func setTimeOfDay(_ hour: Int, _ minute: Int) {
        if let d = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date) {
            date = d
        }
    }

    /// Tappable time presets. The default time-of-day wheel isn't reachable by VoiceOver or UI
    /// automation and is fiddly to land on an exact minute; these plain buttons set common exact
    /// times (medication, standups) in one tap while the picker above still allows any other time.
    @ViewBuilder private var timePresets: some View {
        let presets: [(String, Int, Int)] = [
            ("6:00 AM", 6, 0), ("7:00 AM", 7, 0), ("8:00 AM", 8, 0), ("9:00 AM", 9, 0),
            ("10:00 AM", 10, 0), ("11:00 AM", 11, 0), ("12:00 PM", 12, 0), ("1:00 PM", 13, 0),
            ("2:00 PM", 14, 0), ("3:00 PM", 15, 0), ("4:00 PM", 16, 0), ("5:00 PM", 17, 0),
            ("6:00 PM", 18, 0), ("7:00 PM", 19, 0), ("8:00 PM", 20, 0), ("9:00 PM", 21, 0),
        ]
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick times").font(Typeface.body(13)).foregroundStyle(Palette.inkSecondary)
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(presets, id: \.0) { p in
                    Button { setTimeOfDay(p.1, p.2) } label: {
                        Text(p.0)
                            .font(Typeface.body(14))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Palette.ink.opacity(0.06))
                            .foregroundStyle(Palette.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Set time \(p.0)")
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // A failed create keeps the sheet open (nothing was created, so a retry is safe);
                // say why here — the Tasks list's banner is hidden behind the sheet.
                if let errorMessage {
                    Section { ErrorBanner(message: errorMessage, retry: nil) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    TextField("What needs doing?", text: $title)
                    TextField("Details (optional)", text: $details, axis: .vertical).lineLimit(1...3)
                }

                Section {
                    Picker("Kind", selection: $scheduleKind) {
                        Text("One-off").tag("sporadic")
                        Text("Routine").tag("routine")
                    }
                    .pickerStyle(.segmented)

                    if scheduleKind == "sporadic" {
                        Toggle("Give it a date", isOn: $hasDate)
                        if hasDate {
                            DatePicker("Date", selection: $date)
                            timePresets
                        }
                    } else {
                        DatePicker("Starts", selection: $date)
                        timePresets
                        Picker("Repeats", selection: $routineFreq) {
                            Text("Daily").tag("daily")
                            Text("Weekly").tag("weekly")
                            Text("Monthly").tag("monthly")
                        }
                        .pickerStyle(.segmented)
                        if routineFreq == "weekly" {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("On these days").font(Typeface.body(13)).foregroundStyle(Palette.inkSecondary)
                                WeekdayPicker(selected: $routineDays)
                            }
                        }
                    }
                } header: {
                    Text("When")
                        .accessibilityAddTraits(.isHeader)
                }

                Section {
                    Picker("Priority", selection: $priority) {
                        Text("Normal").tag(0)
                        Text("High").tag(1)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Priority")
                        .accessibilityAddTraits(.isHeader)
                }

                Section {
                    Button { showGoalPicker = true } label: {
                        HStack {
                            Text(goal?.title ?? "Not linked to a goal")
                                .foregroundStyle(goal == nil ? Palette.inkSecondary : Palette.ink)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Advances goal, \(goal?.title ?? "none")")
                } header: {
                    Text("Advances goal")
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    if goal == nil {
                        Text("Link this to a goal so the goal shows the work moving it forward.")
                    }
                }

                Section {
                    Button { showAssigneePicker = true } label: {
                        HStack {
                            Text(assignee?.name ?? "Choose someone (optional)")
                                .foregroundStyle(assignee == nil ? Palette.inkSecondary : Palette.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                                .accessibilityHidden(true)
                        }
                    }
                    if let warning = liveWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(Typeface.body(13))
                            .foregroundStyle(Palette.danger)
                    }
                } header: {
                    Text("Assign to")
                        .accessibilityAddTraits(.isHeader)
                }

                Section {
                    Picker("Remind", selection: $leadMinutes) {
                        // nil = inherit the assignee's own notice window (the previous only option).
                        Text(assignee.map { "\($0.name)'s default" } ?? "At the scheduled time")
                            .tag(Int?.none)
                        ForEach(LeadTime.presets, id: \.minutes) { preset in
                            Text(preset.label).tag(Int?.some(preset.minutes))
                        }
                    }
                } header: {
                    Text("Reminder")
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text(reminderFooter)
                }
            }
            .navigationTitle("New assignment")
            .brandedForm()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.fixedSize() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Create", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .fixedSize()
                }
            }
            .sheet(isPresented: $showAssigneePicker) { AssigneePickerSheet(selection: $assignee).macSheet() }
            .sheet(isPresented: $showGoalPicker) { GoalPickerSheet(selection: $goal).macSheet() }
        }
    }

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            var body = AssignmentCreateBody(title: title.trimmingCharacters(in: .whitespaces))
            let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
            body.details = trimmedDetails.isEmpty ? nil : trimmedDetails
            body.scheduleKind = scheduleKind
            body.scheduledStart = scheduledStartISO
            body.rrule = rrule
            body.priority = priority
            body.goalId = goal?.id
            body.leadTimeMinutes = leadMinutes   // nil → server defaults it from the assignee
            body.timezone = TimeZone.current.identifier   // anchor recurrence to local wall-clock (DST-safe)
            errorMessage = nil
            let (created, _) = await app.tasks.createAssignment(body, assigneeSlug: assignee?.slug, client: app.client)
            if created != nil {
                Haptics.success()
                dismiss()
            } else {
                Haptics.warning()
                errorMessage = app.tasks.errorMessage ?? "Couldn't create the assignment. Try again."
            }
        }
    }

    private static func orderedDays(_ set: Set<String>) -> [String] {
        ["MO", "TU", "WE", "TH", "FR", "SA", "SU"].filter { set.contains($0) }
    }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

struct WeekdayPicker: View {
    @Binding var selected: Set<String>
    // The visible glyph is a single letter (with duplicate M/T/T and S/S), so VoiceOver
    // gets the full weekday name + on/off state instead of an ambiguous "T".
    private let days: [(code: String, label: String, name: String)] = [
        ("MO", "M", "Monday"), ("TU", "T", "Tuesday"), ("WE", "W", "Wednesday"),
        ("TH", "T", "Thursday"), ("FR", "F", "Friday"), ("SA", "S", "Saturday"), ("SU", "S", "Sunday"),
    ]

    private func toggle(_ code: String) {
        if selected.contains(code) { selected.remove(code) } else { selected.insert(code) }
    }

    var body: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(days, id: \.code) { day in
                let on = selected.contains(day.code)
                Button { toggle(day.code) } label: {
                    Text(day.label)
                        .font(Typeface.body(15, on ? .semibold : .medium))
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 4)
                        .background(on ? Palette.accent : Palette.hairline, in: Circle())
                        .foregroundStyle(on ? .white : Palette.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.name)
                .accessibilityValue(on ? "Selected" : "Not selected")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

struct AssigneePickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Delegatee?
    @State private var query = ""
    @State private var adding = false

    private var matches: [Delegatee] {
        let others = query.isEmpty ? app.people.delegatees
            : app.people.delegatees.filter { $0.name.localizedCaseInsensitiveContains(query) }
        // Offer "Me" (self) as a first-class existing choice at the top — assigning work to
        // yourself shouldn't look like creating a duplicate person.
        guard let me = app.people.selfDelegatee else { return others }
        let q = query.trimmingCharacters(in: .whitespaces)
        let meMatches = q.isEmpty || me.name.localizedCaseInsensitiveContains(q) || "me".hasPrefix(q.lowercased())
        return meMatches ? [me] + others : others
    }
    private var canAddNew: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return false }
        if let me = app.people.selfDelegatee, me.name.caseInsensitiveCompare(q) == .orderedSame { return false }
        return !app.people.delegatees.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            List {
                if canAddNew {
                    Button(action: addNew) {
                        Label("Add \"\(query.trimmingCharacters(in: .whitespaces))\"", systemImage: "plus.circle.fill")
                            .foregroundStyle(Palette.accent)
                    }
                    .disabled(adding)
                }
                ForEach(matches) { delegatee in
                    Button {
                        selection = delegatee
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: delegatee.kind == "ai_model" ? "cpu" : "person.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(delegatee.kind == "ai_model" ? Palette.accent : Palette.sage)
                            Text(delegatee.name).foregroundStyle(Palette.ink)
                            if delegatee.leadTimeMinutes > 0 {
                                Text("· \(LeadTime.label(delegatee.leadTimeMinutes))")
                                    .font(.caption).foregroundStyle(Palette.inkSecondary)
                            }
                            Spacer()
                            if selection?.id == delegatee.id {
                                Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                            }
                        }
                    }
                }
                if selection != nil {
                    Button("Clear assignee", role: .destructive) { selection = nil; dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Find or add a person")
            .navigationTitle("Assign to")
            .brandedForm()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fixedSize() } }
            .task { if app.people.delegatees.isEmpty { await app.people.load(client: app.client) } }
        }
    }

    private func addNew() {
        let name = query.trimmingCharacters(in: .whitespaces)
        Task {
            adding = true
            defer { adding = false }
            if let created = await app.people.upsert(
                name: name, slug: nil, kind: "human", leadTimeMinutes: 0, metadata: [:], active: true, client: app.client) {
                selection = created
                dismiss()
            }
        }
    }
}
