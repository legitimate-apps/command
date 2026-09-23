//
//  Biometrics.swift
//  Command
//
//  Face ID / Touch ID convenience unlock for the device lock. Always a convenience over the
//  PIN, never a replacement — the PIN is the source of truth, biometrics just skip typing it.
//

import Foundation
import LocalAuthentication

enum Biometrics {
    /// Whether this device can do Face ID / Touch ID right now (enrolled + available).
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// The kind of biometry, for labelling ("Face ID" / "Touch ID").
    static var label: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "Biometrics"
        }
    }

    /// Prompt for biometric auth. Returns whether it succeeded.
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        return await withCheckedContinuation { cont in
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }
}
