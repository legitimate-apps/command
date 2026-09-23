//
//  SFSpeechEngine.swift
//  Command
//
//  Universal fallback (iOS 13+). On-device where the locale supports it, else
//  Apple's server path. Always available, so it anchors the tier list.
//

import Foundation
import Speech

struct SFSpeechEngine: TranscriptionEngine {
    let id = "sfspeech"
    let displayName = "Apple Speech"

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func transcribe(fileURL: URL, locale: String?) async throws -> String {
        guard await Self.requestAuthorization() == .authorized else { throw TranscriptionError.notAuthorized }

        let recognizer = locale.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) } ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { throw TranscriptionError.unavailable }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let text: String = try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error { box.resume(throwing: error); return }
                if let result, result.isFinal {
                    box.resume(returning: result.bestTranscription.formattedString)
                }
            }
            // Watchdog: an SFSpeechRecognitionTask can stall silently — end with neither a final
            // result nor an error (recognizer becomes unavailable, task interrupted). Without this
            // the continuation never resumes and, as the anchor tier, the whole transcribe() call
            // (and the "Transcribing…" UI) hangs forever. ContinuationBox makes the first resume win.
            Task {
                try? await Task.sleep(for: .seconds(45))
                box.resume(throwing: TranscriptionError.unavailable)
                task.cancel()
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.empty }
        return trimmed
    }
}
