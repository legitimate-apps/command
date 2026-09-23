//
//  AgentStore.swift
//  Command
//
//  Shared observable state for the AI assistant: the thread list, the active
//  conversation's transcript, and the live SSE stream of a run. One instance lives
//  on AppState so the chat screen and the history sheet stay in sync.
//
//  Streaming is a small state machine: `send` appends an optimistic user turn + an
//  empty pending assistant turn, then folds each `AgentEvent` into that assistant
//  turn (text deltas, tool chips, final usage). A generation counter makes
//  cancel/restart (new chat, open thread) race-safe.
//

import Foundation
import Observation

/// Which model tier to run. `auto` uses the server's weighted router; the rest
/// force a tier so the user can ask harder questions on Opus or save budget on Fast.
enum AgentModelChoice: String, CaseIterable, Identifiable, Hashable {
    /// Claude tiers first (the house default), then the non-Anthropic alternates.
    case auto, opus, sonnet, fast, glm, kimi, gpt

    var id: String { rawValue }
    /// Sent to the server; `auto` maps to the weighted router there.
    var apiValue: String? { self == .auto ? nil : rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .fast: return "Fast"
        case .glm: return "GLM"
        case .kimi: return "Kimi"
        case .gpt: return "GPT"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Balanced — picks for you"
        case .opus: return "Most capable, pricier"
        case .sonnet: return "Strong all-rounder"
        case .fast: return "Quick & capable"
        case .glm: return "Cheapest — text only"
        case .kimi: return "Long-context alternate"
        case .gpt: return "OpenAI alternate"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .opus: return "brain.head.profile"
        case .sonnet: return "wand.and.stars"
        case .fast: return "bolt.fill"
        case .glm: return "leaf.fill"
        case .kimi: return "circle.hexagongrid.fill"
        case .gpt: return "cpu"
        }
    }

    /// Whether this tier accepts image attachments — drives the composer's attach
    /// affordance. GLM is text-only on OpenRouter; the server independently
    /// re-routes an image turn to the multimodal default and reports the model it
    /// actually used, so this is the friendly guard, not the safety one.
    var supportsImages: Bool { self != .glm }
}

/// One image the user attached to the next message. Holds the display thumbnail and
/// the already-encoded JPEG payload (downscaled) so sending is a cheap base64 step.
struct ChatAttachment: Identifiable, Equatable, Sendable {
    let id = UUID()
    let jpeg: Data          // downscaled JPEG bytes, sent natively to the model
    static func == (a: ChatAttachment, b: ChatAttachment) -> Bool { a.id == b.id }
}

/// One tool the assistant invoked during a turn, for the live status chips.
struct ChatToolEvent: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var done: Bool
    /// A short target pulled from the call's `args` — e.g. the task title or search query —
    /// so a chip can read "Creating task: Make saffron milk" instead of a bare verb. nil when
    /// the tool has no obvious subject (or an older server didn't send args).
    var detail: String? = nil
    /// The entity the tool touched, from `tool_done`. Present only for write tools that
    /// returned an id + label; drives the tappable "open this" affordance on the chip.
    var entity: AgentEntityRef? = nil

    /// The delete/remove tools that gate on the two-call confirm-token flow AND surface an
    /// entity on success. When one of these runs but `tool_done` carries NO entity, the delete
    /// was blocked awaiting the user's approval (the needs_confirm round-trip) — the signal the
    /// chat uses to show an explicit Confirm / Cancel affordance. `delete_activity` is omitted
    /// deliberately: the server doesn't emit an entity for it, so "no entity" can't distinguish
    /// awaiting-confirm from a completed delete there (it falls back to typing "yes").
    static let confirmGatedTools: Set<String> = ["delete_assignment", "delete_goal", "remove_person"]

    /// True when this chip represents a destructive op that completed a step but did NOT
    /// delete anything — i.e. it's parked on the confirmation round-trip.
    var isAwaitingConfirmation: Bool {
        done && entity == nil && Self.confirmGatedTools.contains(name)
    }
}

/// A single chat bubble. View identity is a UUID; `serverId` is the persisted message id when
/// known (a reopened thread, or a user turn once the stream's `thread` event names it) — what
/// "Edit & resend" / "Regenerate" cut the server-side thread back to.
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String              // "user" | "assistant"
    var text: String
    var model: String? = nil
    var costUsd: Double? = nil
    var pending: Bool = false      // assistant turn still streaming
    var tools: [ChatToolEvent] = []
    var failed: Bool = false
    var images: [Data] = []        // JPEG payloads attached to a user turn (live only)
    var serverId: Int? = nil

    var isUser: Bool { role == "user" }
}

@MainActor
@Observable
final class AgentStore {
    var threads: [AgentThread] = []
    var transcript: [ChatMessage] = []
    var currentThreadId: Int?
    var isStreaming = false
    var usage: AgentUsage?
    var errorMessage: String?
    var modelChoice: AgentModelChoice = .auto
    /// Per-conversation opt-in to let the agent read hidden (invisible-ink) items.
    /// Resets to false on every new chat / thread switch — the user must re-enable it.
    var allowHidden = false
    /// Images staged for the next message (the composer's preview row). Max 4 — the
    /// server enforces the same cap. Cleared on send / new chat / thread switch.
    var pendingImages: [ChatAttachment] = []
    static let maxImages = 4

    /// Turns the user sent while the assistant was still answering, oldest first.
    ///
    /// Before this existed, `send` bailed on `!isStreaming` and the turn was silently dropped
    /// after the composer had already cleared the field — the user's message simply vanished.
    /// Queueing is the honest behaviour: accept it, show it, send it when the current turn ends.
    private(set) var queuedTurns: [QueuedTurn] = []
    /// Bounded on purpose: an unbounded queue lets a wedged stream bank an unlimited burst of
    /// paid turns that all fire at once when it finally closes.
    static let maxQueuedTurns = 10

    var queuedCount: Int { queuedTurns.count }

    struct QueuedTurn: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var images: [Data]
    }

    private var streamTask: Task<Void, Never>?
    private var generation = 0

    // MARK: Loads

    func loadThreads(client: APIClient) async {
        do {
            threads = try await client.drainAll { limit, cursor in
                try await client.agentThreads(limit: limit, cursor: cursor)
            }
            errorMessage = nil
        }
        catch { errorMessage = describe(error) }
    }

    func loadUsage(client: APIClient) async {
        usage = try? await client.agentUsage()
    }

    /// Remaining budget as a 0...1 fraction of the cap (for the budget meter).
    var budgetFraction: Double {
        guard let u = usage, u.capUsd > 0 else { return 1 }
        return max(0, min(1, u.remainingUsd / u.capUsd))
    }

    // MARK: Navigation

    /// Abandon whatever conversation is on screen: supersede any in-flight stream and drop the
    /// state that belongs to it.
    ///
    /// Queued turns are conversation-scoped and MUST die here. `drainQueue` only runs inside the
    /// stream's `gen == generation` block, so navigating away leaves the queue orphaned rather
    /// than drained — and the next stream to finish, in a DIFFERENT thread, would fire those
    /// messages into it. The user would watch text they typed in one conversation get sent, and
    /// billed, in another.
    private func leaveCurrentConversation() {
        generation += 1
        streamTask?.cancel()
        isStreaming = false
        pendingImages = []
        queuedTurns.removeAll()
        allowHidden = false   // every conversation starts with hidden content off-limits
    }

    func newChat() {
        leaveCurrentConversation()
        currentThreadId = nil
        transcript = []
        errorMessage = nil
    }

    func openThread(_ id: Int, client: APIClient) async {
        leaveCurrentConversation()
        do {
            let detail = try await client.agentThread(id: id)
            currentThreadId = detail.thread.id
            transcript = detail.messages.map {
                ChatMessage(role: $0.role, text: $0.content, model: $0.model, costUsd: $0.costUsd,
                            serverId: $0.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    func reset() {
        leaveCurrentConversation()
        threads = []
        transcript = []
        currentThreadId = nil
        usage = nil
        errorMessage = nil
    }

    // MARK: Streaming send

    /// Send a turn, or queue it when the assistant is still answering.
    ///
    /// Returns whether the turn was ACCEPTED. The composer clears its field only on `true`, so a
    /// refused turn (empty, or a full queue) leaves the user's typing where they can still see it
    /// instead of eating it.
    @discardableResult
    func send(_ text: String, client: APIClient) -> Bool {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingImages
        guard !msg.isEmpty || !attachments.isEmpty else { return false }
        if isStreaming {
            return enqueueIfBusy(text: msg, images: attachments.map(\.jpeg))
        }
        pendingImages = []   // consumed into this turn
        dispatch(text: msg, payloads: attachments.map(\.jpeg), client: client)
        return true
    }

    /// Queue a turn that arrived mid-stream. Returns false when it can't be queued — not
    /// streaming (the caller should dispatch instead), empty, or the queue is full.
    @discardableResult
    func enqueueIfBusy(text: String, images: [Data]) -> Bool {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isStreaming else { return false }
        guard !msg.isEmpty || !images.isEmpty else { return false }
        guard queuedTurns.count < Self.maxQueuedTurns else { return false }
        queuedTurns.append(QueuedTurn(text: msg, images: images))
        pendingImages = []   // consumed into the queued turn
        return true
    }

    /// Pop the next queued turn, oldest first.
    func dequeueNextTurn() -> QueuedTurn? {
        queuedTurns.isEmpty ? nil : queuedTurns.removeFirst()
    }

    /// Drop everything queued — the composer's "Clear" affordance.
    func clearQueue() {
        queuedTurns.removeAll()
    }

    /// Start the next queued turn, if any. Called when a stream finishes cleanly.
    private func drainQueue(client: APIClient) {
        guard !isStreaming, let next = dequeueNextTurn() else { return }
        dispatch(text: next.text, payloads: next.images, client: client)
    }

    /// Regenerate the last assistant turn: drop it, then re-send the preceding user message
    /// (with the same attachments). No-op mid-stream or with no user turn to replay.
    func regenerateLast(client: APIClient) {
        guard !isStreaming, let idx = transcript.lastIndex(where: { $0.isUser }) else { return }
        let text = transcript[idx].text
        let payloads = transcript[idx].images
        let cut = transcript[idx].serverId
        transcript.removeSubrange(idx...)   // the user turn + everything after (the stale assistant reply)
        dispatch(text: text, payloads: payloads, client: client, truncatingFrom: cut)
    }

    /// Edit-and-resend a past user message: everything from that turn onward is dropped and
    /// the edited text is re-sent (reusing the turn's original attachments). No-op mid-stream.
    func editAndResend(messageId: UUID, newText: String, client: APIClient) {
        let msg = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming,
              let idx = transcript.firstIndex(where: { $0.id == messageId }), transcript[idx].isUser
        else { return }
        let payloads = transcript[idx].images
        guard !msg.isEmpty || !payloads.isEmpty else { return }
        let cut = transcript[idx].serverId
        transcript.removeSubrange(idx...)
        dispatch(text: msg, payloads: payloads, client: client, truncatingFrom: cut)
    }

    /// Core streaming send: append the optimistic user + pending-assistant turns and fold the
    /// SSE stream into the assistant turn. Shared by `send`, `regenerateLast`, `editAndResend`.
    ///
    /// `truncatingFrom` is the server id of a user turn being replaced. The server thread is cut
    /// back to just before it first — otherwise only the phone forgot the old turns, and the model
    /// still received them as history (and reopening the thread showed them again).
    private func dispatch(text msg: String, payloads: [Data], client: APIClient, truncatingFrom cut: Int? = nil) {
        transcript.append(ChatMessage(role: "user", text: msg, images: payloads))
        let assistantIndex = transcript.count
        transcript.append(ChatMessage(role: "assistant", text: "", pending: true))

        isStreaming = true
        errorMessage = nil
        generation += 1
        let gen = generation
        let threadId = currentThreadId
        let model = modelChoice.apiValue
        let allowHidden = self.allowHidden

        streamTask = Task {
            // Base64-encode attachments off the main actor — encoding up to 4 JPEGs synchronously
            // in send() (a @MainActor method) hitched the UI on send. payloads/[ChatImage] are Sendable.
            let images = await Task.detached {
                payloads.map { APIClient.ChatImage(mediaType: "image/jpeg", data: $0.base64EncodedString()) }
            }.value
            if let cut, let threadId {
                // Best-effort: an older server without the endpoint still gets the new turn.
                try? await client.truncateAgentThread(id: threadId, fromMessageId: cut)
            }
            do {
                for try await event in client.streamAgentChat(message: msg, threadId: threadId, model: model, allowHidden: allowHidden, images: images) {
                    guard gen == self.generation else { return }   // superseded by new chat / open
                    self.apply(event, assistantIndex: assistantIndex)
                }
            } catch {
                if gen == self.generation, !Task.isCancelled {
                    self.fail(assistantIndex: assistantIndex, message: self.describe(error))
                }
            }
            if gen == self.generation {
                self.isStreaming = false
                // A clean stream close that never delivered `done`/`error` (server timeout/crash
                // after some deltas) used to leave the bubble spinning forever. Finalize it.
                self.finalizeIfPending(assistantIndex: assistantIndex)
                await self.loadThreads(client: client)   // titles/order may have changed
                await self.loadUsage(client: client)
                // Anything the user sent while this turn was answering goes now, in order.
                self.drainQueue(client: client)
            }
        }
    }

    /// Close out an assistant turn still marked `pending` after the stream ended without a
    /// terminal `done`/`error` event, so it never spins indefinitely. No-op once `apply`/`fail`
    /// has already finalized it.
    private func finalizeIfPending(assistantIndex: Int) {
        guard transcript.indices.contains(assistantIndex), transcript[assistantIndex].pending else { return }
        transcript[assistantIndex].pending = false
        if transcript[assistantIndex].text.isEmpty {
            transcript[assistantIndex].text = "The response ended unexpectedly. Please try again."
        }
    }

    func cancelStreaming() {
        guard isStreaming else { return }
        generation += 1
        streamTask?.cancel()
        isStreaming = false
        // Stop means stop. Draining a queue the user just interrupted would fire a burst of
        // paid turns they explicitly cancelled — worse than not queueing at all.
        queuedTurns.removeAll()
        if let last = transcript.indices.last, transcript[last].role == "assistant", transcript[last].pending {
            transcript[last].pending = false
            if transcript[last].text.isEmpty { transcript[last].text = "Stopped." }
        }
    }

    /// Fold one SSE event into the pending assistant turn. Pure state transition
    /// (no I/O) so it's unit-testable; the post-stream thread/usage refresh happens
    /// in `send`'s completion.
    func apply(_ event: AgentEvent, assistantIndex: Int) {
        guard transcript.indices.contains(assistantIndex) else { return }
        switch event.type {
        case "thread":
            if let tid = event.threadId { currentThreadId = tid }
            // The user turn is the bubble just before the pending assistant one.
            if let uid = event.userMessageId, assistantIndex > 0, transcript[assistantIndex - 1].isUser {
                transcript[assistantIndex - 1].serverId = uid
            }
        case "start":
            transcript[assistantIndex].model = event.model
        case "tool":
            if let name = event.name {
                transcript[assistantIndex].tools.append(
                    ChatToolEvent(name: name, done: false, detail: Self.toolDetail(name: name, args: event.args))
                )
            }
        case "tool_done":
            if let name = event.name,
               let i = transcript[assistantIndex].tools.lastIndex(where: { $0.name == name && !$0.done }) {
                transcript[assistantIndex].tools[i].done = true
                transcript[assistantIndex].tools[i].entity = event.entity
            }
        case "text":
            if let d = event.delta { transcript[assistantIndex].text += d }
        case "done":
            if let out = event.output, !out.isEmpty { transcript[assistantIndex].text = out }
            transcript[assistantIndex].pending = false
            transcript[assistantIndex].model = event.model ?? transcript[assistantIndex].model
            transcript[assistantIndex].costUsd = event.costUsd
            for i in transcript[assistantIndex].tools.indices { transcript[assistantIndex].tools[i].done = true }
        case "error":
            fail(assistantIndex: assistantIndex, message: event.error ?? "Something went wrong.")
        default:
            break
        }
    }

    /// Pull a short human target out of a tool call's `args` for the status chip — the task
    /// title, person name, or search query. Prefers the most subject-like key present and
    /// caps the length so a chip never sprawls. Returns nil when there's nothing worth showing.
    nonisolated static func toolDetail(name: String, args: [String: JSONValue]?) -> String? {
        guard let args else { return nil }
        // Ordered by how subject-like the key is; the first string hit wins.
        for key in ["title", "name", "query", "assignee", "text", "body"] {
            if let s = args[key]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s.count > 60 ? String(s.prefix(60)) + "…" : s
            }
        }
        return nil
    }

    private func fail(assistantIndex: Int, message: String) {
        guard transcript.indices.contains(assistantIndex) else { return }
        transcript[assistantIndex].pending = false
        transcript[assistantIndex].failed = true
        if transcript[assistantIndex].text.isEmpty { transcript[assistantIndex].text = message }
        errorMessage = message
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
