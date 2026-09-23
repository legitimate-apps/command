//
//  LockGate.swift
//  Command
//
//  Wraps the app shell with the device lock: overlays the unlock screen while locked, a privacy
//  shield while the app is inactive (so the app-switcher snapshot can't leak), and re-locks on
//  background. Entirely inert unless the `deviceLock` flag is on, so the shipped app is unaffected.
//

import SwiftUI

struct LockGate: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay {
                if app.flags.isOn(.deviceLock) {
                    if app.lock.isLocked {
                        LockScreenView().transition(.opacity)
                    } else if app.lock.shielded {
                        PrivacyShield().transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: app.lock.isLocked)
            .onChange(of: scenePhase) { _, phase in
                guard app.flags.isOn(.deviceLock) else { return }
                switch phase {
                case .active:
                    app.lock.setShielded(false)
                case .inactive:
                    app.lock.setShielded(true)
                case .background:
                    app.lock.setShielded(true)
                    app.lock.lockIfProtected()
                @unknown default:
                    break
                }
            }
    }
}
