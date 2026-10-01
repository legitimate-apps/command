import Foundation
import Observation
import SwiftUI

/// One compose session per window. The shell owns this above its tab/split branches; leaf view
/// reconstruction and repeated New Note intents reuse the same text, id and in-flight save.
@MainActor
@Observable
final class NoteComposer {
    var session: NoteSaver?
    private var hosts: [UUID] = []
    private var presenter: UUID?
    private var visibleSession: UUID?

    func begin() {
        guard session == nil else { return }
        session = NoteSaver(noteId: nil, text: "")
        visibleSession = nil
        presenter = hosts.last
    }

    /// Sheet content registers above the shell. Pick the topmost available host before showing
    /// a new session, then keep that presenter fixed while its editor is visible.
    func mountHost(_ id: UUID) {
        hosts.removeAll { $0 == id }; hosts.append(id)
        if session != nil && visibleSession == nil { presenter = hosts.last }
    }

    func unmountHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
        if presenter == id {
            presenter = hosts.last
            visibleSession = nil
        }
    }

    func session(for host: UUID) -> NoteSaver? { presenter == host ? session : nil }
    func didPresent(_ sessionID: UUID, from host: UUID) {
        if presenter == host && session?.id == sessionID { visibleSession = sessionID }
    }
    /// A system-owned picker may block even the newest app host. An empty request that never
    /// appeared can be abandoned safely, so subsequent New Note actions cannot get stuck.
    func abandonUnpresented(_ sessionID: UUID, from host: UUID) {
        guard visibleSession != sessionID, let session, session.id == sessionID,
              session.noteId == nil, session.text.isEmpty else { return }
        dismiss(sessionID, from: host)
    }

    func dismiss(_ sessionID: UUID, from host: UUID) {
        guard presenter == host && session?.id == sessionID else { return }
        session = nil; visibleSession = nil; presenter = nil
    }
}

/// A list refresh is not a navigation action. Keep the selected note's last known value until
/// the user changes selection, even if a server search temporarily stops returning its row.
@MainActor
@Observable
final class NoteSelection {
    private(set) var note: Note?

    func receive(_ note: Note?) {
        if let note { self.note = note }
    }
}


extension View {
    /// Mount beside the shell and inside sheet content so New Note always has a free presenter.
    func noteComposerHost(enabled: Bool = true) -> some View {
        modifier(NoteComposerHost(enabled: enabled))
    }
}

private struct NoteComposerHost: ViewModifier {
    @Environment(NoteComposer.self) private var composer: NoteComposer?
    @State private var id = UUID()
    let enabled: Bool

    func body(content: Content) -> some View {
        let presented = enabled ? composer?.session(for: id) : nil
        content
            .onAppear { if enabled { composer?.mountHost(id) } }
            .onDisappear { if enabled { composer?.unmountHost(id) } }
            .task(id: presented?.id) {
                guard let presented else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                composer?.abandonUnpresented(presented.id, from: id)
            }
            .sheet(item: Binding(
                get: { enabled ? composer?.session(for: id) : nil },
                set: { if $0 == nil, let presented { composer?.dismiss(presented.id, from: id) } }
            )) { session in
                // The composer must not become its own presenter when sheet content mounts.
                NoteDetailView(session: session).macSheet(.page, hostsComposer: false)
                    .privacyChallenge()
                    .onAppear { composer?.didPresent(session.id, from: id) }
            }
    }
}
