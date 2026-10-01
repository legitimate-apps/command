import Foundation
import Observation

/// One compose session per window. The shell owns this above its tab/split branches; leaf view
/// reconstruction and repeated New Note intents reuse the same text, id and in-flight save.
@MainActor
@Observable
final class NoteComposer {
    var session: NoteSaver?

    func begin() {
        guard session == nil else { return }
        session = NoteSaver(noteId: nil, text: "")
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
