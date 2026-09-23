//
//  RecordingSheet.swift
//  Command
//
//  Voice capture flow: permission → record (live level + timer) → transcribe →
//  editable review → save as a voice note. Self-contained; presented from the
//  capture bar's mic.
//

import SwiftUI
import AVFAudio

struct RecordingSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// When set, the review step hands the transcript back here (e.g. into the Assistant's
    /// input) instead of saving a voice note. `nil` keeps the original save-a-note behaviour.
    var onUse: ((String) -> Void)? = nil
    var requiresPreparedPermission = false
    var useImmediatelyAfterTranscription = false

    @State private var recorder = AudioRecorder()
    @State private var phase: Phase = .preparing
    /// Transcript, kept recording, and the save/cancel rules around them. See VoiceCaptureFlow.
    @State private var flow = VoiceCaptureFlow()
    /// Why the microphone couldn't start (busy, route conflict) — distinct from a permission denial.
    @State private var startFailure: String?

    enum Phase { case preparing, permissionPreparation, recording, transcribing, review, denied, startFailed }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                content.padding(28)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
            }
            // Also hold the sheet while review shows an error: the kept recording and the typed
            // transcript would go with a stray swipe. Cancel stays the explicit way out.
            .interactiveDismissDisabled(phase == .recording || phase == .transcribing
                                        || (phase == .review && flow.errorMessage != nil))
            .task { await begin() }
            // However the sheet goes away, release the recording and void any in-flight transcription.
            .onDisappear { recorder.cancel(); flow.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            ProgressView("Preparing…").controlSize(.large)
        case .permissionPreparation:
            permissionPreparationView
        case .denied:
            deniedView
        case .startFailed:
            startFailedView
        case .recording:
            recordingView
        case .transcribing:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Transcribing…").foregroundStyle(Palette.inkSecondary)
            }
        case .review:
            reviewView
        }
    }

    private var permissionPreparationView: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.badge.plus").font(.system(size: 44)).foregroundStyle(Palette.accent)
            Text("Enable voice capture").font(Typeface.display(22)).foregroundStyle(Palette.ink)
            Text("Command needs microphone access to listen, transcribe on this device, and send your words to the assistant. Recording starts only after you continue.")
                .font(.system(size: 15)).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            Button("Enable Voice Capture") { Task { await requestPreparedPermission() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var recordingView: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().fill(Palette.accentSoft)
                    .frame(width: 180, height: 180)
                    .scaleEffect(1 + recorder.level * 0.35)
                    .animation(.easeOut(duration: 0.08), value: recorder.level)
                Circle().fill(Palette.accent).frame(width: 96, height: 96)
                Image(systemName: "mic.fill").font(.system(size: 38)).foregroundStyle(.white)
            }
            Text(timeString(recorder.elapsed))
                .font(.system(size: 34, weight: .light, design: .monospaced))
                .foregroundStyle(Palette.ink)
            Text("Listening — speak your note").foregroundStyle(Palette.inkSecondary)
            Spacer()
            Button { Task { await stopAndTranscribe() } } label: {
                Label("Stop & transcribe", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        // A call, Siri, or another app taking the microphone ends the recording underneath us.
        // Without this the sheet went on showing a live-looking recording screen — climbing
        // timer, dead level meter — until the user pressed Stop, which then transcribed a
        // truncated file. Move straight to transcribing what was actually captured.
        .onChange(of: recorder.isRecording) { _, recording in
            guard !recording, phase == .recording else { return }
            Task { await stopAndTranscribe() }
        }
        // Backgrounding is the same loss by a different route, and it posts no interruption —
        // iOS just suspends us (there is no `UIBackgroundModes: audio`, deliberately). Without
        // this the recording died on the way to the background and came back as a truncated
        // file the user had no reason to distrust. `.inactive` is deliberately not treated as
        // an interruption: the notification shade and the app switcher pass through it.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background, phase == .recording else { return }
            recorder.stopBecauseInterrupted()
        }
    }

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(onUse != nil ? "Dictation" : "Your note").font(Typeface.display(24)).foregroundStyle(Palette.ink)
            if let err = flow.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            // The recording is kept after a failed transcription, so it can be tried again
            // instead of re-spoken.
            if flow.transcriptionFailed, flow.audioURL != nil {
                Button("Transcribe again") { Task { await transcribeKeptRecording() } }
                    .font(.footnote.weight(.semibold))
            }
            // Say so explicitly. A truncated transcript is indistinguishable from the
            // transcriber simply mishearing the end of a sentence, and the user would have no
            // reason to suspect the recording stopped early.
            if recorder.wasInterrupted {
                Label("Recording stopped early — a call or another app took the microphone. This is what was captured up to that point.",
                      systemImage: "phone.arrow.down.left")
                    .font(.footnote).foregroundStyle(.orange)
            }
            TextField("Transcribed text", text: $flow.transcript, axis: .vertical)
                .lineLimit(4...12)
                .font(.system(size: 17))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(cornerRadius: 16)
            if !flow.engineUsed.isEmpty {
                Text("Transcribed with \(engineLabel(flow.engineUsed))")
                    .font(.caption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button(action: commit) {
                HStack { if flow.saving { ProgressView().tint(.white) }; Text(onUse != nil ? "Use" : "Save note") }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(flow.transcript.trimmingCharacters(in: .whitespaces).isEmpty || flow.saving)
            Button("Record again") { Task { await begin() } }
                .frame(maxWidth: .infinity)
        }
    }

    /// Hand the transcript to the caller (Assistant input) when provided; otherwise save a note.
    private func commit() {
        if let onUse {
            onUse(flow.transcript)
            flow.committedToCaller()
            dismiss()
        } else {
            save()
        }
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash").font(.system(size: 44)).foregroundStyle(Palette.inkSecondary)
            Text("Microphone access needed").font(Typeface.display(20)).foregroundStyle(Palette.ink)
            Text("Enable Microphone and Speech Recognition for Command in Settings to dictate notes.")
                .font(.system(size: 15)).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url).buttonStyle(.borderedProminent)
            }
        }
    }

    /// A mic that won't start (another app holds it, a route conflict) is not a permission problem:
    /// say what happened and offer Retry, rather than sending the user to Settings.
    private var startFailedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash").font(.system(size: 44)).foregroundStyle(Palette.inkSecondary)
            Text("Couldn't start recording").font(Typeface.display(20)).foregroundStyle(Palette.ink)
            Text(startFailure ?? AudioRecorderError.couldNotStart.localizedDescription)
                .font(.system(size: 15)).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            Text("If another app or a call is using the microphone, finish there and try again.")
                .font(.footnote).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            Button("Try Again") { Task { await startRecording() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func cancel() {
        recorder.cancel()
        flow.cancel()
        dismiss()
    }

    private func begin() async {
        flow.reset()
        if requiresPreparedPermission {
            switch VoiceLaunchPolicy.decision(for: permissionState) {
            case .beginListening:
                await startRecording()
            case .explainBeforeRequesting:
                phase = .permissionPreparation
            case .openSettings:
                phase = .denied
            }
            return
        }
        guard await recorder.requestPermission() else { phase = .denied; return }
        await startRecording()
    }

    private func requestPreparedPermission() async {
        guard await recorder.requestPermission() else { phase = .denied; return }
        await startRecording()
    }

    private func startRecording() async {
        do {
            flow.reset()
            try recorder.start()
            startFailure = nil
            phase = .recording
        } catch {
            startFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .startFailed
        }
    }

    private var permissionState: VoicePermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .authorized
        case .undetermined: return .undetermined
        default: return .denied
        }
    }

    private func stopAndTranscribe() async {
        guard let url = recorder.stop() else { dismiss(); return }
        flow.adopt(url)
        await transcribeKeptRecording()
    }

    /// Transcribe the kept recording. The file is NOT deleted here — only once its words are
    /// committed (saved / used) or the user cancels — so a failure can be retried.
    private func transcribeKeptRecording() async {
        phase = .transcribing
        let transcription = app.transcription
        let used = await flow.transcribe(immediateUse: useImmediatelyAfterTranscription && onUse != nil) { url in
            try await transcription.transcribe(fileURL: url, locale: Locale.current.identifier)
        }
        // Cancelled mid-transcription: the sheet is already closing; hand nothing on.
        guard !flow.isCancelled else { return }
        if let used, let onUse {
            onUse(used)
            dismiss()
            return
        }
        phase = .review
    }

    /// Save the note; close only once it's committed. On failure stay on review with the error
    /// (the transcript and recording are kept for a retry).
    private func save() {
        Task {
            let notes = app.notes, client = app.client
            let saved = await flow.saveNote { text, engine in
                await notes.saveVoiceNote(text, engine: engine, locale: Locale.current.identifier, client: client)
                    ? nil : (notes.errorMessage ?? "Couldn't save the note.")
            }
            if saved { dismiss() }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
    private func engineLabel(_ id: String) -> String {
        switch id {
        case "parakeet-v3": return "Parakeet v3"
        case "speechtranscriber": return "on-device Speech"
        default: return "Apple Speech"
        }
    }
}
