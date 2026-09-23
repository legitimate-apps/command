//
//  ContentColumn.swift
//  Command
//
//  Column 2 of the iPad/Mac split: the primary list/canvas for the section the
//  sidebar (column 1) has selected. Each section view supplies its own
//  NavigationStack + nav chrome, so it drops straight in.
//

import SwiftUI

struct ContentColumn: View {
    @Environment(Navigator.self) private var nav

    var body: some View {
        switch nav.destination {
        case .calendar:  CalendarView()
        case .notes:     NotesView()
        case .assistant: AssistantColumn()   // regular width: history list here, chat in the detail column
        case .tasks:     TasksView()
        case .people:    PeopleView()
        // Account opens as a sheet (iPad) / Preferences (Mac); keep the content
        // column stable on the last planning section rather than blanking it.
        case .account:   CalendarView()
        }
    }
}
