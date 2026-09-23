//
//  AgentTests.swift
//  CommandTests
//
//  Covers the assistant's wire decoding (SSE AgentEvent) and the streaming state
//  machine (AgentStore.apply) deterministically — no network, no simulator UI.
//

import XCTest
@testable import Command

final class AgentTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func event(_ json: String) throws -> AgentEvent {
        try decoder.decode(AgentEvent.self, from: Data(json.utf8))
    }

    func testAgentEventDecoding() throws {
        let thread = try event(#"{"type":"thread","thread_id":42}"#)
        XCTAssertEqual(thread.type, "thread")
        XCTAssertEqual(thread.threadId, 42)

        let tool = try event(#"{"type":"tool","name":"web_search","args":{"query":"x"}}"#)
        XCTAssertEqual(tool.name, "web_search")
        XCTAssertEqual(tool.args?["query"]?.asString, "x")   // args now decoded (E2a)

        // tool_done may carry a compact entity ref for a tappable chip (back-compat: optional).
        let toolDone = try event(#"{"type":"tool_done","name":"create_assignment","entity":{"kind":"assignment","id":40,"label":"Make saffron milk"}}"#)
        XCTAssertEqual(toolDone.entity, AgentEntityRef(kind: "assignment", id: 40, label: "Make saffron milk"))
        // Older servers omit entity — must still decode.
        let bare = try event(#"{"type":"tool_done","name":"create_note"}"#)
        XCTAssertNil(bare.entity)

        let text = try event(#"{"type":"text","delta":"Hel"}"#)
        XCTAssertEqual(text.delta, "Hel")

        let done = try event(#"""
        {"type":"done","output":"Hello","model":"anthropic/claude-sonnet-5","cost_usd":0.007,"remaining_usd":9.99,"searches":1}
        """#)
        XCTAssertEqual(done.output, "Hello")
        XCTAssertEqual(done.costUsd, 0.007)
        XCTAssertEqual(done.remainingUsd, 9.99)
    }

    /// The persisted id of the user turn arrives on the `thread` event; Edit & resend and
    /// Regenerate need it to cut the SERVER thread back, not just the on-screen transcript.
    @MainActor
    func testThreadEventRecordsTheUserTurnsServerId() throws {
        let store = AgentStore()
        store.transcript = [
            ChatMessage(role: "user", text: "plan my week"),
            ChatMessage(role: "assistant", text: "", pending: true),
        ]
        store.apply(try event(#"{"type":"thread","thread_id":7,"user_message_id":42}"#), assistantIndex: 1)
        XCTAssertEqual(store.transcript[0].serverId, 42)
        XCTAssertNil(store.transcript[1].serverId)
    }

    @MainActor
    func testStreamFoldsIntoTranscript() throws {
        let store = AgentStore()
        store.transcript = [
            ChatMessage(role: "user", text: "plan my week"),
            ChatMessage(role: "assistant", text: "", pending: true),
        ]
        let i = 1
        store.apply(try event(#"{"type":"thread","thread_id":7}"#), assistantIndex: i)
        store.apply(try event(#"{"type":"start","model":"anthropic/claude-sonnet-5"}"#), assistantIndex: i)
        store.apply(try event(#"{"type":"tool","name":"search_notes"}"#), assistantIndex: i)
        store.apply(try event(#"{"type":"tool_done","name":"search_notes"}"#), assistantIndex: i)
        store.apply(try event(#"{"type":"text","delta":"Here "}"#), assistantIndex: i)
        store.apply(try event(#"{"type":"text","delta":"you go."}"#), assistantIndex: i)
        store.apply(
            try event(#"{"type":"done","output":"Here you go.","model":"anthropic/claude-sonnet-5","cost_usd":0.01}"#),
            assistantIndex: i
        )

        XCTAssertEqual(store.currentThreadId, 7)
        let a = store.transcript[i]
        XCTAssertEqual(a.text, "Here you go.")
        XCTAssertFalse(a.pending)
        XCTAssertEqual(a.model, "anthropic/claude-sonnet-5")
        XCTAssertEqual(a.costUsd, 0.01)
        XCTAssertEqual(a.tools.count, 1)
        XCTAssertTrue(a.tools[0].done)
    }

    @MainActor
    func testErrorEventMarksFailed() throws {
        let store = AgentStore()
        store.transcript = [
            ChatMessage(role: "user", text: "hi"),
            ChatMessage(role: "assistant", text: "", pending: true),
        ]
        store.apply(
            try event(#"{"type":"error","code":"cap_reached","error":"You've reached this month's $10 agent limit."}"#),
            assistantIndex: 1
        )
        XCTAssertTrue(store.transcript[1].failed)
        XCTAssertFalse(store.transcript[1].pending)
        XCTAssertTrue(store.transcript[1].text.contains("limit"))
    }

    @MainActor
    func testApplyIgnoresOutOfRangeIndex() throws {
        let store = AgentStore()
        store.transcript = [ChatMessage(role: "user", text: "hi")]
        // Index 5 doesn't exist — must not crash or mutate.
        store.apply(try event(#"{"type":"text","delta":"x"}"#), assistantIndex: 5)
        XCTAssertEqual(store.transcript.count, 1)
    }

    @MainActor
    func testBudgetFraction() {
        let store = AgentStore()
        XCTAssertEqual(store.budgetFraction, 1, accuracy: 0.0001)   // no usage -> full bar
        store.usage = AgentUsage(period: "2026-06", costUsd: 2.5, capUsd: 10,
                                 remainingUsd: 7.5, runs: 3, inputTokens: 100, outputTokens: 50)
        XCTAssertEqual(store.budgetFraction, 0.75, accuracy: 0.0001)
    }

    // E4: the meter shows credits (real backend USD × 3) for a budget-governed subscriber,
    // and raw dollars otherwise (dev / comp / flat cap). Backend is always real USD.
    func testDisplayRemainingAppliesCreditMultiplierWhenBudgetGoverned() {
        // Flat-cap / dev account: shown as-is.
        let capUsage = AgentUsage(period: "2026-07", costUsd: 0, capUsd: 10, remainingUsd: 6,
                                  runs: 0, inputTokens: 0, outputTokens: 0,
                                  creditsEnabled: false, budgetGoverned: false)
        XCTAssertEqual(capUsage.displayRemaining, 6, accuracy: 0.0001)

        // Budget-governed subscriber: $6.05 backend → $18.15 of credits shown.
        let budgetUsage = AgentUsage(period: "2026-07", costUsd: 0, capUsd: 6.66, remainingUsd: 6.05,
                                     runs: 0, inputTokens: 0, outputTokens: 0,
                                     creditsEnabled: true, budgetGoverned: true)
        XCTAssertEqual(budgetUsage.displayRemaining, 18.15, accuracy: 0.0001)
    }

    func testModelLabel() {
        XCTAssertEqual(AgentModelLabel.short("anthropic/claude-sonnet-5"), "Sonnet")
        XCTAssertEqual(AgentModelLabel.short("anthropic/claude-opus-5.5"), "Opus")
        XCTAssertEqual(AgentModelLabel.short("anthropic/claude-haiku-4.5"), "Haiku")   // Fast tier is Haiku now
        XCTAssertEqual(AgentModelLabel.short("z-ai/glm-5.3"), "GLM")
        XCTAssertEqual(AgentModelLabel.short("moonshotai/kimi-k3"), "Kimi")
        XCTAssertEqual(AgentModelLabel.short("openai/gpt-6-sol"), "GPT")
        XCTAssertEqual(AgentModelLabel.short("openai/gpt-5.6-terra"), "GPT")  // pre-rename usage rows
        // Matching is on the family, not the version, so a tier bump needs no client change.
        XCTAssertEqual(AgentModelLabel.short("anthropic/claude-opus-6"), "Opus")
        // Qwen is retired — no special mapping remains; a stray slug just yields its tail.
        XCTAssertEqual(AgentModelLabel.short("qwen/qwen3-coder-plus"), "qwen3-coder-plus")
    }

    /// The picker's `apiValue` is the wire contract with `resolve_model_slug` on the
    /// server — a rename on either side silently falls through to the auto router.
    func testModelChoiceWireValues() {
        XCTAssertNil(AgentModelChoice.auto.apiValue)
        XCTAssertEqual(AgentModelChoice.allCases.compactMap(\.apiValue),
                       ["opus", "sonnet", "fast", "glm", "kimi", "gpt"])
    }

    /// GLM is text-only on OpenRouter, so the composer hides the attach button
    /// for it; every other tier takes images.
    func testOnlyGLMHidesImageAttachments() {
        XCTAssertFalse(AgentModelChoice.glm.supportsImages)
        for choice in AgentModelChoice.allCases where choice != .glm {
            XCTAssertTrue(choice.supportsImages, "\(choice.rawValue) should accept images")
        }
    }

    func testToolLabel() {
        XCTAssertEqual(AgentToolLabel.describe("web_search"), "Searching the web")
        XCTAssertEqual(AgentToolLabel.describe("create_goal"), "Creating a goal")
        XCTAssertEqual(AgentToolLabel.describe("search_notes"), "Reading your notes")
        XCTAssertEqual(AgentToolLabel.describe("delete_assignment"), "Deleting a task")
        XCTAssertEqual(AgentToolLabel.describe("fetch_url"), "Reading a link")
    }

    // E5: the Claude tiers are all multimodal (Fast = Haiku 4.5); the per-tier image
    // rule now lives in testOnlyGLMHidesImageAttachments, since GLM is text-only.
    func testClaudeTiersSupportImages() {
        for choice in [AgentModelChoice.auto, .opus, .sonnet, .fast] {
            XCTAssertTrue(choice.supportsImages, "\(choice) should accept images")
        }
        XCTAssertEqual(AgentModelChoice.fast.detail, "Quick & capable")
    }

    // E2a: the `tool` args and `tool_done` entity fold into the chip (target text + tappability).
    @MainActor
    func testToolChipCarriesDetailAndEntity() throws {
        let store = AgentStore()
        store.transcript = [
            ChatMessage(role: "user", text: "make saffron milk at 9pm"),
            ChatMessage(role: "assistant", text: "", pending: true),
        ]
        store.apply(try event(#"{"type":"tool","name":"create_assignment","args":{"title":"Make saffron milk"}}"#), assistantIndex: 1)
        XCTAssertEqual(store.transcript[1].tools.first?.detail, "Make saffron milk")
        store.apply(try event(#"{"type":"tool_done","name":"create_assignment","entity":{"kind":"assignment","id":40,"label":"Make saffron milk"}}"#), assistantIndex: 1)
        let chip = store.transcript[1].tools.first
        XCTAssertEqual(chip?.entity, AgentEntityRef(kind: "assignment", id: 40, label: "Make saffron milk"))
        XCTAssertTrue(chip?.done == true)
        XCTAssertFalse(chip?.isAwaitingConfirmation == true)   // a create is never a confirm round-trip
    }

    func testToolDetailExtraction() {
        XCTAssertEqual(AgentStore.toolDetail(name: "search_notes", args: ["query": .string("meals")]), "meals")
        XCTAssertEqual(AgentStore.toolDetail(name: "upsert_person", args: ["name": .string("Dana")]), "Dana")
        XCTAssertNil(AgentStore.toolDetail(name: "list_goals", args: nil))
        // Non-string values are ignored (never coerced into chip text).
        XCTAssertNil(AgentStore.toolDetail(name: "set_assignment_status", args: ["priority": .number(2)]))
    }

    // E4: a delete tool that completes with NO entity means the delete is parked awaiting the
    // user's confirmation (the needs_confirm round-trip) — the signal for the Confirm/Cancel UI.
    @MainActor
    func testAwaitingConfirmationSignal() throws {
        let store = AgentStore()
        store.transcript = [
            ChatMessage(role: "user", text: "delete the duplicate reminder"),
            ChatMessage(role: "assistant", text: "", pending: true),
        ]
        store.apply(try event(#"{"type":"tool","name":"delete_assignment","args":{"assignment_id":41}}"#), assistantIndex: 1)
        store.apply(try event(#"{"type":"tool_done","name":"delete_assignment"}"#), assistantIndex: 1)   // no entity → needs_confirm
        XCTAssertTrue(store.transcript[1].tools.first?.isAwaitingConfirmation == true)

        // The follow-up (confirmed) delete DOES carry an entity → no longer awaiting.
        store.transcript[1].tools[0].entity = AgentEntityRef(kind: "assignment", id: 41, label: "saffron milk")
        XCTAssertFalse(store.transcript[1].tools[0].isAwaitingConfirmation)
    }

    // E3: regenerate replays the last user turn (drops the stale assistant reply).
    @MainActor
    func testRegenerateLastReplaysUserTurn() {
        let store = AgentStore()
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        store.transcript = [
            ChatMessage(role: "user", text: "plan my week"),
            ChatMessage(role: "assistant", text: "here's a plan", model: "m", pending: false),
        ]
        store.regenerateLast(client: client)
        XCTAssertEqual(store.transcript.count, 2)
        XCTAssertEqual(store.transcript[0].text, "plan my week")
        XCTAssertTrue(store.transcript[0].isUser)
        XCTAssertTrue(store.transcript[1].pending)                 // fresh pending assistant
        XCTAssertEqual(store.transcript[1].text, "")
        store.cancelStreaming()                                    // tidy the localhost stream task
    }

    // E3: edit-and-resend rewrites a user turn and drops everything after it.
    @MainActor
    func testEditAndResendDropsLaterTurns() {
        let store = AgentStore()
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        store.transcript = [
            ChatMessage(role: "user", text: "typo qustion"),
            ChatMessage(role: "assistant", text: "answer", pending: false),
        ]
        let userId = store.transcript[0].id
        store.editAndResend(messageId: userId, newText: "typo question", client: client)
        XCTAssertEqual(store.transcript.count, 2)
        XCTAssertEqual(store.transcript[0].text, "typo question")
        XCTAssertTrue(store.transcript[1].pending)
        store.cancelStreaming()
    }
}

// MARK: - Markdown block parser (E1)

final class MarkdownParserTests: XCTestCase {
    func testHeadingsAndParagraphs() {
        let blocks = MarkdownParser.parse("# Title\n\nA paragraph line.")
        XCTAssertEqual(blocks, [.heading(level: 1, text: "Title"), .paragraph("A paragraph line.")])
    }

    func testBulletAndOrderedLists() {
        let bullets = MarkdownParser.parse("- one\n- two")
        XCTAssertEqual(bullets, [.bulletList(["one", "two"])])
        let ordered = MarkdownParser.parse("1. first\n2. second")
        XCTAssertEqual(ordered, [.orderedList(["first", "second"])])
    }

    func testPipeTable() {
        let md = "| Name | Role |\n|------|------|\n| Dana | Lead |\n| Sam | Eng |"
        XCTAssertEqual(MarkdownParser.parse(md), [
            .table(header: ["Name", "Role"], rows: [["Dana", "Lead"], ["Sam", "Eng"]])
        ])
    }

    func testFencedCodeAndRule() {
        let code = MarkdownParser.parse("```\nlet x = 1\n```")
        XCTAssertEqual(code, [.code("let x = 1")])
        XCTAssertEqual(MarkdownParser.parse("---"), [.rule])
        // An unclosed fence (mid-stream) still renders as code, not raw text.
        XCTAssertEqual(MarkdownParser.parse("```\nhalf typed"), [.code("half typed")])
    }

    func testDashRuleVsBulletDisambiguation() {
        // "- item" is a bullet, not a horizontal rule.
        XCTAssertEqual(MarkdownParser.parse("- item"), [.bulletList(["item"])])
    }

    func testBlockQuote() {
        XCTAssertEqual(MarkdownParser.parse("> quoted line"), [.quote("quoted line")])
    }

    func testPlainTextDegradesToParagraph() {
        XCTAssertEqual(MarkdownParser.parse("just words"), [.paragraph("just words")])
    }
}
