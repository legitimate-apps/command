//
//  AudioRecorder.swift
//  Command
//
//  Records a voice note to a 16 kHz mono m4a (good for on-device ASR) and
//  publishes a live level + elapsed time for the recording UI.
//

import AVFoundation
import Observation

enum AudioRecorderError: LocalizedError {
    case couldNotStart
    var errorDescription: String? { "Couldn't start recording — the microphone may be unavailable." }
}

@MainActor
@Observable
final class AudioRecorder {
    var isRecording = false
    var level: CGFloat = 0
    var elapsed: TimeInterval = 0

    /// The system cut the recording short — an incoming call, Siri, or another app taking the
    /// microphone. The audio captured up to that point is still usable, but it is *truncated*,
    /// and the user has to be told: transcribing it silently drops whatever they said after the
    /// interruption and looks exactly like the transcriber mishearing them.
    private(set) var wasInterrupted = false

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startedAt: Date?
    private var meterTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    /// Ask for microphone permission (iOS 17 API). Returns true if granted.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    @discardableResult
    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-note-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        // record() can fail (session interruption / route conflict) and returns false. Ignoring it
        // left isRecording = true with silent metering, so the pipeline handed an empty file to the
        // transcriber and surfaced only a generic "empty" error. Fail loudly instead.
        guard rec.record() else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioRecorderError.couldNotStart
        }

        recorder = rec
        fileURL = url
        startedAt = Date()
        isRecording = true
        wasInterrupted = false
        level = 0
        elapsed = 0
        startMetering()
        observeInterruptions()
        return url
    }

    /// End the recording cleanly when the system takes the microphone away.
    ///
    /// Without this the recorder was paused by the system while `isRecording` stayed true: the
    /// meter task went on polling a stopped recorder, so the level pinned to zero while the timer
    /// kept climbing, and Stop then transcribed a truncated file with nothing to indicate the
    /// recording had ended early.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            // Delivered on .main, so main-actor state is safe to touch here.
            MainActor.assumeIsolated { self?.stopBecauseInterrupted() }
        }
    }

    /// End the recording and mark it truncated, keeping whatever was captured.
    ///
    /// Shared by the audio-session interruption observer and by the app being backgrounded.
    /// Backgrounding needs its own trigger: iOS suspends the app *without* posting an
    /// interruption (there is no `UIBackgroundModes: audio` here, deliberately — this is
    /// push-to-record capture, not a background recorder), so the observer alone would miss it
    /// and leave exactly the same silently-truncated file.
    @discardableResult
    func stopBecauseInterrupted() -> URL? {
        guard isRecording else { return fileURL }
        wasInterrupted = true
        return stop()
    }

    /// Stop and return the recorded file (nil if nothing was recorded).
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return fileURL }
        isRecording = false
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return fileURL
    }

    /// Stop and discard the recording.
    func cancel() {
        _ = stop()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
    }

    private func startMetering() {
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let rec = self.recorder else { break }
                rec.updateMeters()
                // averagePower is dBFS (-160…0); map roughly -50…0 → 0…1.
                let normalized = max(0, min(1, (rec.averagePower(forChannel: 0) + 50) / 50))
                self.level = CGFloat(normalized)
                if let started = self.startedAt { self.elapsed = Date().timeIntervalSince(started) }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }
}
