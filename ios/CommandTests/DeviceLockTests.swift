//
//  DeviceLockTests.swift
//  CommandTests
//
//  Security-critical: the PIN verifier (PBKDF2) and the attempt-lockout policy. Pure logic,
//  no Keychain I/O (that needs a host app + entitlement). Uses a low iteration count for speed
//  — the derivation is identical, only slower in production.
//

import XCTest
@testable import Command

final class DeviceLockTests: XCTestCase {

    // MARK: PinCredential

    func testCorrectPinMatchesAndWrongDoesNot() {
        let cred = PinCredential.make(pin: "1234", iterations: 1_000)
        XCTAssertTrue(cred.matches("1234"))
        XCTAssertFalse(cred.matches("1235"))
        XCTAssertFalse(cred.matches("123"))
        XCTAssertFalse(cred.matches(""))
        XCTAssertFalse(cred.matches("123456"))
    }

    func testSixDigitPin() {
        let cred = PinCredential.make(pin: "024680", iterations: 1_000)
        XCTAssertTrue(cred.matches("024680"))
        XCTAssertFalse(cred.matches("024681"))
    }

    func testDerivationIsDeterministic() {
        let salt = Data((0..<16).map { UInt8($0) })
        let a = PinCredential.derive(pin: "1234", salt: salt, iterations: 2_000)
        let b = PinCredential.derive(pin: "1234", salt: salt, iterations: 2_000)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
        // A different salt yields a different key for the same PIN.
        let other = PinCredential.derive(pin: "1234", salt: Data(repeating: 9, count: 16), iterations: 2_000)
        XCTAssertNotEqual(a, other)
    }

    func testSaltIsUniquePerMake() {
        let a = PinCredential.make(pin: "1234", iterations: 1_000)
        let b = PinCredential.make(pin: "1234", iterations: 1_000)
        XCTAssertNotEqual(a.salt, b.salt)          // random salt each time
        XCTAssertNotEqual(a.verifier, b.verifier)  // so identical PINs store differently
    }

    func testPinFormat() {
        XCTAssertTrue(PinFormat.isValid("1234"))
        XCTAssertTrue(PinFormat.isValid("123456"))
        XCTAssertFalse(PinFormat.isValid("12345"))   // 5 digits not allowed
        XCTAssertFalse(PinFormat.isValid("12a4"))
        XCTAssertFalse(PinFormat.isValid(""))
    }

    // MARK: LockoutPolicy

    func testBackoffThresholds() {
        XCTAssertEqual(LockoutPolicy.backoff(failedCount: 0), 0)
        XCTAssertEqual(LockoutPolicy.backoff(failedCount: 4), 0)        // below soft threshold
        XCTAssertEqual(LockoutPolicy.backoff(failedCount: 5), 30)       // soft threshold → base
        XCTAssertEqual(LockoutPolicy.backoff(failedCount: 6), 60)       // doubling
        XCTAssertEqual(LockoutPolicy.backoff(failedCount: 7), 120)
        XCTAssertEqual(LockoutPolicy.backoff(failedCount: 100), 3600)   // capped at max
    }

    func testRegisterFailureCountsAndLocks() {
        var state = LockoutState()
        // First 4 failures: counted, no backoff window.
        for i in 1...4 {
            let r = LockoutPolicy.registerFailure(state, now: 1_000)
            state = r.state
            XCTAssertEqual(state.failedCount, i)
            XCTAssertNil(state.lockedUntilEpoch)
            XCTAssertFalse(r.wipe)
        }
        // 5th failure: backoff window opens.
        let fifth = LockoutPolicy.registerFailure(state, now: 1_000)
        state = fifth.state
        XCTAssertEqual(state.failedCount, 5)
        XCTAssertEqual(state.lockedUntilEpoch, 1_030)
        XCTAssertFalse(LockoutPolicy.canAttempt(state, now: 1_000))
        XCTAssertEqual(LockoutPolicy.remaining(state, now: 1_010), 20)
        XCTAssertTrue(LockoutPolicy.canAttempt(state, now: 1_030))
    }

    func testWipeAtThreshold() {
        var state = LockoutState()
        var wiped = false
        for _ in 1...LockoutPolicy.wipeThreshold {
            let r = LockoutPolicy.registerFailure(state, now: 0)
            state = r.state
            wiped = r.wipe
        }
        XCTAssertEqual(state.failedCount, 10)
        XCTAssertTrue(wiped)
    }

    func testSuccessResets() {
        let dirty = LockoutState(failedCount: 7, lockedUntilEpoch: 5_000)
        let clean = LockoutPolicy.registerSuccess(dirty)
        XCTAssertEqual(clean.failedCount, 0)
        XCTAssertNil(clean.lockedUntilEpoch)
        XCTAssertTrue(LockoutPolicy.canAttempt(clean, now: 0))
    }
}
