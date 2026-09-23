//
//  ParakeetEngine.swift
//  Command
//
//  Tier 1: NVIDIA Parakeet v3 via FluidAudio. File-based, fully on-device, 25
//  languages. Only included in the router when the model is downloaded.
//

import FluidAudio
import Foundation

struct ParakeetEngine: TranscriptionEngine {
    let id = "parakeet-v3"
    let displayName = "Parakeet v3"
    let store: ParakeetModelStore

    func transcribe(fileURL: URL, locale: String?) async throws -> String {
        guard let manager = await store.ensureManager() else { throw TranscriptionError.unavailable }
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(fileURL, decoderState: &decoderState, language: nil)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.empty }
        return text
    }
}
