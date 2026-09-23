//
//  AppCommandBus.swift
//  Command
//
//  A tiny one-shot intent channel from the Scene's menu bar / keyboard commands
//  (which live outside the view tree) into the active shell. The shell observes
//  `tick` and maps `last` onto its Navigator + stores. A monotonic `tick` means
//  firing the same intent twice still triggers `onChange`.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppCommandBus {
    enum Intent: Equatable {
        case go(AppDestination)
        case newNote
        case newAssignment
        case newChat
        case voiceConversation
        case capture
        case refresh
        case find
    }

    private(set) var last: Intent?
    private(set) var tick = 0

    func send(_ intent: Intent) {
        last = intent
        tick &+= 1
    }
}
