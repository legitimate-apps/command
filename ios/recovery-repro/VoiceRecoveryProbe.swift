import Foundation

/// Test process only. Checkpoints are an external observer, never read to restore app state.
@main
struct VoiceRecoveryProbe {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args[1], directory = URL(fileURLWithPath: args[2], isDirectory: true)
        if mode.hasPrefix("wire-") {
            try await wire(mode: mode, directory: directory, server: URL(string: args[3])!)
            return
        }
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

private extension VoiceRecoveryProbe {
    @MainActor
    static func wire(mode: String, directory: URL, server: URL) async throws {
        precondition(server.host == "127.0.0.1" && server.scheme == "http")
        let client = APIClient(baseURL: server, configuration: .ephemeral)
        let username = "voice-recovery-test", password = "local-fixture-password-only"
        if mode == "wire-seed" { try await client.register(username: username, password: password, displayName: nil) }
        let account = try await client.login(username: username, password: password)
        let recovery = VoiceRecordingRecoveryStore(root: directory.appendingPathComponent("recovery"),
            server: server, accountID: account.id, username: account.username, accountCreatedAt: account.createdAt)
        let record = mode == "wire-reconcile" ? try recovery.load().recordings.first : nil
        let flow = VoiceCaptureFlow(recovery: recovery, restoring: record)
        if mode == "wire-seed" {
            flow.adopt(directory.appendingPathComponent("recording.wav"))
            flow.transcript = "Original voice capture"
        }
        var observations: [String: String] = [:]
        func snapshot() throws {
            observations["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            observations["audio"] = flow.audioURL?.path ?? ""
            observations["review"] = flow.transcript
            try JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("observation.json"), options: .atomic)
        }
        let saved = await flow.saveRecoveredNote(locale: mode == "wire-seed" ? "en-US" : "fr-FR",
            using: .init(create: { request in
                let note = try await client.createNote(body: request.body, source: "voice", engine: request.engine,
                    locale: request.locale, idempotencyKey: request.key)
                observations["key"] = request.key
                observations["noteID"] = String(note.id)
                observations["createBody"] = request.body
                observations["createLocale"] = request.locale ?? ""
                if mode == "wire-seed" {
                    // The server committed; withhold that acknowledgment from the production flow.
                    flow.transcript = "Later voice review edits"
                    observations["checkpoint"] = "server-committed-before-flow-ack"
                    try snapshot()
                    while true { try await Task.sleep(for: .seconds(3600)) }
                }
                return note.id
            }, update: { id, text in
                let note = try await client.updateNote(id: id, body: text)
                observations["patchedID"] = String(note.id)
                observations["patchedBody"] = note.body
            }))
        observations["saved"] = String(saved)
        observations["remaining"] = String(try recovery.load().recordings.count)
        observations["error"] = flow.errorMessage ?? ""
        try snapshot()
    }
}
