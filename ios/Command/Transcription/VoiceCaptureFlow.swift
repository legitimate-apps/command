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
    var transcript = "" {
        didSet {
            if transcript != oldValue {
                reviewRevision = UUID()
                noteCreate.reset()
            }
        }
    }
    /// Changes whenever another capture replaces this one, even if it reuses a file URL.
    private(set) var captureID = UUID()
    private var reviewRevision = UUID()
    private var transcriptionAttempt = UUID()
    private var noteCreate = CreateAttempt()
    private struct NotePayload: Encodable { let text: String; let engine: String }
    private(set) var engineUsed = ""
    var errorMessage: String?
    /// The last transcription attempt failed (the recording is still kept for another attempt).
    private(set) var transcriptionFailed = false
    private(set) var saving = false
    private(set) var isCancelled = false

    private let removeFile: (URL) -> Void
    private let recovery: VoiceRecordingRecoveryStore?
    private var recoveredRecordingID: UUID?

    init(recovery: VoiceRecordingRecoveryStore? = nil,
         restoring recording: VoiceRecordingRecoveryStore.Recording? = nil,
         removeFile: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
        self.removeFile = removeFile
        self.recovery = recovery
        if let recovery, let recording {
            do {
                audioURL = try recovery.audioURL(for: recording)
                captureID = recording.id
                recoveredRecordingID = recording.id
            } catch { errorMessage = "Couldn't reopen the saved recording. Its files have been kept." }
        }
    }

    /// A new recording is starting: drop the previous one and any leftover review state.
    func reset() {
        guard discardAudio() else { return }
        captureID = UUID()
        noteCreate.reset()
        transcript = ""
        engineUsed = ""
        errorMessage = nil
        transcriptionFailed = false
        isCancelled = false
    }

    /// A permission prompt can outlive the sheet. Nil means the caller must not start recording
    /// or change its UI because this capture was cancelled or replaced while the prompt was up.
    func requestPermission(using request: () async -> Bool) async -> Bool? {
        guard !isCancelled, !Task.isCancelled else { return nil }
        let capture = captureID
        let granted = await request()
        guard !isCancelled, !Task.isCancelled, captureID == capture else { return nil }
        return granted
    }

    /// The recorder finished; keep its file for transcription (and any retry of it).
    func adopt(_ url: URL) {
        guard audioURL != url else { return }
        guard discardAudio() else { return }
        captureID = UUID()
        noteCreate.reset()
        audioURL = url
        if let recovery {
            do {
                let record = try recovery.keep(url, id: captureID)
                audioURL = try recovery.audioURL(for: record)
                recoveredRecordingID = record.id
                removeFile(url) // ownership transferred only after durable metadata publication
            } catch {
                errorMessage = "Couldn't keep a recovery copy of this recording. Keep Command open."
            }
        }
    }

    /// Transcribe the kept recording. Returns the cleaned transcript when `immediateUse` applies
    /// and it is usable — the caller hands it on and closes (the audio is released here, since the
    /// words are committed). Returns nil to show the review step, or when the flow was cancelled
    /// while transcribing (the result is dropped; nothing is handed on).
    func transcribe(immediateUse: Bool,
                    using transcribe: (URL) async throws -> (text: String, engine: String)) async -> String? {
        guard let url = audioURL, !isCancelled, !Task.isCancelled else { return nil }
        let capture = captureID, revision = reviewRevision
        let attempt = UUID()
        transcriptionAttempt = attempt
        do {
            let result = try await transcribe(url)
            guard !isCancelled, !Task.isCancelled, captureID == capture,
                  reviewRevision == revision, transcriptionAttempt == attempt else { return nil }
            transcript = result.text
            engineUsed = result.engine
            errorMessage = nil
            transcriptionFailed = false
            if immediateUse, let cleaned = try? VoiceInputValidator.cleaned(result.text) {
                discardAudio()
                return cleaned
            }
        } catch {
            guard !isCancelled, !Task.isCancelled, captureID == capture,
                  reviewRevision == revision, transcriptionAttempt == attempt else { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            transcriptionFailed = true
        }
        return nil
    }

    /// Save the reviewed transcript. Returns true only when the current review was committed and
    /// may close. Completion of an older save must not discard newer edits or another recording.
    /// A failed current save keeps the recording and shows the error for retry.
    func saveNote(using save: (_ text: String, _ engine: String, _ key: String) async -> String?) async -> Bool {
        guard !saving, !isCancelled, !Task.isCancelled else { return false }
        let capture = captureID, revision = reviewRevision
        let text = transcript
        saving = true
        defer { saving = false }
        do {
            let engine = engineUsed.isEmpty ? "sfspeech" : engineUsed
            let key = try noteCreate.key(for: NotePayload(text: text, engine: engine))
            let failure = await save(text, engine, key)
            guard !isCancelled, !Task.isCancelled, captureID == capture,
                  reviewRevision == revision else { return false }
            if let failure {
                errorMessage = failure
                return false
            }
            noteCreate.succeeded(key: key)
            errorMessage = nil
            discardAudio()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// The transcript was handed to the caller from review: the words are committed.
    func committedToCaller() { discardAudio() }

    /// The user cancelled (or the sheet went away): drop the recording and suppress any in-flight
    /// transcription's result.
    func cancel() {
        captureID = UUID()
        isCancelled = true
        discardAudio()
    }

    @discardableResult
    private func discardAudio() -> Bool {
        if let recoveredRecordingID, let recovery {
            do { try recovery.discard(recoveredRecordingID) }
            catch {
                errorMessage = "Couldn't remove the saved recording. Its cleanup can be retried."
                return false
            }
        }
        if let url = audioURL { removeFile(url) }
        audioURL = nil
        recoveredRecordingID = nil
        return true
    }
}
