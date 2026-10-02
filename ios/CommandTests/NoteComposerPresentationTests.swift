import XCTest
@testable import Command

@MainActor
final class NoteComposerPresentationTests: XCTestCase {
    func testTopSheetOwnsPresentationAndStaleDismissCannotLoseSession() throws {
        let composer = NoteComposer(), root = UUID(), sheet = UUID(), replacement = UUID()
        composer.mountHost(root); composer.mountHost(sheet); composer.begin()
        let session = try XCTUnwrap(composer.session(for: sheet))
        XCTAssertNil(composer.session(for: root))
        composer.didPresent(session.id, from: sheet)
        composer.mountHost(replacement)
        XCTAssertTrue(composer.session(for: sheet) === session, "a visible presenter stays fixed")
        composer.unmountHost(sheet)
        composer.dismiss(session.id, from: sheet)
        XCTAssertTrue(composer.session(for: replacement) === session, "the session outlives its old presenter")
        composer.dismiss(session.id, from: replacement)
        XCTAssertNil(composer.session)
    }

    func testBlockedEmptyRequestCanExpireAndNextIntentStartsFresh() throws {
        let composer = NoteComposer(), host = UUID()
        composer.mountHost(host); composer.begin()
        let first = try XCTUnwrap(composer.session)
        composer.abandonUnpresented(first.id, from: host)
        XCTAssertNil(composer.session)
        composer.begin()
        XCTAssertNotEqual(composer.session?.id, first.id)
    }

    func testExpiryNeverDropsVisibleOrPopulatedSession() throws {
        let composer = NoteComposer(), host = UUID()
        composer.mountHost(host); composer.begin()
        let session = try XCTUnwrap(composer.session)
        session.text = "Kept text"
        composer.abandonUnpresented(session.id, from: host)
        XCTAssertTrue(composer.session === session)
        session.text = ""
        composer.didPresent(session.id, from: host)
        composer.abandonUnpresented(session.id, from: host)
        XCTAssertTrue(composer.session === session)
    }
}
