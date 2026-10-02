import Foundation

/// Test process only. Checkpoints are an external observer, never read to restore app state.
@main
struct VoiceRecoveryProbe {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args[1], directory = URL(fileURLWithPath: args[2], isDirectory: true)
        let audio = directory.appendingPathComponent("recording.wav")
        let recovery = VoiceRecordingRecoveryStore(root: directory.appendingPathComponent("recovery"),
            server: URL(string: "https://example.invalid")!, accountID: 1,
            username: "recovery-test", accountCreatedAt: "2026-10-02")
        let restored = ["relaunch", "retry", "reconcile"].contains(mode) ? try recovery.load().recordings.first : nil
        let flow = VoiceCaptureFlow(recovery: recovery, restoring: restored)
        func snapshot(_ extra: [String: String] = [:]) throws {
            var value = extra
            value["audio"] = flow.audioURL?.path ?? ""
            value["transcript"] = flow.transcript
            value["engine"] = flow.engineUsed
            value["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("observation.json"), options: .atomic)
        }
        func hold() async {
            while true { try? await Task.sleep(for: .seconds(3600)) }
        }
        if mode == "relaunch" {
            try snapshot()
            return
        }
        if mode == "retry" {
            _ = await flow.saveRecoveredNote(locale: "fr-FR", using: .init(create: { request in
                try snapshot(["key": request.key])
                throw URLError(.networkConnectionLost)
            }, update: { _, _ in }))
            return
        }
        if mode == "reconcile" {
            var key = "", body = "", locale = "", patchedBody = "", patchedID = ""
            let saved = await flow.saveRecoveredNote(locale: "fr-FR", using: .init(create: { request in
                key = request.key; body = request.body; locale = request.locale ?? ""
                return 7
            }, update: { id, text in patchedID = String(id); patchedBody = text }))
            try snapshot(["key": key, "createBody": body, "createLocale": locale,
                          "patchedID": patchedID, "patchedBody": patchedBody,
                          "saved": String(saved), "remaining": String(try recovery.load().recordings.count)])
            return
        }
        flow.adopt(audio)
        switch mode {
        case "stopped":
            try snapshot(); await hold()
        case "transcribing":
            _ = await flow.transcribe(immediateUse: false) { _ in
                try snapshot(["checkpoint": "inside-transcriber"])
                await hold()
                throw CancellationError()
            }
        case "review":
            _ = await flow.transcribe(immediateUse: false) { _ in ("Spoken capture", "sfspeech") }
            flow.transcript = "Latest edited review"
            try snapshot(); await hold()
        case "uncertain", "uncertain-edited":
            flow.transcript = "Reviewed capture"
            _ = await flow.saveRecoveredNote(locale: "en-US", using: .init(create: { request in
                if mode == "uncertain-edited" { flow.transcript = "Later review edits" }
                try snapshot(["key": request.key, "checkpoint": "request-awaiting-response"])
                await hold()
                throw URLError(.networkConnectionLost)
            }, update: { _, _ in }))
        case "cancel":
            flow.cancel(); try snapshot()
        case "success":
            flow.transcript = "Reviewed capture"
            _ = await flow.saveNote { _, _, _ in nil }
            try snapshot()
        case "same-process-retry":
            flow.transcript = "Reviewed capture"
            var keys: [String] = []
            for _ in 0..<2 {
                _ = await flow.saveNote { _, _, key in keys.append(key); return "Response lost" }
            }
            try snapshot(["firstKey": keys[0], "secondKey": keys[1]])
        default:
            fatalError("Unknown test mode")
        }
    }
}
