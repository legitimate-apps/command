import Foundation

/// One intended create, retained after ambiguous failures. A changed payload or an explicit
/// reset starts a new intent; success clears only the attempt that actually finished.
struct CreateAttempt: Codable {
    private var payload: Data?
    private var currentKey: String?

    mutating func key(for body: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(body)
        if payload != data || currentKey == nil {
            payload = data
            currentKey = UUID().uuidString
        }
        return currentKey!
    }

    mutating func reset() { payload = nil; currentKey = nil }
    mutating func succeeded(key: String) {
        if currentKey == key { reset() }
    }
}
