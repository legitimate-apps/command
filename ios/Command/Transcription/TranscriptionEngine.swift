//
//  TranscriptionEngine.swift
//  Command
//
//  A transcription "tier". The router (TranscriptionService) tries engines in
//  priority order — Parakeet v3 → iOS 26 SpeechTranscriber → SFSpeechRecognizer.
//

import Foundation

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case unavailable
    case empty

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition isn't enabled. Turn it on in Settings → Command."
        case .unavailable: return "No transcription engine is available right now."
        case .empty: return "Didn't catch any words — give it another try."
        }
    }
}

/// Resume-once, thread-safe wrapper — recognition callbacks fire on arbitrary
/// queues and may be called multiple times.
final class ContinuationBox<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
    func resume(throwing error: Error) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}

protocol TranscriptionEngine {
    /// Stable id stored as the note's `engine` field.
    var id: String { get }
    var displayName: String { get }
    /// Transcribe an already-recorded audio file. `locale` is a BCP-47 hint.
    func transcribe(fileURL: URL, locale: String?) async throws -> String
}
