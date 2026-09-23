//
//  GoalPickerSheet.swift
//  Command
//
//  Choose the goal an assignment advances — or unlink it. Mirrors AssigneePickerSheet:
//  search, tap to pick, an explicit clear.
//
//  Goals and the work that moves them forward were disconnected: the schema has had
//  `assignments.goal_id` since day one and the detail page would *show* a linked goal,
//  but nothing in the app could ever set it, so every assignment created on-device was
//  goal_id: null and goals stayed decorative.
//

import SwiftUI

struct GoalPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Goal?
    @State private var query = ""

    /// Done and dropped goals are filtered out — you don't schedule work toward a finished
    /// goal — unless one is already linked (never hide the current value from its own picker).
    private var matches: [Goal] {
        app.tasks.goals.filter { goal in
            let live = goal.status != "done" && goal.status != "dropped"
            guard live || goal.id == selection?.id else { return false }
            return query.isEmpty || goal.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if matches.isEmpty {
                    Text(app.tasks.goals.isEmpty
                         ? "No goals yet. Create one from Tasks › Goals, then link work to it."
                         : "No goals match \"\(query)\".")
                        .font(Typeface.body(14))
                        .foregroundStyle(Palette.inkSecondary)
                }
                ForEach(matches) { goal in
                    Button {
                        selection = goal
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "target").font(.system(size: 13)).foregroundStyle(Palette.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(goal.title).foregroundStyle(Palette.ink)
                                if let target = goal.targetDate {
                                    Text("by \(PlannerFormat.dayLabel(target))")
                                        .font(.caption).foregroundStyle(Palette.inkSecondary)
                                }
                            }
                            Spacer()
                            if selection?.id == goal.id {
                                Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityLabel("Goal \(goal.title)")
                    .accessibilityAddTraits(selection?.id == goal.id ? [.isButton, .isSelected] : .isButton)
                }
                if selection != nil {
                    Button("Clear goal", role: .destructive) { selection = nil; dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Find a goal")
            .navigationTitle("Advances goal")
            .brandedForm()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fixedSize() } }
            .task { if app.tasks.goals.isEmpty { await app.tasks.load(client: app.client) } }
        }
    }
}
