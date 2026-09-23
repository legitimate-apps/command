//
//  ActivityEditSheet.swift
//  Command
//
//  Edit a logged fact: rename it, re-attribute it to a different actor, re-time it
//  (back-dating allowed; future isn't — facts are past), categorize it for audits,
//  note minutes spent, or delete it.
//

import SwiftUI

struct ActivityEditSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let activity: Activity

    @State private var title: String
    @State private var actorId: Int?
    @State private var category: String
    @State private var occurredAt: Date
    @State private var durationText: String
    @State private var showDelete = false
    @State private var revealedOverride = false   // set true after a gated unredact, to edit in place

    init(activity: Activity) {
        self.activity = activity
        _title = State(initialValue: activity.title)
        _actorId = State(initialValue: activity.actorId)
        _category = State(initialValue: activity.category ?? "")
        _occurredAt = State(initialValue: PlannerFormat.parse(activity.occurredAt) ?? Date())
        _durationText = State(initialValue: activity.durationMinutes.map(String.init) ?? "")
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A hidden log opens censored: shown but covered, so tapping it never exposes the
    /// fact. In "Rub to reveal" the reader can rub to peek; "Reveal all" restores editing.
    private var isHidden: Bool { !revealedOverride && (activity.hidden ?? false) && app.hiddenRevealMode != .revealAll }

    var body: some View {
        // Presented as a sheet, so reveals asked for in here need their own challenge host.
        sheetContent.privacyChallenge()
    }

    private var sheetContent: some View {
        NavigationStack {
            Group {
                if isHidden { hiddenReader } else { editForm }
            }
            .navigationTitle(isHidden ? "Hidden log" : "Edit log")
            .brandedForm()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(isHidden ? "Done" : "Cancel") { dismiss() } }
                if isHidden {
                    ToolbarItem(placement: .confirmationAction) { Button("Reveal") { reveal() } }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
                }
            }
            .confirmationDialog("Delete this log entry?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Haptics.delete()
                    Task { await app.log.delete(id: activity.id, client: app.client); dismiss() }
                }
            }
            .task { if app.log.actors.isEmpty { await app.log.loadActors(client: app.client) } }
        }
    }

    /// A hidden fact, censored under the hidden veil — read-only, rub to peek.
    private var hiddenReader: some View {
        ScrollView {
            Text(activity.title)
                .font(Typeface.body(17, .medium))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .hiddenVeil(hidden: true)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hidden log entry")
    }

    private var editForm: some View {
        Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical).lineLimit(1...4)
                } header: {
                    Text("What got done")
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    Picker("Actor", selection: $actorId) {
                        ForEach(app.log.pickActors) { actor in
                            Text(actor.name).tag(Optional(actor.id))
                        }
                    }
                } header: {
                    Text("Who")
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    DatePicker("Occurred", selection: $occurredAt, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text("When")
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    HStack {
                        Text("Category")
                        Spacer()
                        TextField("e.g. chores", text: $category)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Category")
                    }
                    if !app.log.knownCategories.isEmpty {
                        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(app.log.knownCategories, id: \.self) { c in
                                Button { category = c } label: {
                                    Text(c).font(Typeface.body(12, .medium))
                                        .foregroundStyle(category == c ? .white : Palette.accent)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(category == c ? Palette.accent : Palette.accentSoft, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    HStack {
                        Text("Minutes")
                        Spacer()
                        TextField("optional", text: $durationText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .accessibilityLabel("Minutes")
                    }
                } header: {
                    Text("Details")
                        .accessibilityAddTraits(.isHeader)
                }
                if activity.isCompletion {
                    Label("Logged automatically from marking an assignment done.", systemImage: "info.circle")
                        .font(Typeface.body(13)).foregroundStyle(Palette.inkSecondary)
                }
                Section {
                    Button { hide() } label: {
                        Label("Hide entry", systemImage: "eye.slash")
                    }
                    .tint(Palette.ink)
                    Button(role: .destructive) { showDelete = true } label: {
                        Label("Delete entry", systemImage: "trash")
                    }
                }
            }
    }

    /// Hide the log entry and close — reopening shows it hidden.
    private func hide() {
        Task { await app.log.setHidden(id: activity.id, hidden: true, client: app.client); dismiss() }
    }

    /// Reveal a hidden entry in place after passing the passcode/biometric gate.
    private func reveal() {
        Task {
            if await app.privacy.authenticate(reason: "Reveal this log entry"),
               await app.log.setHidden(id: activity.id, hidden: false, client: app.client) {
                revealedOverride = true
            }
        }
    }

    private func save() {
        let body = ActivityUpdateBody(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            actorId: actorId,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            occurredAt: Self.iso(occurredAt),
            durationMinutes: Int(durationText)   // nil (unchanged) when blank; type 0 to zero it
        )
        Task {
            await app.log.update(id: activity.id, body, client: app.client)
            Haptics.success()
            dismiss()
        }
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
