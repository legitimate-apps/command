//
//  HideMenu.swift
//  Command
//
//  The Hide / Reveal actions for a hideable item (note, assignment/reminder, logged fact),
//  ready to drop into any `Menu {}` or `.contextMenu {}`. Hiding takes effect immediately;
//  revealing is gated behind the device passcode / biometrics via `PrivacyGate`. Each call
//  site supplies one `setHidden` closure so the store stays the source of truth.
//

import SwiftUI

struct HideMenuItems: View {
    @Environment(AppState.self) private var app
    let isHidden: Bool
    /// Shown on the reveal challenge so the user knows what they're unlocking.
    var reason: String = "Reveal this item"
    /// Persist the new hidden state (the store call). Runs only after the gate passes for reveals.
    let setHidden: (Bool) async -> Void
    /// Ask the call site to confirm before hiding. Hiding is one tap in a menu, but *undoing*
    /// it costs a passcode/biometric challenge — so a mis-tap is cheap to cause and expensive to
    /// reverse, and testers ended up with most of their list accidentally hidden. The confirmation
    /// lives at the call site because a dialog can't present from inside `Menu` content.
    let requestHide: () -> Void

    var body: some View {
        if isHidden {
            Button {
                Task {
                    if await app.privacy.authenticate(reason: reason) { await setHidden(false) }
                }
            } label: {
                Label("Reveal", systemImage: "eye")
            }
        } else {
            Button(action: requestHide) {
                Label("Hide…", systemImage: "eye.slash")
            }
        }
    }
}

/// The shared confirm for hiding an item. Attach to the row/detail that owns the menu.
extension View {
    func hideConfirmation(isPresented: Binding<Bool>, what: String, confirm: @escaping () -> Void) -> some View {
        confirmationDialog("Hide this \(what)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Hide", role: .destructive, action: confirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays in your list but is hidden, and is kept from the assistant. Revealing it again needs your passcode.")
        }
    }
}
