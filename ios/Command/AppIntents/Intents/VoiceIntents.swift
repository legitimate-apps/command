//
//  VoiceIntents.swift
//  Command
//
//  iOS 26 voice entry points. StartVoiceConversationIntent foregrounds the app and
//  hands microphone capture to the existing on-device transcription stack. AskCommandIntent
//  uses Siri's normal required-parameter resolution, then sends that resolved String to the
//  existing streaming agent endpoint and returns the completed answer as spoken dialog.
//

import AppIntents
import Foundation

struct StartVoiceConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Voice Conversation"
    static var description = IntentDescription(
        "Open Command ready to listen and send the transcription to your assistant.",
        categoryName: "Assistant",
        searchKeywords: ["voice", "talk", "assistant", "listen"]
    )
    static var openAppWhenRun = true
    static var isDiscoverable = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard #available(iOS 26.0, *) else {
            throw CommandIntentError.server("voice conversations require iOS 26 or later.")
        }
        ShortcutNavigation.shared.route(.voiceConversation)
        return .result()
    }
}

struct AskCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Command"
    static var description = IntentDescription(
        "Ask your Command assistant a free-form question.",
        categoryName: "Assistant",
        searchKeywords: ["ask", "question", "assistant", "agent"]
    )
    static var isDiscoverable = true

    @Parameter(
        title: "Question",
        requestValueDialog: IntentDialog("What would you like to ask?")
    )
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Command \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard #available(iOS 26.0, *) else {
            throw CommandIntentError.server("Ask Command requires iOS 26 or later.")
        }
        let cleaned: String
        do {
            cleaned = try VoiceInputValidator.cleaned(question)
        } catch {
            throw CommandIntentError.emptyInput("a question")
        }

        let answer = try await IntentAPI.run { client in
            var completed = ""
            var streamed = ""
            for try await event in client.streamAgentChat(message: cleaned, threadId: nil) {
                if event.type == "text", let delta = event.delta { streamed += delta }
                if event.type == "done", let output = event.output { completed = output }
                if event.type == "error" {
                    throw CommandIntentError.server(event.error ?? "the assistant stopped unexpectedly.")
                }
            }
            let result = completed.isEmpty ? streamed : completed
            guard !result.isEmpty else {
                throw CommandIntentError.server("the assistant returned no answer.")
            }
            return result
        }
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}
