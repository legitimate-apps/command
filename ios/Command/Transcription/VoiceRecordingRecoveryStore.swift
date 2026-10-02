import CryptoKit
import Foundation

/// Owns stopped audio independently of a recorder's temporary file. App-level recovery UI and
/// account lifecycle wiring are separate: callers must explicitly opt into this durable owner.
@MainActor
final class VoiceRecordingRecoveryStore {
    struct Recording: Codable {
        let version: Int
        let id: UUID
        let filename: String
        var transcript: String? = nil
        var engine: String? = nil
    }
    enum RecoveryError: Error { case invalidRecord }
    let directory: URL
    private let files = FileManager.default

    init(root: URL, server: URL, accountID: Int, username: String, accountCreatedAt: String) {
        let identity = [server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        String(accountID), username, accountCreatedAt].joined(separator: "\n")
        let scope = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(scope, isDirectory: true)
    }

    /// Publish metadata only after the copied audio exists. A crash during copy leaves the source
    /// untouched and an undiscoverable partial directory; no successful capture is claimed.
    func keep(_ source: URL, id: UUID) throws -> Recording {
        let suffix = source.pathExtension.lowercased()
        guard ["m4a", "wav", "caf"].contains(suffix) else { throw RecoveryError.invalidRecord }
        let record = Recording(version: 1, id: id, filename: "recording.\(suffix)")
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var protectedFolder = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedFolder.setResourceValues(values)
        let destination = folder.appendingPathComponent(record.filename)
        try files.copyItem(at: source, to: destination)
        try files.setAttributes([.posixPermissions: 0o600,
                                 .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                ofItemAtPath: destination.path)
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("manifest.json"),
                                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try files.setAttributes([.posixPermissions: 0o600],
                                ofItemAtPath: folder.appendingPathComponent("manifest.json").path)
        return record
    }

    func saveReview(id: UUID, transcript: String, engine: String) throws {
        let manifest = directory.appendingPathComponent(id.uuidString).appendingPathComponent("manifest.json")
        var record = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: manifest))
        guard record.id == id else { throw RecoveryError.invalidRecord }
        _ = try audioURL(for: record)
        record.transcript = transcript
        record.engine = engine
        try JSONEncoder().encode(record).write(to: manifest,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }

    func recordings() throws -> [Recording] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .compactMap { folder in
                let manifest = folder.appendingPathComponent("manifest.json")
                guard files.fileExists(atPath: manifest.path) else { return nil }
                let record = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: manifest))
                guard record.id.uuidString == folder.lastPathComponent else { throw RecoveryError.invalidRecord }
                _ = try audioURL(for: record)
                return record
            }
    }

    func audioURL(for record: Recording) throws -> URL {
        guard record.version == 1, ["recording.m4a", "recording.wav", "recording.caf"].contains(record.filename)
        else { throw RecoveryError.invalidRecord }
        let url = directory.appendingPathComponent(record.id.uuidString).appendingPathComponent(record.filename)
        guard files.fileExists(atPath: url.path) else { throw RecoveryError.invalidRecord }
        return url
    }

    /// Removing the manifest first makes a crash during cleanup non-replayable. Leftover audio
    /// remains private; it is never mistaken for another pending recording.
    func discard(_ id: UUID) throws {
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let manifest = folder.appendingPathComponent("manifest.json")
        if files.fileExists(atPath: manifest.path) { try files.removeItem(at: manifest) }
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
    }
}
