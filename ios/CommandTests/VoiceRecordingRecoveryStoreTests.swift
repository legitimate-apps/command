import XCTest
@testable import Command

@MainActor
final class VoiceRecordingRecoveryStoreTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func store(server: String = "https://example.com", id: Int = 1, created: String = "first") -> VoiceRecordingRecoveryStore {
        VoiceRecordingRecoveryStore(root: root.appendingPathComponent("recovery"), server: URL(string: server)!,
                                    accountID: id, username: "tester", accountCreatedAt: created)
    }
    private func source() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("source.m4a")
        try Data("opaque audio fixture".utf8).write(to: url)
        return url
    }
    func testStoredCopySurvivesSourceRemovalAndFreshStore() throws {
        let original = try source(), owner = store()
        let record = try owner.keep(original, id: UUID())
        try FileManager.default.removeItem(at: original)
        let restarted = store(), recovered = try XCTUnwrap(restarted.recordings().first)
        XCTAssertEqual(record.id, recovered.id)
        XCTAssertEqual(try Data(contentsOf: restarted.audioURL(for: recovered)), Data("opaque audio fixture".utf8))
    }
    func testAccountServerAndRecreatedAccountCannotDiscoverAudio() throws {
        _ = try store().keep(source(), id: UUID())
        XCTAssertTrue(try store(id: 2).recordings().isEmpty)
        XCTAssertTrue(try store(server: "https://other.example.com").recordings().isEmpty)
        XCTAssertTrue(try store(created: "recreated").recordings().isEmpty)
        XCTAssertEqual(try store().recordings().count, 1)
    }
    func testDiscardDoesNotResurrectAndRemovesOwnedAudio() throws {
        let owner = store(), record = try owner.keep(source(), id: UUID())
        let audio = try owner.audioURL(for: record)
        try owner.discard(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(try store().recordings().isEmpty)
        try owner.discard(record.id)
    }
    func testCorruptManifestIsReportedAndKept() throws {
        let owner = store(), record = try owner.keep(source(), id: UUID())
        let manifest = owner.directory.appendingPathComponent(record.id.uuidString).appendingPathComponent("manifest.json")
        try Data("broken".utf8).write(to: manifest)
        XCTAssertThrowsError(try owner.recordings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertNoThrow(try owner.audioURL(for: record))
    }
    func testFailedCopyDoesNotPublishRecoveryAndKeepsSource() throws {
        let owner = store(), original = try source(), id = UUID()
        _ = try owner.keep(original, id: id)
        XCTAssertThrowsError(try owner.keep(original, id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try owner.recordings().count, 1)
    }
    func testManifestCannotReferenceAnOutsideFile() throws {
        let owner = store()
        XCTAssertThrowsError(try owner.audioURL(for: .init(version: 1, id: UUID(), filename: "../../outside.m4a")))
    }
}
