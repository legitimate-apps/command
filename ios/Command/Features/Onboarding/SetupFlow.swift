//
//  SetupFlow.swift
//  Command
//
//  The decisions behind guided setup, kept pure so they are unit-tested rather than implied by
//  view code: which server label to show, whether "Create account" is offered, whether the
//  "Add your AI key" step appears, which post-sign-in step comes next, and what the "You're set"
//  tutorial cards say and do. Spec: docs/specs/2026-09-23-command-cloud.md ("App").
//

import Foundation

/// What comes after a sign-in during setup. `nil` in AppState means "show the app".
enum SetupStage: String, Equatable, Sendable {
    /// Self-hosted owner, the server can take a key from the app, and none is configured.
    case aiKey
    /// The short "You're set" tutorial, shown once.
    case ready
}

/// One "You're set" card: one idea, one action that lands in the real app.
struct TutorialCard: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Focus the Calendar's capture bar (type, or tap the mic to speak).
        case capture
        /// Open a new assistant chat.
        case newChat
        /// Open the Assistant tab (shows the Pro paywall where the assistant is gated).
        case assistant
        /// Open Account (MCP access token, server settings).
        case account

        /// The shell intent this action routes through — the same channel as ⌘-shortcuts.
        var intent: AppCommandBus.Intent {
            switch self {
            case .capture:   return .capture
            case .newChat:   return .newChat
            case .assistant: return .go(.assistant)
            case .account:   return .go(.account)
            }
        }
    }

    let id: String
    let systemImage: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: Action
}

enum SetupFlow {
    static let tutorialSeenKey = "command.setup.tutorialSeen"
    /// Per-server: skipping the key on one server must not hide the step on another.
    static func aiKeySkippedKey(for serverURL: String) -> String {
        "command.setup.aiKeySkipped." + serverURL
    }

    /// True for Command Cloud. The server's own word wins; the address is the fallback for an
    /// older response (or no response) so the label is right even before info loads.
    static func isCloud(info: ServerInfo?, serverURL: String) -> Bool {
        if let kind = info?.kind { return kind == "cloud" }
        return sameServer(serverURL, ServerSetupGuide.cloudURL.absoluteString)
    }

    /// "Command Cloud", or the host of your own server ("Your server" when unparseable).
    static func serverLabel(info: ServerInfo?, serverURL: String) -> String {
        if isCloud(info: info, serverURL: serverURL) { return "Command Cloud" }
        if let host = URL(string: serverURL)?.host, !host.isEmpty {
            let port = URL(string: serverURL)?.port.map { ":\($0)" } ?? ""
            return host + port
        }
        return "Your server"
    }

    /// The one-word kind shown in Account → Server.
    static func serverKindLabel(info: ServerInfo?, serverURL: String) -> String {
        isCloud(info: info, serverURL: serverURL) ? "Command Cloud" : "Self-hosted"
    }

    /// Offer "Create account"? Unknown (older server) ⇒ yes, exactly as before.
    static func canCreateAccount(info: ServerInfo?) -> Bool { info?.allowsRegistration ?? true }

    /// Open the account screen on "Create account" rather than "Sign in"? Only when sign-up is
    /// actually open AND it is almost certainly what the person wants: a self-hosted server with
    /// no owner yet (the first account becomes the owner), or a server they just chose during
    /// setup. Someone returning to a known server gets "Sign in".
    static func startsOnCreateAccount(info: ServerInfo?, justChoseServer: Bool) -> Bool {
        guard let info, info.allowsRegistration else { return false }
        return info.isSelfHosted || justChoseServer
    }

    /// Show "Add your AI key"? Only on a self-hosted server that can take one from the app and
    /// has none — and not after the person skipped it on this server. Ownership is decided by
    /// the server: a non-owner's attempt answers `not_owner` and the step simply goes away.
    static func offersAIKey(info: ServerInfo?, skipped: Bool) -> Bool {
        guard let info, !skipped else { return false }
        return info.isSelfHosted && info.aiKeySettable && !info.aiConfigured
    }

    /// The first post-sign-in step, or nil to go straight to the app.
    static func firstStage(info: ServerInfo?, aiKeySkipped: Bool, tutorialSeen: Bool) -> SetupStage? {
        if offersAIKey(info: info, skipped: aiKeySkipped) { return .aiKey }
        return tutorialSeen ? nil : .ready
    }

    /// The step after `stage` finishes (saved or skipped).
    static func stage(after stage: SetupStage, tutorialSeen: Bool) -> SetupStage? {
        switch stage {
        case .aiKey: return tutorialSeen ? nil : .ready
        case .ready: return nil
        }
    }

    /// The "You're set" cards — three at most. The assistant card tells the truth about THIS
    /// server: on Cloud without Pro it says Pro unlocks it (no hard sell); on a self-hosted
    /// server with no key it says where to add one; otherwise it opens a chat.
    static func tutorialCards(isCloud: Bool, assistantUnlocked: Bool, aiConfigured: Bool) -> [TutorialCard] {
        let capture = TutorialCard(
            id: "capture", systemImage: "square.and.pencil",
            title: "Capture a note",
            detail: "Type it, or tap the mic and say it. It lands on today.",
            actionTitle: "Capture something", action: .capture)

        let assistant: TutorialCard
        if isCloud && !assistantUnlocked {
            assistant = TutorialCard(
                id: "assistant", systemImage: "sparkles",
                title: "Ask the assistant",
                detail: "It turns notes into goals and tasks. On Command Cloud it's part of Command Pro.",
                actionTitle: "See the assistant", action: .assistant)
        } else if !isCloud && !aiConfigured {
            assistant = TutorialCard(
                id: "assistant", systemImage: "sparkles",
                title: "Ask the assistant",
                detail: "It needs an AI key on your server. Add one any time in Account → Server.",
                actionTitle: "Open Account", action: .account)
        } else {
            assistant = TutorialCard(
                id: "assistant", systemImage: "sparkles",
                title: "Ask the assistant",
                detail: "Ask it to plan your week from your notes.",
                actionTitle: "Start a chat", action: .newChat)
        }

        let mcp = TutorialCard(
            id: "mcp", systemImage: "terminal",
            title: "Connect Claude Code",
            detail: "Your access token is in Account. Add it to Claude Code and it can plan from your notes.",
            actionTitle: "Find my token", action: .account)

        return [capture, assistant, mcp]
    }

    /// Which agent brief fits where the person is: the server they're on, else what they picked.
    static func handoffPath(info: ServerInfo?, serverURL: String,
                            chosen: ServerHostingOption?) -> AgentHandoff.Path {
        if !serverURL.isEmpty, isCloud(info: info, serverURL: serverURL) { return .cloud }
        switch chosen {
        case .railway:    return .railway
        case .selfHosted: return .docker
        case .existing:   return .existing
        case nil:         return serverURL.isEmpty ? .undecided : .existing
        }
    }

    /// Two addresses name the same server, ignoring case, a trailing slash and a default port.
    static func sameServer(_ a: String, _ b: String) -> Bool {
        func canon(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while t.hasSuffix("/") { t.removeLast() }
            if t.hasSuffix(":443"), t.hasPrefix("https://") { t.removeLast(4) }
            return t
        }
        return !a.isEmpty && canon(a) == canon(b)
    }
}
