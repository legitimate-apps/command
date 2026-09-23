//
//  PinStore.swift
//  Command
//
//  Ties the PIN verifier + lockout state to the Keychain, per account. All persistence is
//  device-bound (see Keychain). The verify path is the only place attempts are counted, so the
//  lockout can't be bypassed by anything but a correct PIN (or the wipe after too many misses).
//

import Foundation

@MainActor
struct PinStore {
    private let credService = "com.legitimateapps.command.pin.credential"
    private let lockService = "com.legitimateapps.command.pin.lockout"
    // A SEPARATE lockout ledger for the redaction reveal gate. It shares the PIN but must never
    // wipe (mistyping to peek at a hidden note can't nuke the session), so it can't reuse the
    // device-unlock lockout state.
    private let revealLockService = "com.legitimateapps.command.pin.reveal-lockout"

    enum VerifyResult: Equatable {
        case success
        case wrong(remainingBeforeWipe: Int)
        case lockedOut(seconds: TimeInterval)
        case wiped
        case noPin
    }

    /// Reveal-gate outcome — like VerifyResult but with no `wiped` case (reveal never wipes).
    enum RevealResult: Equatable {
        case success
        case wrong(backoff: TimeInterval)      // failed; backoff > 0 once rate-limiting kicks in
        case lockedOut(seconds: TimeInterval)  // still inside a backoff window
        case noPin
    }

    func hasPin(account: Int) -> Bool {
        Keychain.get(service: credService, account: String(account)) != nil
    }

    /// Set (or replace) the account's PIN. Returns whether the credential actually persisted.
    ///
    /// The result is not decorative: a Keychain write can genuinely fail — `errSecMissingEntitlement`
    /// on an unsigned build is the one already documented here — and this used to discard it. The
    /// setup screen would then dismiss as if it had succeeded while `hasPin` stayed false, leaving
    /// someone believing their notes were behind a passcode that was never stored.
    ///
    /// BOTH lockout ledgers reset, not just the device-lock one. They are separate services (the
    /// reveal gate must never wipe), and only clearing one meant a long exponential backoff from
    /// mistyping the reveal PIN survived setting a brand-new PIN.
    @discardableResult
    func setPin(_ pin: String, account: Int) -> Bool {
        let acct = String(account)
        let cred = PinCredential.make(pin: pin)
        let stored = Keychain.setCodable(cred, service: credService, account: acct)
        _ = Keychain.setCodable(LockoutState(), service: lockService, account: acct)
        _ = Keychain.setCodable(LockoutState(), service: revealLockService, account: acct)
        return stored
    }

    func removePin(account: Int) {
        let acct = String(account)
        Keychain.delete(service: credService, account: acct)
        Keychain.delete(service: lockService, account: acct)
        // Leaving this behind stranded a reveal backoff on an account with no PIN at all, which
        // then applied to whatever PIN was set next.
        Keychain.delete(service: revealLockService, account: acct)
    }

    /// The redaction reveal gate. Rate-limits brute force with the same exponential backoff as the
    /// device lock (persisted, so it survives a relaunch) but NEVER wipes — mistyping the PIN to peek
    /// at a hidden note must not nuke the session. Biometrics stay the primary path; this closes the
    /// hole where an already-unlocked device could try all 10^4–10^6 PINs unthrottled to unveil items.
    func verifyReveal(_ pin: String, account: Int, now: TimeInterval) -> RevealResult {
        let acct = String(account)
        guard let cred = Keychain.getCodable(PinCredential.self, service: credService, account: acct) else {
            return .noPin
        }
        let lock = Keychain.getCodable(LockoutState.self, service: revealLockService, account: acct) ?? LockoutState()
        if !LockoutPolicy.canAttempt(lock, now: now) {
            return .lockedOut(seconds: LockoutPolicy.remaining(lock, now: now))
        }
        if cred.matches(pin) {
            _ = Keychain.setCodable(LockoutPolicy.registerSuccess(lock), service: revealLockService, account: acct)
            return .success
        }
        let result = LockoutPolicy.registerFailure(lock, now: now)   // ignore result.wipe — reveal never wipes
        _ = Keychain.setCodable(result.state, service: revealLockService, account: acct)
        return .wrong(backoff: LockoutPolicy.remaining(result.state, now: now))
    }

    func revealLockoutRemaining(account: Int, now: TimeInterval) -> TimeInterval {
        let lock = Keychain.getCodable(LockoutState.self, service: revealLockService, account: String(account)) ?? LockoutState()
        return LockoutPolicy.remaining(lock, now: now)
    }

    func verify(_ pin: String, account: Int, now: TimeInterval) -> VerifyResult {
        let acct = String(account)
        guard let cred = Keychain.getCodable(PinCredential.self, service: credService, account: acct) else {
            return .noPin
        }
        var lock = Keychain.getCodable(LockoutState.self, service: lockService, account: acct) ?? LockoutState()
        if !LockoutPolicy.canAttempt(lock, now: now) {
            return .lockedOut(seconds: LockoutPolicy.remaining(lock, now: now))
        }
        if cred.matches(pin) {
            lock = LockoutPolicy.registerSuccess(lock)
            _ = Keychain.setCodable(lock, service: lockService, account: acct)
            return .success
        }
        let result = LockoutPolicy.registerFailure(lock, now: now)
        _ = Keychain.setCodable(result.state, service: lockService, account: acct)
        if result.wipe { return .wiped }
        return .wrong(remainingBeforeWipe: LockoutPolicy.wipeThreshold - result.state.failedCount)
    }

    func lockoutRemaining(account: Int, now: TimeInterval) -> TimeInterval {
        let lock = Keychain.getCodable(LockoutState.self, service: lockService, account: String(account)) ?? LockoutState()
        return LockoutPolicy.remaining(lock, now: now)
    }
}
