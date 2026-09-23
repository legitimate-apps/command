//
//  TranscriptionService.swift
//  Command
//
//  The tiered router. Engine order: Parakeet v3 (when downloaded) → iOS 26
//  SpeechTranscriber → SFSpeechRecognizer (universal). Tries each in turn and
//  returns the first success.
//

import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionService {
    let parakeet = ParakeetModelStore()
    private(set) var engines: [TranscriptionEngine] = [SFSpeechEngine()]

    /// Call once at launch: check the Parakeet model and assemble the tier list.
    func configure() {
        parakeet.refresh()
        rebuild()
    }

    func rebuild() {
        var list: [TranscriptionEngine] = []
        if parakeet.state.isReady { list.append(ParakeetEngine(store: parakeet)) }
        if #available(iOS 26.0, *) { list.append(SpeechTranscriberEngine()) }
        list.append(SFSpeechEngine())
        engines = list
    }

    func downloadParakeet() async {
        await parakeet.download()
        rebuild()
    }

    func deleteParakeet() {
        parakeet.delete()
        rebuild()
    }

    var activeEngineName: String { engines.first?.displayName ?? "—" }

    /// Transcribe via the first engine that succeeds. Returns (text, engineId).
    func transcribe(fileURL: URL, locale: String? = nil) async throws -> (text: String, engine: String) {
        var lastError: Error = TranscriptionError.unavailable
        for engine in engines {
            do {
                let text = try await engine.transcribe(fileURL: fileURL, locale: locale)
                return (text, engine.id)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
