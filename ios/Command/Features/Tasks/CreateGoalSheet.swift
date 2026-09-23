//
//  CreateGoalSheet.swift
//  Command
//
//  Create a goal with the structure a goal actually needs. This replaces a bare
//  one-field `.alert`: goals could only ever be given a title, so users encoded
//  the real information into the title itself ("Outline - 2027-02-15"). The
//  server, REST layer, and agent tools have always accepted `description` and
//  `target_date` — only this form couldn't set them.
//
//  Status is deliberately not offered here: a goal you are creating is open by
//  definition. It's editable on the detail page via the status chips.
//

import SwiftUI

struct CreateGoalSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var hasTarget = false
    @State private var target = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var saving = false

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to achieve?", text: $title)
                    TextField("Description (optional)", text: $details, axis: .vertical).lineLimit(1...4)
                } footer: {
                    Text("Goals gather the assignments that move them forward.")
                }

                Section {
                    Toggle("Give it a target date", isOn: $hasTarget)
                    if hasTarget {
                        DatePicker("By", selection: $target, displayedComponents: .date)
                        targetPresets
                    }
                } header: {
                    Text("Target")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .navigationTitle("New goal")
            .brandedForm()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.fixedSize() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Create", action: save)
                        .disabled(trimmedTitle.isEmpty || saving)
                        .fixedSize()
                }
            }
        }
    }

    /// The graphical date picker isn't reachable by VoiceOver or UI automation and is fiddly for a
    /// date months out; these plain buttons cover the common horizons in one tap. Same reasoning as
    /// the assignment sheet's time presets.
    @ViewBuilder private var targetPresets: some View {
        let presets: [(String, Int)] = [
            ("1 week", 7), ("2 weeks", 14), ("1 month", 30), ("3 months", 90), ("6 months", 180), ("1 year", 365),
        ]
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick targets").font(Typeface.body(13)).foregroundStyle(Palette.inkSecondary)
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(presets, id: \.0) { preset in
                    Button {
                        target = Calendar.current.date(byAdding: .day, value: preset.1, to: .now) ?? target
                    } label: {
                        Text(preset.0)
                            .font(Typeface.body(14))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Palette.ink.opacity(0.06))
                            .foregroundStyle(Palette.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Target in \(preset.0)")
                }
            }
        }
    }

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            let description = details.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = await app.tasks.createGoal(
                title: trimmedTitle,
                description: description.isEmpty ? nil : description,
                targetDate: hasTarget ? PlannerFormat.dayString(target) : nil,
                client: app.client)
            if ok {
                Haptics.success()
                dismiss()
            }
        }
    }
}
