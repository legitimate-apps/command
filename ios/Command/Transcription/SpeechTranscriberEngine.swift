//
//  SpeechTranscriberEngine.swift
//  Command
//
//  Tier 2: iOS 26 SpeechAnalyzer + SpeechTranscriber — on-device, OS-managed
//  model assets, broad locale coverage (incl. CJK/Arabic that Parakeet lacks).
//  API per Apple WWDC25 + SDK headers.
//

import AVFoundation
import Foundation
import Speech

@available(iOS 26.0, *)
struct SpeechTranscriberEngine: TranscriptionEngine {
    let id = "speechtranscriber"
    let displayName = "On-device Speech"

    func transcribe(fileURL: URL, locale: String?) async throws -> String {
        let chosenLocale = locale.map { Locale(identifier: $0) } ?? Locale.current
        let transcriber = SpeechTranscriber(locale: chosenLocale, preset: .transcription)

        // Make sure the on-device model for this locale is installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect transcript text concurrently while the file is analyzed.
        async let collected = transcriber.results.reduce(into: AttributedString()) { $0 += $1.text }

        let file = try AVAudioFile(forReading: fileURL)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = String(try await collected.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.empty }
        return text
    }
}
