//
//  DetailColumn.swift
//  Command
//
//  Column 3 of the iPad/Mac split: the detail for the current selection. An
//  entity (assignment/goal/log) renders as the shared EntityDetailView; note and
//  person selections get their own column hosts (added in a later task). Empty
//  selection shows a quiet placeholder.
//
//  EntityDetailView relies on an ancestor NavigationStack for its title/toolbar,
//  so this column provides one. (Views that bring their own stack — like
//  NoteDetailView — are hosted without an extra wrapper to avoid double nav bars.)
//

import SwiftUI

struct DetailColumn: View {
    @Environment(Navigator.self) private var nav

    /// A stable key for the currently-shown detail so `.animation` can cross-fade swaps.
    private var selectionKey: String {
        if let subject = nav.detail { return "detail-\(subject.id)" }
        if let noteId = nav.selectedNoteId { return "note-\(noteId)" }
        if let personId = nav.selectedPersonId { return "person-\(personId)" }
        return "empty-\(nav.destination)"
    }

    var body: some View {
        Group {
            if let subject = nav.detail {
                // `.id(subject.id)` forces a fresh EntityDetailView (and its @State DetailStore)
                // when the selection changes to another entity — without it the column keeps the
                // previous entity's store, so its debounced title/notes saves write to the OLD id.
                // No explicit NavigationStack: the split view's detail column already provides the
                // navigation context, and the nested stack displaced tap/a11y coordinates by a
                // nav-bar height (~73pt) so the assignee/goal picker rows were unhittable on iPad.
                EntityDetailView(subject: subject, inDetailColumn: true)
                    .id(subject.id)
                    .transition(.opacity)
            } else if let noteId = nav.selectedNoteId {
                NoteDetailColumn(noteId: noteId)
                    .transition(.opacity)
            } else if let personId = nav.selectedPersonId {
                PersonDetailColumn(personId: personId)
                    .transition(.opacity)
            } else if nav.destination == .calendar {
                // Calendar has no per-item selection by default → show the selected day's agenda,
                // so the detail column carries real content instead of an empty placeholder.
                NavigationStack { CalendarDayColumn() }
                    .transition(.opacity)
            } else if nav.destination == .assistant {
                // The Assistant's active chat is the detail column (its history list is the content
                // column). AgentChatView brings its own NavigationStack, so host it directly.
                AssistantChatDetail()
                    .transition(.opacity)
            } else {
                DetailEmptyState(destination: nav.destination)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectionKey)
    }
}

/// The active assistant chat, shown in the detail column once the AI gate is satisfied. While the
/// gate isn't ready the disclosure/paywall is shown in the content column, so this stays quiet.
private struct AssistantChatDetail: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.assistantGateResolved == .ready {
            AgentChatView(showsThreadControls: false)
        } else {
            DetailEmptyState(destination: .assistant)
        }
    }
}

/// Hosts the note editor in the detail column. NoteDetailView brings its own
/// NavigationStack, so it's presented directly (no extra wrapper). `.id` forces a
/// fresh editor when the selection changes.
private struct NoteDetailColumn: View {
    @Environment(AppState.self) private var app
    let noteId: Int

    var body: some View {
        if let note = app.notes.notes.first(where: { $0.id == noteId }) {
            NoteDetailView(note: note, inDetailColumn: true).id(noteId)
        } else {
            DetailEmptyState(destination: .notes)
        }
    }
}

/// A calm placeholder shown when nothing is selected in the detail column.
struct DetailEmptyState: View {
    let destination: AppDestination

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: destination.icon)
                .font(.system(size: 40))
                .foregroundStyle(Palette.inkSecondary.opacity(0.4))
                .accessibilityHidden(true)
            Text("Select an item")
                .font(Typeface.display(20))
                .foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
    }
}
