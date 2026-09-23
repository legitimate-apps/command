//
//  PinCredential.swift
//  Command
//
//  A device-lock PIN verifier. A 4–6 digit PIN is low entropy (10^4–10^6), so the stored
//  value is a PBKDF2-HMAC-SHA256 derivation with a per-user random salt and a high iteration
//  count — slow enough to blunt brute force, but the real protection is that this lives in the
//  Keychain (device-bound hardware encryption) behind an attempt lockout, never on disk.
//

import Foundation
import CommonCrypto

struct PinCredential: Codable, Equatable {
    let salt: Data
    let iterations: UInt32
    let verifier: Data

    static let defaultIterations: UInt32 = 200_000
    private static let keyLength = 32
    private static let saltLength = 16

    /// Derive the PBKDF2 key for `pin` against a salt. Pure — used for both make and verify.
    static func derive(pin: String, salt: Data, iterations: UInt32) -> Data {
        let pinBytes = Array(pin.utf8)
        var out = [UInt8](repeating: 0, count: keyLength)
        _ = salt.withUnsafeBytes { (saltBuf: UnsafeRawBufferPointer) -> Int32 in
            pinBytes.withUnsafeBytes { (pinBuf: UnsafeRawBufferPointer) -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pinBuf.baseAddress?.assumingMemoryBound(to: Int8.self), pinBytes.count,
                    saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &out, out.count)
            }
        }
        return Data(out)
    }

    /// Create a fresh credential for `pin` with a new random salt.
    static func make(pin: String, iterations: UInt32 = defaultIterations) -> PinCredential {
        var saltBytes = [UInt8](repeating: 0, count: saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let salt = Data(saltBytes)
        return PinCredential(salt: salt, iterations: iterations,
                             verifier: derive(pin: pin, salt: salt, iterations: iterations))
    }

    /// Constant-time check so verification time doesn't leak how many bytes matched.
    func matches(_ pin: String) -> Bool {
        let candidate = Self.derive(pin: pin, salt: salt, iterations: iterations)
        guard candidate.count == verifier.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(candidate, verifier) { diff |= a ^ b }
        return diff == 0
    }
}

/// Allowed PIN shapes — operator chose 6-digit default, 4 allowed.
enum PinLength: Int, CaseIterable { case four = 4, six = 6 }

enum PinFormat {
    static func isValid(_ pin: String) -> Bool {
        (pin.count == 4 || pin.count == 6) && pin.allSatisfy(\.isNumber)
    }
}
