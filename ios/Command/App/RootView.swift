//
//  RootView.swift
//  Command
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "COMMAND_INK_PREVIEW") {
            return AnyView(InkPreviewView())
        }
        if UserDefaults.standard.bool(forKey: "COMMAND_LOCK_PREVIEW") {
            return AnyView(LockPreviewView())
        }
        if UserDefaults.standard.bool(forKey: "COMMAND_DETAIL_PREVIEW") {
            return AnyView(DetailPreviewView())
        }
        if UserDefaults.standard.bool(forKey: "COMMAND_NOTE_PREVIEW") {
            return AnyView(NotePreviewView())
        }
        if UserDefaults.standard.bool(forKey: "COMMAND_PRIVACY_PREVIEW") {
            return AnyView(PrivacyChallengePreview())
        }
        #endif
        // Honor Dynamic Type (the display/body Typeface helpers scale with it), but cap the
        // upper end so the largest accessibility sizes enlarge text without breaking the
        // fixed-frame layouts (calendar grid, capture bar, split columns).
        return AnyView(content.dynamicTypeSize(...DynamicTypeSize.accessibility2))
    }

    @ViewBuilder private var content: some View {
        switch app.phase {
        case .loading:
            ProgressView().controlSize(.large)
        case .needsServer:
            OnboardingView()
        case .signedOut:
            AuthView()
        case .unreachable:
            // Deliberately NOT the sign-in screen: the session is intact, we just could not
            // reach the server. Asking for a password here is the bug this state exists to fix.
            ServerUnreachableView()
        case .signedIn:
            if app.sessionMode == .delegatee {
                MyWorkView()
            } else {
                AdaptiveRootView()
            }
        }
    }
}

/// Shown when the app could not reach the server to confirm an existing session.
///
/// The distinction this screen draws is the whole point: "we couldn't check" is not "you are
/// signed out". The session cookie is still on the device, so a retry — or simply relaunching
/// once the network is back — resumes without a password.
struct ServerUnreachableView: View {
    @Environment(AppState.self) private var app
    @State private var retrying = false
    @State private var showServer = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Can't reach Command")
                .font(.title3.weight(.semibold))
            Text("You're still signed in — the app just couldn't check with \(serverHost). This usually means the network dropped or the server is restarting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button {
                retrying = true
                Task {
                    await app.bootstrap()
                    retrying = false
                }
            } label: {
                if retrying { ProgressView() } else { Text("Try again") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(retrying)
            // A server that moved or was retired never comes back, so "Try again" alone was a
            // dead end whose only exit was deleting the app.
            HStack(spacing: 20) {
                Button("Change server") { showServer = true }
                Button("Sign out", role: .destructive) { Task { await app.logout() } }
            }
            .font(.callout)
            .disabled(retrying)
        }
        .padding(32)
        .sheet(isPresented: $showServer) { ServerURLSheet().macSheet() }
    }

    private var serverHost: String {
        URL(string: app.serverURLString)?.host ?? "the server"
    }
}
