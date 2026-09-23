//
//  OnboardingPreviewHost.swift
//  Command
//
//  DEBUG-only: jump straight to any setup screen with stubbed state and no network, for
//  screenshots, the web guide's recordings, and eyeballing layout without tap automation.
//
//  Launch arguments (all DEBUG builds only; pass as `-KEY value` after the app's launch):
//
//    -COMMAND_ONBOARDING_STEP <step>
//        welcome   the first screen: Command Cloud or My own server
//        switch    "Choose a server" (Account → Server → Switch server)
//        cloud     the Command Cloud pane
//        selfhost  "Your own server": Railway / my computer / I have an address
//        railway   the Railway guide           docker   the Docker guide
//        connect   the address field
//        account   sign-in / create account against the chosen server
//        aikey     "Add your AI key" (self-hosted owner)
//        ready     "You're set" tutorial
//        handoff   the "Hand to your AI agent" sheet over the welcome screen
//
//    -COMMAND_ONBOARDING_KIND <kind>    the stubbed /api/server/info (account, aikey, ready)
//        cloud      Command Cloud, sign-up open, assistant behind Command Pro  (default)
//        self       a fresh self-hosted server: sign-up open, no AI key yet    (default for aikey)
//        selfOwned  a self-hosted server with its owner: sign-up closed, key set
//        legacy     an older server with no /api/server/info
//
//    -COMMAND_HANDOFF_PATH <path>       which brief the handoff sheet shows
//        undecided (default) | cloud | railway | docker | existing
//
//    -COMMAND_ONBOARDING_ADDRESS <text> pre-fills the connect field (keyboard stays down)
//
//  Example:
//    xcrun simctl launch <udid> com.legitimateapps.command -COMMAND_ONBOARDING_STEP ready
//

#if DEBUG
import SwiftUI

struct OnboardingPreviewHost: View {
    let step: String
    @Environment(AppState.self) private var app
    @State private var configured = false
    @State private var showHandoff = true

    private var kind: String {
        UserDefaults.standard.string(forKey: "COMMAND_ONBOARDING_KIND")
            ?? (step == "aikey" ? "self" : "cloud")
    }

    private var handoffPath: AgentHandoff.Path {
        UserDefaults.standard.string(forKey: "COMMAND_HANDOFF_PATH")
            .flatMap(AgentHandoff.Path.init(rawValue:)) ?? .undecided
    }

    static func stubInfo(kind: String) -> ServerInfo? {
        switch kind {
        case "self":
            return ServerInfo(service: "command", version: "1.1.0", kind: "self", registrationOpen: true,
                              ai: .init(configured: false, requiresSubscription: false, keySettable: true))
        case "selfOwned":
            return ServerInfo(service: "command", version: "1.1.0", kind: "self", registrationOpen: false,
                              ai: .init(configured: true, requiresSubscription: false, keySettable: true))
        case "legacy":
            return nil
        default:
            return ServerInfo(service: "command", version: "1.1.0", kind: "cloud", registrationOpen: true,
                              ai: .init(configured: true, requiresSubscription: true, keySettable: false))
        }
    }

    var body: some View {
        Group {
            if configured { screen } else { Palette.paper.ignoresSafeArea() }
        }
        .task {
            let isCloud = kind == "cloud"
            let url = isCloud ? ServerSetupGuide.cloudURL.absoluteString : "http://192.168.1.10:9071"
            let stage: SetupStage? = step == "aikey" ? .aiKey : (step == "ready" ? .ready : nil)
            app.applyOnboardingPreview(info: Self.stubInfo(kind: kind), serverURL: url, stage: stage,
                                       hosting: isCloud ? nil : .selfHosted, justChose: true)
            configured = true
        }
    }

    @ViewBuilder private var screen: some View {
        switch step {
        case "switch":   OnboardingView(start: .switchServer, onCancel: {})
        case "cloud":    OnboardingView(start: .cloud)
        case "selfhost": OnboardingView(start: .selfHost)
        case "railway":  OnboardingView(start: .guide(.railway))
        case "docker":   OnboardingView(start: .guide(.selfHosted))
        case "connect":  OnboardingView(start: .connect(.existing))
        case "account":  AuthView()
        case "aikey", "ready": SetupContinuationView()
        case "handoff":
            OnboardingView(start: .welcome)
                .sheet(isPresented: $showHandoff) {
                    AgentHandoffSheet(path: handoffPath, serverURL: "").macSheet(.page)
                }
        default:         OnboardingView(start: .welcome)
        }
    }
}
#endif
