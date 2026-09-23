//
//  CommandApp.swift
//  Command
//

import SwiftUI
import UIKit

@main
struct CommandApp: App {
    @State private var app = AppState()
    @State private var bus = AppCommandBus()   // Mac/iPad menu + keyboard intents
    @Environment(\.scenePhase) private var scenePhase
    // Adopt an app delegate solely to receive the APNs device token (SwiftUI has no direct hook).
    @UIApplicationDelegateAdaptor(CommandAppDelegate.self) private var appDelegate

    init() { Self.configureNavigationAppearance() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(WidgetSurfacesModifier(app: app))
                .modifier(LockGate())   // device PIN lock + privacy shield (inert unless flagged on)
                .privacyChallenge()     // redaction reveal gate (biometric/passcode) — inert until awaited
                .macWindowFloor()       // Catalyst-only: a sane minimum so the window never collapses to content (e.g. the loading spinner)
                .environment(app)       // injected ABOVE LockGate so its overlays see AppState too
                .environment(bus)
                .tint(Palette.accent)
                .task {
                    // Let the App Intents layer live-update the running UI after a background
                    // capture, and let "Open Command" intents reach the active shell.
                    ShortcutNavigation.shared.appState = app
                    app.subscription.configureIfNeeded()   // RevenueCat, once, before sign-in
                    await app.bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.didEnterForeground() }   // resync device timezone (B2)
                }
                .onOpenURL { url in
                    if url.scheme == "command", url.host == "voice", #available(iOS 26.0, *) {
                        ShortcutNavigation.shared.route(.voiceConversation)
                    } else if url.scheme == "command", url.host == "calendar" {
                        // The agenda widget's tap target. Same sticky route an "Open Command"
                        // intent uses, so a cold launch lands on Calendar too.
                        ShortcutNavigation.shared.route(.go(.calendar))
                    } else {
                        app.handleIncomingURL(url)
                    }
                }
        }
        // The menu bar (Mac) / ⌘-HUD (iPad keyboard). No-op on the iPhone path.
        .commands { CommandMenus(bus: bus) }
        // Give the three-column shell room. On Mac Catalyst the window's MAX size tracks
        // `defaultSize` (SwiftUI drives the scene's `sizeRestrictions` from it and re-applies it,
        // so an `onAppear` override doesn't stick) — so this is effectively the largest the window
        // opens/grows to as well as its initial size. 1400×880 gives the three columns real room on
        // a Mac display; `macWindowFloor()`'s 900×600 floor is the lower bound it resizes down to.
        .defaultSize(width: 1400, height: 880)
        // `.contentMinSize` (NOT `.contentSize`): opens at `defaultSize`, resizable down to the
        // content's MINIMUM — vs `.contentSize`, which locks the window to its fitting size and
        // collapses the macOS window to whatever is on screen during launch (the loading spinner).
        // macOS-only API; inert on iOS/iPadOS, which is why this never showed on the simulators.
        .windowResizability(.contentMinSize)
    }

    /// Editorial serif (New York) navigation titles app-wide — the notebook feel.
    private static func configureNavigationAppearance() {
        func serif(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return base
        }
        let ink = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.925, green: 0.890, blue: 0.839, alpha: 1)
                : UIColor(red: 0.129, green: 0.110, blue: 0.086, alpha: 1)
        }
        let appearance = UINavigationBarAppearance()
        // Transparent bar: no material/fill, so content (and overlays) show through behind the
        // title + bar buttons. Applied to standard/scrollEdge/compact below, so it stays clear
        // in every scroll state.
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.font: serif(32, .semibold), .foregroundColor: ink]
        appearance.titleTextAttributes = [.font: serif(17, .semibold), .foregroundColor: ink]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}

private struct WidgetSurfacesModifier: ViewModifier {
    let app: AppState

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.modifier(WidgetAgendaSync(app: app))
        } else {
            content
        }
    }
}

private extension View {
    /// A minimum window size for Mac Catalyst so the root content (and therefore the
    /// window, under `.contentMinSize`) never collapses to the launch spinner's size.
    /// No-op on iPhone/iPad, where imposing a 900pt floor would break compact layout.
    @ViewBuilder func macWindowFloor() -> some View {
        #if targetEnvironment(macCatalyst)
        // A 900×600 floor so the window never collapses to the launch spinner, with explicit
        // `maxWidth/maxHeight: .infinity` so the content advertises it can fill a larger window
        // (without these the frame's upper size was ambiguous and the window opened pinned at the
        // 900pt floor instead of the roomy `defaultSize`).
        frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        #else
        self
        #endif
    }
}
