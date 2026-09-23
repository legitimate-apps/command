//
//  CalendarView.swift
//  Command
//
//  Root tab: one scroll view holding the month grid + the selected day's agenda,
//  with a keyboard-aware capture dock pinned at the bottom. Three capture modes —
//  Note (a thought), Log (a past fact on the selected day), and Schedule (a
//  forward-dated assignment with Date/Time/Repeats that lands on the calendar).
//
//  Keyboard handling is native SwiftUI: the dock lives in `.safeAreaInset(.bottom)`
//  over a `ScrollView`, with `ignoresSafeArea()` confined to the background — so the
//  dock rides above the keyboard the way Apple's docs intend, no UIKit accessory.
//

import SwiftUI

struct CalendarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.navigator) private var nav
    @State private var showSaved = false
    @State private var savedHidden = false
    @State private var showRecording = false
    @State private var captureMode: CaptureMode = .note
    @State private var captureText = ""   // shared across modes — switching mode keeps the text
    @State private var showDatePicker = false
    @State private var showTimePicker = false
    @State private var showLogDatePicker = false
    @State private var showLogTimePicker = false
    // True once the user has hand-picked the Log/Schedule date in the popover. While set,
    // the capture date stops tracking the big calendar (they're intentionally "out of sync")
    // until the entry is sent or the capture mode changes.
    @State private var dateOverridden = false
    @State private var editingActivity: Activity?
    @State private var detail: DetailSubject?
    @State private var showAccount = false
    @State private var showAddPerson = false
    @FocusState private var fieldFocused: Bool

    /// A logged fact tapped in the agenda. iPad/Mac shell (Navigator present) →
    /// the shared detail column; iPhone → the existing detail-page sheet (flag-gated)
    /// or the edit sheet. Hidden items never route to the detail column.
    private func openLog(_ activity: Activity) {
        if !(activity.hidden ?? false), let nav, nav.hasDetailColumn {
            nav.select(.log(activity))
        } else if app.flags.isOn(.detailPages) && !(activity.hidden ?? false) {
            detail = .log(activity)
        } else {
            editingActivity = activity
        }
    }

    /// Open a scheduled occurrence's assignment. Occurrences carry only an assignmentId, so fetch
    /// the full assignment, then route it to the detail column (iPad/Mac split) or a sheet (iPhone).
    private func openOccurrence(_ occ: Occurrence) {
        guard !(occ.hidden ?? false) else { return }
        Task {
            guard let assignment = try? await app.client.assignment(id: occ.assignmentId) else { return }
            if let nav, nav.hasDetailColumn { nav.select(.assignment(assignment)) }
            else { detail = .assignment(assignment) }
        }
    }

    /// The drag payload for an agenda row: enough to re-find the occurrence in the store.
    static func dragPayload(_ occ: Occurrence) -> String {
        "cmd-occ:\(occ.assignmentId)|\(occ.dateKey)"
    }

    /// A payload dropped on a month-grid day: move the occurrence to that day, keeping its
    /// wall-clock time. Returns false (no-op) for foreign payloads or a same-day drop.
    private func handleOccurrenceDrop(_ payloads: [String], on day: Date) -> Bool {
        guard let payload = payloads.first(where: { $0.hasPrefix("cmd-occ:") }) else { return false }
        let parts = payload.dropFirst("cmd-occ:".count).split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let assignmentId = Int(parts[0]) else { return false }
        let key = String(parts[1])
        guard let occ = cal.occurrences.first(where: { $0.assignmentId == assignmentId && $0.dateKey == key }),
              let current = PlannerFormat.parse(occ.occursAt) else { return false }
        let calendar = Calendar.current
        guard !calendar.isDate(current, inSameDayAs: day) else { return false }
        let hm = calendar.dateComponents([.hour, .minute], from: current)
        guard let target = calendar.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0,
                                         second: 0, of: day) else { return false }
        Haptics.light()
        Task { await cal.move(occ, to: target, client: app.client) }
        return true
    }

    /// Context menu (long-press / right-click) for one calendar occurrence. Routine copy names the
    /// occurrence-versus-series scope explicitly so an in-place status change cannot be mistaken
    /// for editing the whole routine.
    @ViewBuilder private func occurrenceMenu(_ occ: Occurrence) -> some View {
        if occ.status != "done" {
            occurrenceStatusButton(occ, status: "done", label: scopedLabel("done", occ),
                                   systemImage: "checkmark.circle")
        }
        if occ.status != "skipped" {
            occurrenceStatusButton(occ, status: "skipped", label: scopedLabel("skipped", occ),
                                   systemImage: "forward.end.circle")
        }
        if occ.status == "done" || occ.status == "skipped" {
            occurrenceStatusButton(occ, status: "todo", label: scopedLabel("pending", occ),
                                   systemImage: "circle")
        }
        if occ.isRescheduled {
            Button {
                Haptics.light()
                Task { await cal.resetOverride(occ, client: app.client) }
            } label: {
                Label("Reset to series time", systemImage: "arrow.uturn.backward")
            }
        }
        if !(occ.hidden ?? false) {
            Button { openOccurrence(occ) } label: {
                Label(occ.scheduleKind == "routine" ? "Open series" : "Open assignment",
                      systemImage: "arrow.up.right.square")
            }
        }
    }

    private func occurrenceStatusButton(_ occ: Occurrence, status: String, label: String,
                                        systemImage: String) -> some View {
        Button {
            Haptics.light()
            Task { await cal.setOccurrenceStatus(status, for: occ, client: app.client) }
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    private func scopedLabel(_ status: String, _ occ: Occurrence) -> String {
        occ.scheduleKind == "routine" ? "Mark this occurrence \(status)" : "Mark \(status)"
    }

    private enum CaptureMode { case note, log, schedule }

    /// The shared month-grid store (on AppState) so the iPad/Mac detail column can render the
    /// selected day's agenda against the same data the month grid + capture dock use.
    private var cal: CalendarStore { app.cal }

    private var scheduledAt: Binding<Date> {
        Binding(get: { app.schedule.scheduledAt }, set: { app.schedule.scheduledAt = $0 })
    }
    private var repeats: Binding<RepeatRule> {
        Binding(get: { app.schedule.repeats }, set: { app.schedule.repeats = $0 })
    }
    private var loggedAt: Binding<Date> {
        Binding(get: { app.log.occurredAt }, set: { app.log.occurredAt = $0 })
    }
    // Date-popover bindings: a hand-pick here flags the override so the date stops
    // tracking the big calendar. (The Time popovers write the plain bindings above,
    // which keep tracking — useDay preserves the time-of-day when the day re-syncs.)
    private var scheduleDate: Binding<Date> {
        Binding(get: { app.schedule.scheduledAt },
                set: { if $0 != app.schedule.scheduledAt { dateOverridden = true }; app.schedule.scheduledAt = $0 })
    }
    private var logDate: Binding<Date> {
        Binding(get: { app.log.occurredAt },
                set: { if $0 != app.log.occurredAt { dateOverridden = true }; app.log.occurredAt = $0 })
    }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    /// The weekday row + day grid — shared by both layouts. The month/year title lives
    /// in the nav bar (principal toolbar item) and the month arrows flank the weekday
    /// row, so the whole calendar sits higher on screen.
    @ViewBuilder private var monthGrid: some View {
        weekdayHeader
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(cal.gridDays, id: \.self) { day in
                DayCell(
                    day: day,
                    inMonth: cal.isInVisibleMonth(day),
                    isToday: cal.isToday(day),
                    isSelected: cal.isSelected(day),
                    count: cal.count(on: day),
                    loggedCount: cal.loggedCount(on: day)
                ) { cal.selectedDay = day }
                    // Drag an agenda row onto a day to move that item there (same wall-clock
                    // time). Routine occurrence → per-occurrence override; sporadic → the
                    // assignment itself moves (spec 2026-07-19-later-bucket, month-drag rev).
                    .dropDestination(for: String.self) { payloads, _ in
                        handleOccurrenceDrop(payloads, on: day)
                    }
            }
        }
    }

    /// Compact (iPhone) stacks the grid above the day's agenda in one scroll view;
    /// regular width (iPad/Mac) puts them side by side. The compact branch is kept
    /// identical to what shipped — including the horizontal-pan-bug workaround.
    @ViewBuilder private var calendarContent: some View {
        if nav?.hasDetailColumn == true {
            // iPad/Mac split shell: this view is the *content* column — show just the month grid
            // (+ the capture dock via safeAreaInset). The selected day's agenda renders in the
            // real detail column (CalendarDayColumn), so the wide canvas isn't wasted on an empty
            // "Select an item" pane and the calendar isn't crammed beside it.
            ScrollView {
                VStack(spacing: 12) {
                    #if targetEnvironment(macCatalyst)
                    // Catalyst merges the split shell's per-column navigation bars into ONE window
                    // toolbar and puts the DETAIL column's title in it, which silently drops this
                    // column's `.principal` month/year item — a Mac user could not tell which month
                    // the grid was showing. Put the title back at the top of the column here.
                    // iPhone/iPad keep the nav-bar title (they render this column's own bar), so
                    // this is deliberately Catalyst-only rather than a shared row.
                    HStack {
                        Text(cal.monthTitle)
                            .font(Typeface.display(20))
                            .foregroundStyle(Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                    }
                    #endif
                    monthGrid
                }
                    .padding(.horizontal, 16).padding(.top, 6)
                    // Fill exactly the content column's width. NOT `containerRelativeFrame(.horizontal)`
                    // here: inside the split-view content column that resolves to the whole WINDOW's
                    // width, so the 7-column month grid was laid out ~window-wide and clipped by the
                    // narrow column — only ~3 of 7 weekday columns showed. `maxWidth: .infinity` sizes
                    // the grid to the column (its flexible columns then fit) and still caps the scroll
                    // to one axis, so the horizontal-pan bug the container frame guarded against can't return.
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await cal.load(client: app.client) }
        } else if hSize == .regular {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(spacing: 12) { monthGrid }
                        .padding(.horizontal, 16).padding(.top, 6)
                }
                .frame(maxWidth: 480)
                Divider().overlay(Palette.hairline)
                ScrollView {
                    agenda.padding(.horizontal, 16).padding(.top, 6)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await cal.load(client: app.client) }
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    monthGrid
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    agenda
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                // Lock the scroll content to the container's width so the calendar can never
                // pan horizontally — a vertical ScrollView otherwise becomes 2-axis the moment
                // any descendant reports a width wider than the viewport (the recurring
                // left/right-pan bug). All real content already fits; this just caps the axis.
                .containerRelativeFrame(.horizontal)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await cal.load(client: app.client) }
        }
    }

    var body: some View {
        NavigationStack {
            calendarContent
            // Background (not content) ignores the safe area, so SwiftUI keeps the
            // scroll content + dock above the keyboard while the paper fills the screen.
            .background(Palette.paper.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { captureDock }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)   // transparent bar; paper shows through
            .toolbar { todayToolbar }
            .overlay(alignment: .top) { if showSaved { savedToast } }
            .onChange(of: captureMode) { _, mode in
                dateOverridden = false   // a mode switch re-syncs the date to the big calendar
                if mode == .schedule {
                    if app.schedule.assigneeId == nil { app.schedule.assigneeId = app.log.me?.id }
                    app.schedule.useDay(cal.selectedDay)
                } else if mode == .log {
                    app.log.useDay(cal.selectedDay)
                }
            }
            .onChange(of: cal.selectedDay) { _, day in
                // The capture date tracks the big calendar — unless the user hand-picked it.
                guard !dateOverridden else { return }
                if captureMode == .schedule { app.schedule.useDay(day) }
                else if captureMode == .log { app.log.useDay(day) }
            }
            // ⌘⇧C / "Quick Capture" from the Mac/iPad menu focuses the jot field. `initial: true` so
            // a cross-section ⌘⇧C (show(.calendar) mounts this view fresh with the flag already set)
            // still consumes it — plain onChange skips the value present at mount.
            .onChange(of: nav?.focusCapture, initial: true) { _, want in
                if want == true { captureMode = .note; fieldFocused = true; nav?.focusCapture = false }
            }
            .sheet(isPresented: $showRecording) { RecordingSheet().macSheet() }
            .sheet(isPresented: $showAccount) { AccountView().macSheet(.page) }
            // Reload after editing a logged fact: the edit sheet saves via app.log + the server,
            // but the agenda reads cal.activities (a separate windowed copy), so without this the
            // calendar keeps showing the pre-edit time/day. (send() already reloads; edit now does too.)
            .sheet(item: $editingActivity, onDismiss: { Task { await cal.load(client: app.client) } }) {
                ActivityEditSheet(activity: $0).macSheet()
            }
            .sheet(item: $detail) { subject in NavigationStack { EntityDetailView(subject: subject) }.macSheet(.page) }
            .sheet(isPresented: $showAddPerson) {
                // Inline-add a delegatee from the capture-dock assignee dropdown, then
                // refresh the roster and select the new person for the current mode.
                DelegateeEditor(target: .new, onSaved: { saved in
                    Task {
                        await app.log.loadActors(client: app.client)
                        if captureMode == .schedule { app.schedule.assigneeId = saved.id }
                        else { app.log.composeActorId = saved.id }
                    }
                })
            }
            .task {
                #if DEBUG
                // In offline UI-preview the calendar occurrences are seeded in AppState; a real
                // load would hit the network, fail, and wipe them — so skip it in preview.
                if UserDefaults.standard.bool(forKey: "COMMAND_UI_PREVIEW") { return }
                #endif
                await cal.load(client: app.client)
                if app.people.delegatees.isEmpty { await app.people.load(client: app.client) }
                if app.log.actors.isEmpty { await app.log.loadActors(client: app.client) }
            }
        }
    }

    // The "Today" jump chip. On iOS 26 the system wraps toolbar items in a shared
    // Liquid Glass capsule; our amber chip already carries its own background, so a
    // double-stacked pill appears. Hiding the shared glass keeps just the amber chip,
    // consistent with the app's custom dark+amber language. No-op on iOS < 26.
    @ToolbarContentBuilder
    private var todayToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showAccount = true } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 18)).foregroundStyle(Palette.accent)
            }
            .accessibilityLabel("Account")
        }
        // The month/year title sits in the bar itself (between Account and Today) so the
        // grid below starts one row higher.
        ToolbarItem(placement: .principal) {
            Text(cal.monthTitle)
                .font(Typeface.display(20))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
        }
        ToolbarItem(placement: .topBarTrailing) { todayButton }
    }

    private var todayButton: some View {
        // A standard iOS 26 trailing nav-bar button: amber label inside the system's
        // Liquid Glass capsule (matches the account button), tucked to the trailing
        // margin. We let the platform supply the capsule rather than stacking our own
        // amber pill inside it (which both double-stacked and floated off the edge).
        Button { Task { await cal.goToToday(client: app.client) } } label: {
            Text("Today")
                .font(Typeface.body(13, .semibold))
                .foregroundStyle(Palette.accent)
        }
    }

    /// The weekday letters, flanked by the month arrows. The 7 letters keep exactly the
    /// grid's column layout (they must align with the day cells below), so the chevrons
    /// are edge overlays nudged into the content margins rather than HStack members —
    /// inserting them inline would shift every column off its letters.
    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .leading) { monthStepButton(by: -1, icon: "chevron.left", label: "Previous month").offset(x: -12) }
        .overlay(alignment: .trailing) { monthStepButton(by: 1, icon: "chevron.right", label: "Next month").offset(x: 12) }
    }

    private func monthStepButton(by months: Int, icon: String, label: String) -> some View {
        Button { Task { await cal.step(months: months, client: app.client) } } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 32, height: 32)   // comfortable tap target without inflating the row
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityLabel(label)
    }

    // The selected day's agenda — flows inside the outer ScrollView (no inner scroll),
    // so scrolling the page moves the calendar up to reveal more of a busy day.
    private var agenda: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedDayTitle.uppercased())
                .font(Typeface.body(12, .semibold))
                .tracking(1.2)
                .foregroundStyle(Palette.accent)
                .accessibilityAddTraits(.isHeader)
            if let err = cal.errorMessage {
                // A refresh failed but we kept the last-known events (B2) — say so instead of
                // silently showing possibly-stale data or a blank grid.
                Label(err, systemImage: "wifi.exclamationmark")
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.inkSecondary)
            }
            let occs = cal.occurrences(on: cal.selectedDay)
            let logs = cal.activities(on: cal.selectedDay)
            if occs.isEmpty && logs.isEmpty {
                Text("Nothing scheduled or logged.")
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.top, 4)
            } else {
                ForEach(occs) { occ in
                    OccurrenceRow(occurrence: occ, assigneeName: assigneeName(occ.assigneeId))
                        .tappableRow { openOccurrence(occ) }
                        .hoverEffect()
                        .contextMenu { occurrenceMenu(occ) }
                        .draggable(Self.dragPayload(occ))
                }
                if !logs.isEmpty {
                    Text("LOGGED")
                        .font(Typeface.body(11, .semibold)).tracking(1.1)
                        .foregroundStyle(Palette.sage)
                        .padding(.top, occs.isEmpty ? 0 : 6)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(logs) { activity in
                        ActivityRow(activity: activity, style: .compact)
                            .tappableRow { openLog(activity) }
                            .hoverEffect()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.bottom, 8)
    }

    // MARK: - Capture dock

    private var captureDock: some View {
        VStack(spacing: 8) {
            if let err = activeError {
                Text(err).font(Typeface.body(12)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Palette.danger.opacity(0.9), in: Capsule())
            }
            HStack(spacing: 4) {
                modeMenu
                inputField
                sendButton
                micButton
            }
            .padding(4)
            .cardSurface(cornerRadius: 26)
            if captureMode == .schedule {
                scheduleSelectors
            } else if captureMode == .log {
                logSelectors
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {
            Palette.paper
                .overlay(Rectangle().fill(Palette.hairline).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        }
        // Speak a capture failure — the red error capsule appears/vanishes silently otherwise.
        .onChange(of: activeError) { _, err in
            if let err { AccessibilityNotification.Announcement(err).post() }
        }
    }

    private var inputField: some View {
        TextField(composePlaceholder, text: $captureText, axis: .vertical)
            .focused($fieldFocused)
            .font(Typeface.body(16))
            .foregroundStyle(Palette.ink)
            .tint(Palette.accent)
            .lineLimit(1...5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var modeMenu: some View {
        Menu {
            modeButton("Note", mode: .note, icon: "square.and.pencil")
            modeButton("Log", mode: .log, icon: "checkmark.circle")
            modeButton("Schedule", mode: .schedule, icon: "calendar")
        } label: {
            Image(systemName: captureModeIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .background(Palette.accentSoft, in: Circle())
        }
        .accessibilityLabel("Capture mode, \(captureModeLabel)")
        .hoverEffect()
    }

    private var sendButton: some View {
        Button { send() } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(sendEnabled ? Palette.accent : Palette.accent.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .disabled(!sendEnabled)
        .accessibilityLabel(captureMode == .schedule ? "Add to queue" : "Send")
        // Long-press the send button for the alternate "Send hidden" send — the item is
        // created under a hidden veil. Only one option for now, by design.
        .contextMenu {
            Button { send(hidden: true) } label: {
                Label("Send hidden", systemImage: "eye.slash")
            }
            .disabled(!sendEnabled)
        }
    }

    private var micButton: some View {
        Button { showRecording = true } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 44, height: 44)
                .cardSurface(cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityLabel("Dictate")
    }

    // Date · Time · Repeats — consistent amber chips matching the assignee chip.
    // Date/Time open compact picker popovers; Repeats is a menu.
    private var scheduleSelectors: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            Button { showDatePicker = true } label: { selectorChip(icon: "calendar", text: dateLabel) }
                .buttonStyle(.plain)
                .popover(isPresented: $showDatePicker) {
                    DatePicker("", selection: scheduleDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().tint(Palette.accent)
                        .frame(width: 320).padding(10)
                        .presentationCompactAdaptation(.popover)
                }
            Button { showTimePicker = true } label: { selectorChip(icon: "clock", text: timeLabel) }
                .buttonStyle(.plain)
                .popover(isPresented: $showTimePicker) {
                    DatePicker("", selection: scheduledAt, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().tint(Palette.accent)
                        .frame(width: 240).padding(8)
                        .presentationCompactAdaptation(.popover)
                }
            Menu {
                Picker("Repeats", selection: repeats) {
                    ForEach(RepeatRule.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                selectorChip(icon: "repeat", text: app.schedule.repeats.label, chevron: true)
            }
            assigneeChip
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // Date · Time for a Log — the same amber chips as Schedule, minus Repeats (a fact
    // doesn't recur). The date mirrors the selected big-calendar day until hand-picked.
    private var logSelectors: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            Button { showLogDatePicker = true } label: { selectorChip(icon: "calendar", text: logDateLabel) }
                .buttonStyle(.plain)
                .popover(isPresented: $showLogDatePicker) {
                    DatePicker("", selection: logDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().tint(Palette.accent)
                        .frame(width: 320).padding(10)
                        .presentationCompactAdaptation(.popover)
                }
            Button { showLogTimePicker = true } label: { selectorChip(icon: "clock", text: logTimeLabel) }
                .buttonStyle(.plain)
                .popover(isPresented: $showLogTimePicker) {
                    DatePicker("", selection: loggedAt, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().tint(Palette.accent)
                        .frame(width: 240).padding(8)
                        .presentationCompactAdaptation(.popover)
                }
            assigneeChip
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The shared chip used by Date, Time, Repeats, and the assignee picker.
    private func selectorChip(icon: String, text: String, chevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
            Text(text).font(Typeface.body(13, .medium)).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).accessibilityHidden(true) }
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 11)
        .frame(minHeight: 44)
        .background(Palette.accentSoft, in: Capsule())
        .hoverEffect()   // Mac/iPad pointer feedback on Date/Time/Repeats/assignee chips
    }

    private var dateLabel: String { Self.dateFmt.string(from: app.schedule.scheduledAt) }
    private var timeLabel: String { Self.timeFmt.string(from: app.schedule.scheduledAt) }
    private var logDateLabel: String { Self.dateFmt.string(from: app.log.occurredAt) }
    private var logTimeLabel: String { Self.timeFmt.string(from: app.log.occurredAt) }
    private static let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()
    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()

    private var assigneeChip: some View {
        Menu {
            Picker("Assignee", selection: assigneeBinding) {
                ForEach(app.log.pickActors) { actor in
                    Text(actor.name).tag(actor.id as Int?)
                }
            }
            Divider()
            Button { showAddPerson = true } label: {
                Label("Add Person…", systemImage: "person.badge.plus")
            }
        } label: {
            selectorChip(icon: "person.fill", text: assigneeChipName, chevron: true)
        }
    }

    /// Reads/writes the right store for the active mode; nil resolves to "Me" so the
    /// menu shows the correct checkmark by default.
    private var assigneeBinding: Binding<Int?> {
        Binding(
            get: {
                let raw = captureMode == .schedule ? app.schedule.assigneeId : app.log.composeActorId
                return raw ?? app.log.me?.id
            },
            set: { newValue in
                if captureMode == .schedule { app.schedule.assigneeId = newValue }
                else { app.log.composeActorId = newValue }
            }
        )
    }

    private var assigneeChipName: String {
        if captureMode == .log { return app.log.composeActorName }
        if let id = app.schedule.assigneeId, let a = app.log.actors.first(where: { $0.id == id }) {
            return a.name
        }
        return app.log.me?.name ?? "Me"
    }

    private func modeButton(_ title: String, mode: CaptureMode, icon: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { captureMode = mode }
        } label: {
            Label(title, systemImage: captureMode == mode ? "checkmark" : icon)
        }
    }

    private var captureModeIcon: String {
        switch captureMode {
        case .note: return "square.and.pencil"
        case .log: return "checkmark.circle"
        case .schedule: return "calendar"
        }
    }

    private var captureModeLabel: String {
        switch captureMode {
        case .note: return "Note"
        case .log: return "Log"
        case .schedule: return "Schedule"
        }
    }

    private var activeError: String? {
        switch captureMode {
        case .note: return app.notes.errorMessage
        case .log: return app.log.errorMessage
        case .schedule: return app.schedule.errorMessage
        }
    }

    private var savedToast: some View {
        Label(savedHidden ? "Hidden" : savedLabel,
              systemImage: savedHidden ? "eye.slash.fill" : "checkmark.circle.fill")
            .font(Typeface.body(13, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(savedHidden ? Palette.ink : Palette.sage, in: Capsule())
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var savedLabel: String {
        switch captureMode {
        case .note: return "Saved"
        case .log: return "Logged"
        case .schedule: return "Queued"
        }
    }

    private var composePlaceholder: String {
        switch captureMode {
        case .note: return "Jot a thought…"
        case .log: return "Log what got done…"
        case .schedule: return "Schedule something…"
        }
    }

    private var sendEnabled: Bool {
        let empty = captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let saving: Bool
        switch captureMode {
        case .note: saving = app.notes.isSaving
        case .log: saving = app.log.isSaving
        case .schedule: saving = app.schedule.isSaving
        }
        return !empty && !saving
    }

    private func send(hidden: Bool = false) {
        Task {
            // Push the shared entry text into the active store, then save.
            let ok: Bool
            switch captureMode {
            case .note:
                app.notes.draft = captureText
                ok = await app.notes.saveDraft(hidden: hidden, client: app.client)
            case .log:
                app.log.draft = captureText
                ok = await app.log.logDraft(hidden: hidden, client: app.client)
            case .schedule:
                app.schedule.draft = captureText
                ok = await app.schedule.addToQueue(hidden: hidden, client: app.client)
            }
            guard ok else { return }
            Haptics.success()
            captureText = ""
            // Sending ends the "out of sync" override: the date snaps back to the big calendar.
            dateOverridden = false
            if captureMode == .schedule { app.schedule.useDay(cal.selectedDay) }
            else if captureMode == .log { app.log.useDay(cal.selectedDay) }
            if captureMode != .note { await cal.load(client: app.client) }
            flashSaved(hidden: hidden)
        }
    }

    private func flashSaved(hidden: Bool = false) {
        savedHidden = hidden
        withAnimation(.spring(duration: 0.3)) { showSaved = true }
        // The toast is a transient visual confirmation; speak it so VoiceOver users also
        // learn the capture succeeded (it otherwise appears and vanishes silently).
        AccessibilityNotification.Announcement(hidden ? "Hidden" : savedLabel).post()
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.25)) { showSaved = false }
        }
    }

    private func assigneeName(_ id: Int?) -> String? {
        guard let id else { return nil }
        return app.people.delegatees.first { $0.id == id }?.name
    }

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var selectedDayTitle: String {
        if Calendar.current.isDateInToday(cal.selectedDay) { return "Today" }
        return Self.dayTitle.string(from: cal.selectedDay)
    }
    private static let dayTitle: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()
}

struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let count: Int
    var loggedCount: Int = 0
    let onTap: () -> Void

    private var number: String { "\(Calendar.current.component(.day, from: day))" }
    private var textColor: Color {
        if isSelected { return .white }
        return inMonth ? Palette.ink : Palette.inkSecondary.opacity(0.4)
    }
    // Amber dots = scheduled occurrences; one sage dot trails if anything was logged.
    private var amberDots: Int { min(count, loggedCount > 0 ? 2 : 3) }

    private static let a11yDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f
    }()
    // VoiceOver reads the whole cell as one button with the date + what's on it, instead
    // of a bare number the user can't tell is tappable or has events.
    private var accessibilityText: String {
        var parts = [DayCell.a11yDate.string(from: day)]
        if isToday { parts.append("Today") }
        if count > 0 { parts.append("\(count) scheduled") }
        if loggedCount > 0 { parts.append("\(loggedCount) logged") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(number)
                .font(.system(size: 15, weight: isToday ? .bold : .regular))
                .foregroundStyle(textColor)
                .frame(width: 32, height: 32)
                .background {
                    if isSelected {
                        Circle().fill(Palette.accent)
                    } else if isToday {
                        Circle().strokeBorder(Palette.accent, lineWidth: 1.5)
                    }
                }
            HStack(spacing: 3) {
                ForEach(0..<amberDots, id: \.self) { _ in
                    Circle().fill(Palette.accent).frame(width: 5, height: 5)
                }
                if loggedCount > 0 {
                    Circle().fill(Palette.sage).frame(width: 5, height: 5)
                }
            }
            .frame(height: 6)
            .opacity(count > 0 || loggedCount > 0 ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onTap)
    }
}

struct OccurrenceRow: View {
    let occurrence: Occurrence
    let assigneeName: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(timeString)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(isDone ? Palette.sage : Palette.inkSecondary)
                .lineLimit(1)
                // 64pt was a hair too narrow for 8 monospaced glyphs ("10:00 AM"), so the time
                // wrapped to two lines in the agenda. Give it enough width to stay on one line.
                .frame(width: 74, alignment: .leading)
            Circle().fill(PlannerFormat.statusColor(occurrence.status)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(occurrence.title)
                        .font(Typeface.body(15, .medium))
                        .foregroundStyle(isDone ? Palette.sage : Palette.ink)
                        .strikethrough(isDone, color: Palette.sage)
                        .lineLimit(1)
                    if let span = occurrence.spanLabel {
                        Text(span)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Palette.accentSoft, in: Capsule())
                    }
                }
                if let name = assigneeName {
                    Text(name).font(Typeface.body(12)).foregroundStyle(Palette.inkSecondary)
                }
                if isSkipped {
                    Label("Skipped", systemImage: "forward.end.fill")
                        .font(Typeface.body(11, .semibold))
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .hiddenVeil(hidden: occurrence.hidden ?? false)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
        .opacity(isSkipped ? 0.55 : 1)
        .accessibilityValue(isSkipped ? "Skipped" : isDone ? "Done" : occurrence.status.capitalized)
    }

    private var isDone: Bool { occurrence.status == "done" }
    private var isSkipped: Bool { occurrence.status == "skipped" }

    private var timeString: String {
        guard let date = PlannerFormat.parse(occurrence.occursAt) else { return "" }
        return Self.time.string(from: date)
    }
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}
