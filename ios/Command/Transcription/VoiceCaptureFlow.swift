//
//  VoiceCaptureFlow.swift
//  Command
//
//  The recording sheet's post-recording state machine, split out of RecordingSheet so its
//  data-safety rules are testable without a microphone:
//   - The recording is KEPT until its words are committed (a note saved, or the transcript handed
//     to the caller). A failed transcription or a failed save leaves it on disk, so the user can
//     transcribe again or retry the save instead of re-speaking the whole thing.
//   - Cancel wins. Cancelling while a transcription is in flight means its result is thrown away —
//     it must never reach `onUse`, which may send a paid assistant turn.
//

import Foundation
import Observation

@MainActor
@Observable
final class VoiceCaptureFlow {
    /// The finished recording, kept until it's committed or discarded.
    private(set) var audioURL: URL?
    var transcript = ""
    private(set) var engineUsed = ""
    var errorMessage: String?
    /// The last transcription attempt failed (the recording is still kept for another attempt).
    private(set) var transcriptionFailed = false
    private(set) var saving = false
    private(set) var isCancelled = false

    private let removeFile: (URL) -> Void

    init(removeFile: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
        self.removeFile = removeFile
    }

    /// A new recording is starting: drop the previous one and any leftover review state.
    func reset() {
        discardAudio()
        transcript = ""
        engineUsed = ""
        errorMessage = nil
        transcriptionFailed = false
        isCancelled = false
    }

    /// The recorder finished; keep its file for transcription (and any retry of it).
    func adopt(_ url: URL) {
        if let old = audioURL, old != url { removeFile(old) }
        audioURL = url
    }

    /// Transcribe the kept recording. Returns the cleaned transcript when `immediateUse` applies
    /// and it is usable — the caller hands it on and closes (the audio is released here, since the
    /// words are committed). Returns nil to show the review step, or when the flow was cancelled
    /// while transcribing (the result is dropped; nothing is handed on).
    func transcribe(immediateUse: Bool,
                    using transcribe: (URL) async throws -> (text: String, engine: String)) async -> String? {
        guard let url = audioURL, !isCancelled else { return nil }
        do {
            let result = try await transcribe(url)
            guard !isCancelled else { return nil }
            transcript = result.text
            engineUsed = result.engine
            errorMessage = nil
            transcriptionFailed = false
            if immediateUse, let cleaned = try? VoiceInputValidator.cleaned(result.text) {
                discardAudio()
                return cleaned
            }
        } catch {
            guard !isCancelled else { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            transcriptionFailed = true
        }
        return nil
    }

    /// Save the reviewed transcript as a note via `save` (true on success). The recording is
    /// released only once the note is committed; on failure it's kept and the error shown.
    func saveNote(using save: (_ text: String, _ engine: String) async -> String?) async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        if let failure = await save(transcript, engineUsed.isEmpty ? "sfspeech" : engineUsed) {
            errorMessage = failure
            return false
        }
        errorMessage = nil
        discardAudio()
        return true
    }

    /// The transcript was handed to the caller from review: the words are committed.
    func committedToCaller() { discardAudio() }

    /// The user cancelled (or the sheet went away): drop the recording and suppress any in-flight
    /// transcription's result.
    func cancel() {
        isCancelled = true
        discardAudio()
    }

    private func discardAudio() {
        if let url = audioURL { removeFile(url) }
        audioURL = nil
    }
}
