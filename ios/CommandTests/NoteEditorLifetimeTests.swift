import SwiftUI
import XCTest
@testable import Command

private final class EditorWireProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var creates = 0
    nonisolated(unsafe) static var patches = 0
    nonisolated(unsafe) static var holdClose = false
    nonisolated(unsafe) static var closing: [EditorWireProtocol] = []
    static var hasHeldClose: Bool { lock.lock(); defer { lock.unlock() }; return !closing.isEmpty }
    static func releaseClose() {
        lock.lock(); holdClose = false; let held = closing; closing = []; lock.unlock()
        held.forEach { $0.respond(closed: true) }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "note-ui.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        if request.url?.path == "/api/notes", request.httpMethod == "POST" { Self.creates += 1 }
        if request.httpMethod == "PATCH" { Self.patches += 1 }
        if request.url?.path.hasSuffix("/close") == true, Self.holdClose {
            Self.closing.append(self); Self.lock.unlock(); return
        }
        Self.lock.unlock()
        respond(closed: request.url?.path.hasSuffix("/close") == true)
    }
    private func respond(closed: Bool) {
        let data: Data
        if request.url?.path == "/api/attachments" { data = Data("[]".utf8) }
        else {
            data = Data("""
            {"id":42,"account_id":1,"body":"Prefix","title":"\(closed ? "Closed" : "Prefix")","title_status":"user",
            "source":"typed","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}
            """.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                           httpVersion: nil, headerFields: ["Content-Type":"application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Observable
private final class EditorPresentation {
    var shown = false
    var generation = 0
    let saver = NoteSaver(noteId: nil, text: "")
}

private struct EditorHarness: View {
    let presentation: EditorPresentation
    var body: some View {
        Text("Editor lifetime test")
            .sheet(isPresented: Bindable(presentation).shown) {
                NoteDetailView(session: presentation.saver).id(presentation.generation)
            }
    }
}

@MainActor
@Observable
private final class BlockingSheetPresentation {
    var existing = false
    let composer = NoteComposer()
}

private struct BlockingSheetHarness: View {
    let presentation: BlockingSheetPresentation
    var body: some View {
        Text("Presentation test")
            .sheet(isPresented: Bindable(presentation).existing) {
                NoteDetailView(note: try! JSONDecoder().decode(Note.self, from: Data("""
                {"id":42,"accountId":1,"body":"Existing","title":"Existing","titleStatus":"user",
                "source":"typed","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z"}
                """.utf8))).macSheet(.page)
            }
            .noteComposerHost()
            .environment(presentation.composer)
    }
}

@MainActor
final class NoteEditorLifetimeTests: XCTestCase {
    private func wait(until predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    private func textView(in view: UIView?) -> UITextView? {
        guard let view else { return nil }
        if let text = view as? UITextView { return text }
        for child in view.subviews { if let text = textView(in: child) { return text } }
        return nil
    }

    func testNewNoteFromExistingSheetPresentsAndCanBeOpenedAgain() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EditorWireProtocol.self]
        let app = AppState(client: APIClient(baseURL: URL(string: "https://note-ui.invalid")!, configuration: config))
        let presentation = BlockingSheetPresentation()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: BlockingSheetHarness(presentation: presentation).environment(app))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        await wait { host.view.window != nil }
        presentation.existing = true
        await wait { self.textView(in: host.presentedViewController?.view) != nil }
        let existing = try XCTUnwrap(host.presentedViewController)
        XCTAssertEqual(textView(in: existing.view)?.text, "Existing")
        presentation.composer.begin() // the exact New Note model intent used by the keyboard
        await wait { existing.presentedViewController != nil }
        let compose = try XCTUnwrap(existing.presentedViewController, "New Note must present above the existing sheet")
        await wait { self.textView(in: compose.view) != nil }
        XCTAssertEqual(textView(in: compose.view)?.text, "")
        presentation.composer.session = nil
        await wait { existing.presentedViewController == nil }
        XCTAssertTrue(presentation.existing)
        presentation.existing = false
        await wait { host.presentedViewController == nil }
        presentation.composer.begin()
        await wait { self.textView(in: host.presentedViewController?.view) != nil }
        XCTAssertNotNil(textView(in: host.presentedViewController?.view), "dismissal must not leave a stuck session")
        presentation.composer.session = nil
        await wait { host.presentedViewController == nil }
    }

    /// Force a real SwiftUI identity replacement after the first create. The replacement must
    /// share the saver (including its id), and the outgoing view must not dismiss the new one
    /// when its asynchronous disappearance save completes.
    func testRebuildingEditorKeepsCreatedNoteAndDoesNotDismissReplacement() async throws {
        EditorWireProtocol.lock.lock(); EditorWireProtocol.creates = 0; EditorWireProtocol.patches = 0
        EditorWireProtocol.closing = []; EditorWireProtocol.holdClose = false
        EditorWireProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EditorWireProtocol.self]
        let app = AppState(client: APIClient(baseURL: URL(string: "https://note-ui.invalid")!, configuration: config))
        let presentation = EditorPresentation()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: EditorHarness(presentation: presentation).environment(app))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        await wait { host.view.window != nil }
        presentation.shown = true
        await wait { self.textView(in: host.presentedViewController?.view) != nil }
        let first = try XCTUnwrap(textView(in: host.presentedViewController?.view))
        first.text = "Prefix"
        first.delegate?.textViewDidChange?(first)
        await wait { presentation.saver.noteId != nil }
        XCTAssertEqual(presentation.saver.noteId, 42)

        EditorWireProtocol.lock.lock(); EditorWireProtocol.holdClose = true; EditorWireProtocol.lock.unlock()
        presentation.generation += 1
        await wait { self.textView(in: host.presentedViewController?.view) !== first }
        await wait { EditorWireProtocol.hasHeldClose }
        XCTAssertTrue(EditorWireProtocol.hasHeldClose, "the outgoing editor is parked at close")
        EditorWireProtocol.releaseClose()
        await wait { app.notes.notes.first?.title == "Closed" }
        XCTAssertEqual(app.notes.notes.first?.title, "Closed", "the outgoing close must have completed")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(presentation.shown)
        let replacement = try XCTUnwrap(textView(in: host.presentedViewController?.view))
        XCTAssertFalse(replacement === first)
        XCTAssertEqual(replacement.text, "Prefix")
        replacement.text = "Prefix continued"
        replacement.delegate?.textViewDidChange?(replacement)
        await wait { presentation.saver.lastSavedText == "Prefix continued" }
        XCTAssertEqual(presentation.saver.lastSavedText, "Prefix continued")
        XCTAssertEqual(EditorWireProtocol.creates, 1)
        XCTAssertEqual(EditorWireProtocol.patches, 1)
        presentation.shown = false
        await wait { host.presentedViewController == nil }
    }
}
