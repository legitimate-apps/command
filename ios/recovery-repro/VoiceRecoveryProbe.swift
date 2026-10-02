import Foundation

/// Test process only. Checkpoints are an external observer, never read to restore app state.
@main
struct VoiceRecoveryProbe {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args[1], directory = URL(fileURLWithPath: args[2], isDirectory: true)
        let audio = directory.appendingPathComponent("recording.wav")
        let flow = VoiceCaptureFlow()
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
            // Re-enter the SAME payload to isolate the loss of retry identity from transcript loss.
            flow.transcript = "Reviewed capture"
            _ = await flow.saveNote { _, _, key in
                try! snapshot(["key": key])
                return "Response lost"
            }
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
        case "uncertain":
            flow.transcript = "Reviewed capture"
            _ = await flow.saveNote { _, _, key in
                try! snapshot(["key": key, "checkpoint": "request-awaiting-response"])
                await hold()
                return "Response lost"
            }
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
