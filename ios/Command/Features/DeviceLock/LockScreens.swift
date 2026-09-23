//
//  LockScreens.swift
//  Command
//
//  The device-lock surfaces: the unlock screen (PIN pad + biometrics + lockout), the set/change
//  PIN flow, and the privacy shield shown while the app is inactive so its app-switcher snapshot
//  can't leak content. All in the app's paper/ink/amber language. Presented only when the
//  `deviceLock` flag is on (see LockGate).
//

import SwiftUI

// MARK: - Shared PIN entry

/// Row of dots reflecting how many digits have been entered out of `length`.
struct PinDots: View {
    let count: Int
    let length: Int
    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<length, id: \.self) { i in
                Circle()
                    .fill(i < count ? Palette.accent : Palette.inkSecondary.opacity(0.25))
                    .frame(width: 14, height: 14)
            }
        }
        .animation(.easeOut(duration: 0.12), value: count)
    }
}

/// Shakes the view horizontally — used for a wrong PIN.
struct ShakeModifier: ViewModifier {
    let trigger: Int
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: trigger) { _, _ in
                withAnimation(.easeInOut(duration: 0.05)) {
                    offset = -10
                }
                Task { @MainActor in
                    for i in 1..<6 {
                        try? await Task.sleep(for: .milliseconds(40))
                        withAnimation(.easeInOut(duration: 0.05)) {
                            offset = i.isMultiple(of: 2) ? 10 : -10
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(40))
                    withAnimation(.easeInOut(duration: 0.05)) {
                        offset = 0
                    }
                }
            }
    }
}

extension View {
    func shake(trigger: Int) -> some View {
        modifier(ShakeModifier(trigger: trigger))
    }
}

/// The numeric keypad. The bottom-left slot optionally hosts a biometric button.
struct PinPad: View {
    var biometricLabel: String?
    var onBiometric: (() -> Void)?
    let onDigit: (Int) -> Void
    let onDelete: () -> Void

    private let metrics = UIFontMetrics(forTextStyle: .body)
    private var keySize: CGFloat { metrics.scaledValue(for: 72) }
    private var hSpacing: CGFloat { metrics.scaledValue(for: 28) }
    private var vSpacing: CGFloat { metrics.scaledValue(for: 20) }
    private var cols: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: hSpacing), count: 3) }

    var body: some View {
        LazyVGrid(columns: cols, spacing: vSpacing) {
            ForEach(1...9, id: \.self) { d in key("\(d)") { onDigit(d) } }
            // bottom row: biometric / 0 / delete
            if let label = biometricLabel, let onBiometric {
                Button(action: onBiometric) {
                    Image(systemName: label == "Face ID" ? "faceid" : "touchid")
                        .font(Typeface.body(26)).foregroundStyle(Palette.accent)
                        .accessibilityLabel(label)
                        .frame(width: keySize, height: keySize)
                }.buttonStyle(.plain)
            } else {
                Color.clear.frame(width: keySize, height: keySize)
            }
            key("0") { onDigit(0) }
            Button(action: onDelete) {
                Image(systemName: "delete.left")
                    .font(Typeface.body(22)).foregroundStyle(Palette.ink)
                    .accessibilityLabel("Delete")
                    .frame(width: keySize, height: keySize)
            }.buttonStyle(.plain)
        }
    }

    private func key(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.light()
            action()
        }) {
            Text(label)
                .font(Typeface.body(30))
                .foregroundStyle(Palette.ink)
                .frame(width: keySize, height: keySize)
                .background(Circle().fill(Palette.surface).overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Unlock screen

struct LockScreenView: View {
    @Environment(AppState.self) private var app
    @State private var pin = ""
    @State private var error: String?
    @State private var lockoutEnds: Date?
    @State private var shakeCount = 0

    private var accountId: Int? { app.lock.accountId }
    private var length: Int { accountId.map { app.lock.pinLength(account: $0) } ?? 6 }
    private var lockedOut: Bool { (lockoutEnds.map { $0 > Date() }) ?? false }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text("Enter passcode").font(Typeface.display(24)).foregroundStyle(Palette.ink)
                if let name = app.account?.displayName ?? app.account?.username {
                    Text(name).font(Typeface.body(14)).foregroundStyle(Palette.inkSecondary)
                }
                PinDots(count: pin.count, length: length)
                    .shake(trigger: shakeCount)
                statusLine
                Spacer()
                PinPad(biometricLabel: app.lock.biometricEnabled && app.lock.biometricAvailable ? Biometrics.label : nil,
                       onBiometric: { Task { _ = await app.lock.tryBiometric() } },
                       onDigit: add, onDelete: del)
                    .disabled(lockedOut)
                    .opacity(lockedOut ? 0.4 : 1)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 32)
        }
        .task {
            // Offer biometrics immediately on appear (convenience).
            _ = await app.lock.tryBiometric()
            refreshLockout()
        }
    }

    @ViewBuilder private var statusLine: some View {
        if lockedOut, let ends = lockoutEnds {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let secs = max(0, Int(ends.timeIntervalSince(ctx.date).rounded(.up)))
                Text("Too many attempts. Try again in \(secs)s")
                    .font(Typeface.body(13)).foregroundStyle(Palette.danger)
                    .onChange(of: secs) { _, s in if s == 0 { error = nil; lockoutEnds = nil } }
            }
        } else if let error {
            Text(error).font(Typeface.body(13)).foregroundStyle(Palette.danger)
        } else {
            Color.clear.frame(height: 16)
        }
    }

    private func add(_ d: Int) {
        guard !lockedOut, pin.count < length else { return }
        pin.append(String(d))
        if pin.count == length { submit() }
    }

    private func del() { if !pin.isEmpty { pin.removeLast() } }

    private func submit() {
        let result = app.lock.attempt(pin: pin)
        pin = ""
        switch result {
        case .success:
            error = nil
        case .wrong(let remaining):
            Haptics.warning()
            error = remaining <= 3 ? "Wrong passcode — \(remaining) tries left" : "Wrong passcode"
            shakeCount += 1
            refreshLockout()
        case .lockedOut(let seconds):
            lockoutEnds = Date().addingTimeInterval(seconds)
        case .wiped:
            // Too many failures: purge this account's persisted PIN + lockout (so a later sign-in
            // isn't trapped by the tripped lockout), then wipe the session and force a re-login.
            app.lock.clearWipedAccount()
            Task { await app.logout() }
        case .noPin:
            error = nil
        }
    }

    private func refreshLockout() {
        let remaining = app.lock.lockoutRemaining()
        lockoutEnds = remaining > 0 ? Date().addingTimeInterval(remaining) : nil
    }
}

// MARK: - Set / change PIN

struct SetPinView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let accountId: Int
    /// Fired as the sheet closes: `true` if a passcode was set, `false` if cancelled.
    /// Lets the redaction gate treat "just set a passcode" as a successful unlock.
    var onComplete: ((Bool) -> Void)? = nil

    @State private var length = 6
    @State private var stage: Stage = .choose
    @State private var first = ""
    @State private var entry = ""
    @State private var error: String?

    private enum Stage { case choose, confirm }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(spacing: 22) {
                    Spacer()
                    Text(stage == .choose ? "Set a passcode" : "Re-enter passcode")
                        .font(Typeface.display(24)).foregroundStyle(Palette.ink)
                    if stage == .choose {
                        Picker("Length", selection: $length) {
                            Text("4 digits").tag(4); Text("6 digits").tag(6)
                        }
                        .pickerStyle(.segmented).frame(width: 220)
                        .onChange(of: length) { _, _ in first = ""; entry = "" }
                    }
                    PinDots(count: entry.count, length: length)
                    if let error { Text(error).font(Typeface.body(13)).foregroundStyle(Palette.danger) }
                    else { Color.clear.frame(height: 16) }
                    Spacer()
                    PinPad(onDigit: add, onDelete: { if !entry.isEmpty { entry.removeLast() } })
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 32)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onComplete?(false); dismiss() }.fixedSize() } }
        }
    }

    private func add(_ d: Int) {
        guard entry.count < length else { return }
        entry.append(String(d))
        guard entry.count == length else { return }
        switch stage {
        case .choose:
            first = entry; entry = ""; error = nil; stage = .confirm
        case .confirm:
            if entry == first {
                // A Keychain refusal must not look like success — dismissing here would leave
                // someone believing their notes are behind a passcode that was never stored.
                guard app.lock.setPin(first, account: accountId) else {
                    error = "Couldn't save your passcode to this device. Please try again."
                    first = ""; entry = ""; stage = .choose
                    return
                }
                onComplete?(true)
                dismiss()
            } else {
                error = "Passcodes didn't match"
                first = ""; entry = ""; stage = .choose
            }
        }
    }
}

// MARK: - Privacy shield

struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Palette.accent.opacity(0.6))
        }
    }
}
