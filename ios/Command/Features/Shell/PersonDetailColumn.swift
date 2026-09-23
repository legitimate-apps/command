//
//  PersonDetailColumn.swift
//  Command
//
//  Column 3 host for a selected delegatee (iPad/Mac). Shows who they are, their
//  default lead time, and the assignments delegated to them — each of which
//  routes back into the detail column. "Edit" opens the existing DelegateeEditor
//  sheet so there's a single source of truth for editing.
//

import SwiftUI

struct PersonDetailColumn: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    let personId: Int
    @State private var editing = false

    private var person: Delegatee? {
        app.people.delegatees.first { $0.id == personId }
    }

    var body: some View {
        NavigationStack {
            if let person {
                List {
                    summary(person)
                    assignments(for: person)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Palette.paper.ignoresSafeArea())
                .navigationTitle(person.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { editing = true }.tint(Palette.accent)
                    }
                }
                .sheet(isPresented: $editing) { DelegateeEditor(target: .edit(person)).macSheet() }
            } else {
                DetailEmptyState(destination: .people)
            }
        }
    }

    private func summary(_ person: Delegatee) -> some View {
        Section {
            LabeledContent("Kind", value: person.kind == "ai_model" ? "AI model" : "Person")
            LabeledContent("Lead time", value: leadText(person.leadTimeMinutes))
            LabeledContent("Status", value: person.active ? "Active" : "Inactive")
        }
        .listRowBackground(Palette.surface)
    }

    @ViewBuilder
    private func assignments(for person: Delegatee) -> some View {
        let theirs = app.tasks.assignments.filter { $0.assigneeId == person.id }
        Section(header: Text("Delegated to \(person.name)").accessibilityAddTraits(.isHeader)) {
            if theirs.isEmpty {
                Text("Nothing delegated yet.")
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                ForEach(theirs) { a in
                    Button { nav.select(.assignment(a)) } label: {
                        HStack {
                            Text(a.title).foregroundStyle(Palette.ink)
                            Spacer(minLength: 8)
                            Text(PlannerFormat.statusLabel(a.status))
                                .font(Typeface.body(12))
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listRowBackground(Palette.surface)
    }

    private func leadText(_ minutes: Int) -> String {
        if minutes <= 0 { return "No notice" }
        if minutes >= 1440 { let d = minutes / 1440; return "\(d) day\(d == 1 ? "" : "s")" }
        if minutes >= 60 { let h = minutes / 60; return "\(h) hour\(h == 1 ? "" : "s")" }
        return "\(minutes) min"
    }
}
