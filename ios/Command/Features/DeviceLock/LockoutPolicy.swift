//
//  LockoutPolicy.swift
//  Command
//
//  Pure attempt-lockout logic for the device PIN. Because a PIN is low entropy, rate-limiting
//  is the real defence: after a few misses the next attempt is delayed (exponential backoff),
//  and after enough misses the device's local sessions + roster are wiped, forcing a full
//  re-login. State is persisted in the Keychain so it survives a relaunch (you can't escape the
//  lockout by killing the app). Kept free of I/O so it can be exhaustively unit-tested.
//

import Foundation

struct LockoutState: Codable, Equatable {
    var failedCount: Int = 0
    var lockedUntilEpoch: TimeInterval?
}

enum LockoutPolicy {
    /// Backoff begins once failures reach this count.
    static let softThreshold = 5
    /// At this many failures the device's local data is wiped (full re-login required).
    static let wipeThreshold = 10
    static let baseBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 3600

    /// Backoff seconds imposed after `failedCount` failures (0 below the soft threshold).
    static func backoff(failedCount: Int) -> TimeInterval {
        guard failedCount >= softThreshold else { return 0 }
        let over = failedCount - softThreshold                 // 0, 1, 2, …
        return min(baseBackoff * pow(2, Double(over)), maxBackoff)  // 30s, 60s, 120s … capped 1h
    }

    /// Record a failed attempt at wall-clock `now`. Returns the new state and whether the
    /// caller must now wipe local data.
    static func registerFailure(_ state: LockoutState, now: TimeInterval) -> (state: LockoutState, wipe: Bool) {
        var next = state
        next.failedCount += 1
        let bo = backoff(failedCount: next.failedCount)
        next.lockedUntilEpoch = bo > 0 ? now + bo : nil
        return (next, next.failedCount >= wipeThreshold)
    }

    /// Clear the counter after a correct PIN.
    static func registerSuccess(_ state: LockoutState) -> LockoutState {
        LockoutState(failedCount: 0, lockedUntilEpoch: nil)
    }

    /// Seconds remaining in the current backoff at `now` (0 if attempts are allowed).
    static func remaining(_ state: LockoutState, now: TimeInterval) -> TimeInterval {
        guard let until = state.lockedUntilEpoch else { return 0 }
        return max(0, until - now)
    }

    /// Whether an attempt is permitted right now.
    static func canAttempt(_ state: LockoutState, now: TimeInterval) -> Bool {
        remaining(state, now: now) <= 0
    }
}
