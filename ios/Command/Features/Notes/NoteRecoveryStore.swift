import CryptoKit
import Foundation

/// Device-local recovery, not a second notes database. Each unsent editor has its own atomic
/// file so a damaged record cannot prevent the other drafts from being recovered.
@MainActor
final class NoteRecoveryStore {
    let directory: URL
    private let files = FileManager.default
    private let owner = UUID()
    private static var owners: [URL: UUID] = [:]

    /// A reauthenticated store takes over this scope. Late completions from its predecessor
    /// must not overwrite or remove recovery files that the new editor now owns.
    func claimOwnership() { Self.owners[directory] = owner }
    private var ownsFiles: Bool { Self.owners[directory] == owner }

    init(root: URL, server: URL, account: Account) {
        // IDs are only unique within a server, and can be reused after an account is deleted.
        let identity = [server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        String(account.id), account.username, account.createdAt].joined(separator: "\n")
        let scope = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(scope, isDirectory: true)
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteRecovery", isDirectory: true)
    }

    struct Draft: Codable {
        var text: String
        var attempt: CreateAttempt
    }

    func loadDraft() throws -> Draft? {
        let url = directory.appendingPathComponent("draft.json")
        guard files.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
    }

    func saveDraft(_ draft: Draft) throws {
        guard ownsFiles else { return }
        if draft.text.isEmpty { try remove("draft.json") }
        else { try write(draft, name: "draft.json") }
    }

    /// Return intact records even if one cannot be read. The unreadable file is never removed.
    func loadEdits() throws -> (edits: [NoteSaver.Snapshot], unreadable: Bool) {
        guard files.fileExists(atPath: directory.path) else { return ([], false) }
        let urls = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("edit-") && $0.pathExtension == "json" }
        var edits: [NoteSaver.Snapshot] = []
        var unreadable = false
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do { edits.append(try JSONDecoder().decode(NoteSaver.Snapshot.self, from: Data(contentsOf: url))) }
            catch { unreadable = true }
        }
        return (edits, unreadable)
    }

    func save(_ snapshot: NoteSaver.Snapshot) throws { try write(snapshot, name: name(snapshot.id)) }
    func removeEdit(_ id: UUID) throws { try remove(name(id)) }
    func removeAll() throws {
        guard ownsFiles else { return }
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
    }

    private func name(_ id: UUID) -> String { "edit-\(id.uuidString).json" }
    private func remove(_ name: String) throws {
        guard ownsFiles else { return }
        let url = directory.appendingPathComponent(name)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }
    private func write(_ value: some Encodable, name: String) throws {
        guard ownsFiles else { return }
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
