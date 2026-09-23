//
//  LockController.swift
//  Command
//
//  The device-lock state machine. When a PIN is set for the active account the app starts
//  locked and re-locks the instant it leaves the foreground (shared-iPad behaviour). The
//  reveal requires the correct PIN (or biometrics as a convenience). A separate "shielded"
//  flag drives the privacy overlay during the brief inactive window so the app-switcher
//  snapshot can't leak content. Only consulted when the `deviceLock` feature flag is on.
//

import Foundation
import Observation

@MainActor
@Observable
final class LockController {
    enum Mode: Equatable { case unlocked, locked }

    private(set) var mode: Mode = .unlocked
    /// True during the inactive/background window — drives an opaque privacy cover.
    private(set) var shielded = false
    /// The account whose PIN unlocks the app (the most-recently-active user).
    private(set) var accountId: Int?
    /// Per-user biometric opt-in (default on where available).
    var biometricEnabled = true

    private let pins = PinStore()
    private let biometricKey = "command.deviceLock.biometricEnabled"

    init() {
        if UserDefaults.standard.object(forKey: biometricKey) != nil {
            biometricEnabled = UserDefaults.standard.bool(forKey: biometricKey)
        }
    }

    var isLocked: Bool { mode == .locked }
    var biometricAvailable: Bool { Biometrics.isAvailable }

    /// Point the lock at the active account. `lockNow` is true on a resumed/cold-launch session
    /// (require the PIN before showing data) and false right after a fresh password login (the
    /// user is already present, so don't immediately re-challenge).
    func configure(accountId: Int?, lockNow: Bool) {
        self.accountId = accountId
        if lockNow, let id = accountId, pins.hasPin(account: id) {
            mode = .locked
        }
    }

    /// The 4- or 6-digit length chosen for an account's PIN (drives the entry dots).
    func pinLength(account: Int) -> Int {
        let n = UserDefaults.standard.integer(forKey: "command.deviceLock.length.\(account)")
        return (n == 4 || n == 6) ? n : 6
    }

    /// Re-lock on backgrounding, but only if the active account is PIN-protected.
    func lockIfProtected() {
        guard let id = accountId, pins.hasPin(account: id) else { return }
        mode = .locked
    }

    func setShielded(_ on: Bool) { shielded = on }

    func hasPin(account: Int) -> Bool { pins.hasPin(account: account) }
    /// Returns whether the PIN persisted. A false here means the Keychain refused the write and
    /// the account has NO passcode — the caller must say so rather than dismissing as if set.
    @discardableResult
    func setPin(_ pin: String, account: Int) -> Bool {
        guard pins.setPin(pin, account: account) else { return false }
        accountId = account
        UserDefaults.standard.set(pin.count, forKey: "command.deviceLock.length.\(account)")
        return true
    }
    func removePin(account: Int) {
        pins.removePin(account: account)
        UserDefaults.standard.removeObject(forKey: "command.deviceLock.length.\(account)")
    }
    func setBiometric(_ on: Bool) {
        biometricEnabled = on
        UserDefaults.standard.set(on, forKey: biometricKey)
    }

    /// Attempt a PIN. On success the app unlocks; otherwise the lockout state advances.
    func attempt(pin: String) -> PinStore.VerifyResult {
        guard let id = accountId else { return .noPin }
        let result = pins.verify(pin, account: id, now: Date().timeIntervalSince1970)
        if result == .success { mode = .unlocked }
        return result
    }

    /// Reveal-gate PIN check: rate-limited (exponential backoff, persisted) but never wipes.
    /// `.noPin` means route the caller to `setPin` first.
    func verifyReveal(pin: String, account: Int) -> PinStore.RevealResult {
        pins.verifyReveal(pin, account: account, now: Date().timeIntervalSince1970)
    }

    func revealLockoutRemaining(account: Int) -> TimeInterval {
        pins.revealLockoutRemaining(account: account, now: Date().timeIntervalSince1970)
    }

    /// Convenience biometric unlock. Returns whether it unlocked.
    func tryBiometric() async -> Bool {
        guard biometricEnabled, Biometrics.isAvailable else { return false }
        let ok = await Biometrics.authenticate(reason: "Unlock Command")
        if ok { mode = .unlocked }
        return ok
    }

    func lockoutRemaining() -> TimeInterval {
        guard let id = accountId else { return 0 }
        return pins.lockoutRemaining(account: id, now: Date().timeIntervalSince1970)
    }

    /// Sign-out: forget the active account and drop to unlocked (the PIN stays in the Keychain
    /// so the user can sign back in and reuse it, unless they removed it).
    func reset() {
        mode = .unlocked
        accountId = nil
        shielded = false
    }

    /// The PIN was wiped after too many failures. Purge THIS account's persisted credential AND
    /// lockout state before the forced logout — otherwise a later sign-in reloads the tripped
    /// lockout from the Keychain, rejecting even the correct PIN for the backoff window and then
    /// re-wiping on the next miss (a permanent one-miss-from-wipe trap). Must run before reset()
    /// nils out accountId.
    func clearWipedAccount() {
        if let id = accountId { pins.removePin(account: id) }
        reset()
    }
}
