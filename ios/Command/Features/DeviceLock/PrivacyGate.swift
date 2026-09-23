//
//  PrivacyGate.swift
//  Command
//
//  The reveal gate for redaction. Redacting (hiding) an item is unguarded — you can always
//  veil your own content. *Un*redacting or peeking at a hidden item requires proving presence:
//  biometrics (the "passkey" path) first, then the device passcode. This reuses the same PIN as
//  the device lock (LockController/PinStore) so there's one secret to remember; if none is set
//  yet, the gate walks the user through establishing one before the first reveal.
//
//  Usage from anywhere on the main actor:
//      if await app.privacy.authenticate(reason: "Reveal this note") { … reveal … }
//  A single host (`privacyChallenge()`, mounted next to the app shell) presents the UI and
//  resolves the awaiting caller.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class PrivacyGate {
    /// Non-nil while a challenge is on screen. The host observes this to present the sheet.
    private(set) var pending: Challenge?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// Mounted hosts, oldest first. Only the newest presents: a sheet can't be presented from a
    /// view that is already presenting one, so a reveal asked for from inside a sheet (Account's
    /// "Reveal all", a note opened as a sheet) must be shown by a host inside that sheet. With a
    /// single root host the challenge never appeared, the caller waited forever, and `pending`
    /// stayed set — so every later reveal was declined until relaunch.
    private(set) var hosts: [UUID] = []

    func mountHost(_ id: UUID) { hosts.removeAll { $0 == id }; hosts.append(id) }

    func unmountHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
        // The sheet presenting the challenge went away underneath it: treat as cancelled rather
        // than leave the caller suspended with no UI.
        if hosts.isEmpty, pending != nil { resolve(false) }
    }

    struct Challenge: Identifiable, Equatable {
        let id = UUID()
        let reason: String
    }

    /// Ask the user to prove presence before revealing hidden content. Returns `true` if they
    /// authenticated (biometrics, correct passcode, or just-established passcode), else `false`.
    /// If a challenge is already in flight the new request is declined rather than queued —
    /// reveal is always a direct response to a tap, so overlap shouldn't happen.
    func authenticate(reason: String) async -> Bool {
        guard pending == nil else { return false }
        return await withCheckedContinuation { cont in
            continuation = cont
            pending = Challenge(reason: reason)
        }
    }

    /// Called by the challenge UI to dismiss the sheet and hand the result back to the caller.
    func resolve(_ authenticated: Bool) {
        guard continuation != nil else { return }   // idempotent: interactive-dismiss + button race
        pending = nil
        continuation?.resume(returning: authenticated)
        continuation = nil
    }
}

// MARK: - Host

extension View {
    /// Mount the reveal-challenge sheet. Place it beside the app shell (like `LockGate`), inside
    /// the AppState environment — and inside any sheet whose content can ask for a reveal, since
    /// only the top-most host can present. Inert until `app.privacy.authenticate(…)` is awaited.
    func privacyChallenge() -> some View { modifier(PrivacyChallengeHost()) }
}

private struct PrivacyChallengeHost: ViewModifier {
    @Environment(AppState.self) private var app
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { app.privacy.mountHost(id) }
            .onDisappear { app.privacy.unmountHost(id) }
            .sheet(item: Binding(
                get: { app.privacy.hosts.last == id ? app.privacy.pending : nil },
                // A swipe-to-dismiss (item → nil) counts as cancelling the reveal.
                set: { if $0 == nil { app.privacy.resolve(false) } }
            )) { challenge in
                PrivacyChallengeView(reason: challenge.reason)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .macSheet()
            }
    }
}

// MARK: - Challenge UI

/// The reveal prompt: biometrics on appear, then the passcode pad — or, if no passcode exists
/// yet, a one-tap path to establish one (which itself counts as authenticating).
private struct PrivacyChallengeView: View {
    @Environment(AppState.self) private var app
    let reason: String

    @State private var pin = ""
    @State private var error = false
    @State private var showSetPin = false
    @State private var biometricTried = false
    @State private var lockoutSeconds: TimeInterval = 0
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var accountId: Int? { app.account?.id }
    private var hasPin: Bool {
        #if DEBUG
        // Screenshot hook: the iOS Simulator's unsigned debug build can't persist a Keychain PIN
        // (SecItemAdd → errSecMissingEntitlement), so force the entry pad to render it here.
        if UserDefaults.standard.bool(forKey: "COMMAND_FORCE_PIN_ENTRY") { return true }
        #endif
        return accountId.map { app.lock.hasPin(account: $0) } ?? false
    }
    private var length: Int { accountId.map { app.lock.pinLength(account: $0) } ?? 6 }
    private var biometricOffered: Bool {
        hasPin && app.lock.biometricEnabled && app.lock.biometricAvailable
    }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if hasPin { entry } else { setupPrompt }
        }
        .sheet(isPresented: $showSetPin) {
            if let id = accountId {
                SetPinView(accountId: id) { established in app.privacy.resolve(established) }
                    .macSheet()
            }
        }
        .task {
            // Restore any active reveal-lockout so reopening the sheet mid-backoff still blocks input.
            if let id = accountId { lockoutSeconds = app.lock.revealLockoutRemaining(account: id) }
            // Offer biometrics immediately — the fast, passkey-like path.
            guard !biometricTried, biometricOffered else { return }
            biometricTried = true
            if await Biometrics.authenticate(reason: reason) { app.privacy.resolve(true) }
        }
        .onReceive(ticker) { _ in if lockoutSeconds > 0 { lockoutSeconds = max(0, lockoutSeconds - 1) } }
    }

    // Passcode entry (an account with a PIN set).
    private var entry: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.system(size: 28)).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("Unlock to reveal").font(Typeface.display(22)).foregroundStyle(Palette.ink)
            Text(reason)
                .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            PinDots(count: pin.count, length: length)
            if lockoutSeconds > 0 {
                Text("Too many attempts — try again in \(Int(lockoutSeconds.rounded(.up)))s")
                    .font(Typeface.body(13)).foregroundStyle(Palette.danger).multilineTextAlignment(.center)
            } else if error {
                Text("Wrong passcode").font(Typeface.body(13)).foregroundStyle(Palette.danger)
            } else {
                Color.clear.frame(height: 16)
            }
            Spacer(minLength: 4)
            PinPad(biometricLabel: biometricOffered ? Biometrics.label : nil,
                   onBiometric: { Task { if await Biometrics.authenticate(reason: reason) { app.privacy.resolve(true) } } },
                   onDigit: add, onDelete: del)
                .disabled(lockoutSeconds > 0)
                .opacity(lockoutSeconds > 0 ? 0.5 : 1)
            Button("Cancel") { app.privacy.resolve(false) }
                .font(Typeface.body(15)).tint(Palette.inkSecondary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 32)
    }

    // No passcode yet — establish one first (a hidden item has no key otherwise).
    private var setupPrompt: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.badge.clock").font(.system(size: 34)).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("Protect hidden items").font(Typeface.display(22)).foregroundStyle(Palette.ink)
            Text("Set a passcode to reveal hidden notes, reminders, and logs. It's stored only on this device.")
                .font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Button { showSetPin = true } label: {
                Text("Set Passcode").font(Typeface.body(16, .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain).padding(.horizontal, 32).padding(.top, 6)
            Button("Not now") { app.privacy.resolve(false) }
                .font(Typeface.body(15)).tint(Palette.inkSecondary)
            Spacer()
        }
    }

    private func add(_ d: Int) {
        guard pin.count < length, lockoutSeconds <= 0 else { return }
        error = false
        pin.append(String(d))
        guard pin.count == length else { return }
        guard let id = accountId else { pin = ""; return }
        switch app.lock.verifyReveal(pin: pin, account: id) {
        case .success:
            app.privacy.resolve(true)
        case .wrong(let backoff):
            error = true; pin = ""
            if backoff > 0 { lockoutSeconds = backoff }   // rate-limiting has kicked in
        case .lockedOut(let seconds):
            pin = ""; lockoutSeconds = seconds
        case .noPin:
            app.privacy.resolve(false)   // shouldn't reach here (entry is gated on hasPin)
        }
    }

    private func del() { if !pin.isEmpty { pin.removeLast() } }
}
