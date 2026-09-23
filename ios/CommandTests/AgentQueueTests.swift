//
//  AgentQueueTests.swift
//  Command
//
//  Sending while the assistant is mid-answer.
//
//  Reported from the field (2026-08-02): "sometimes the message will not be removed from the
//  field" and "I can't queue multiple messages which I should be able to". Both trace to one
//  design flaw — `send` bailed with `guard !isStreaming else { return }`, so a mid-stream turn
//  was silently DROPPED while the composer had already cleared the draft, and the Send button
//  swapped to Stop under the user's finger (which is how a duplicate turn plus a "Stopped."
//  ended up in the same transcript).
//
//  The contract now: a mid-stream turn is ACCEPTED and queued, never dropped; the caller can
//  tell whether it was accepted so it only clears the field when it was; the queue drains in
//  order; and stopping discards it rather than firing a burst the user no longer wants.
//

import XCTest
@testable import Command

@MainActor
final class AgentQueueTests: XCTestCase {

    func testSendWhileStreamingIsQueuedNotDropped() {
        let store = AgentStore()
        store.isStreaming = true

        XCTAssertTrue(store.enqueueIfBusy(text: "second question", images: []),
                      "a mid-stream turn must be accepted, not silently dropped")
        XCTAssertEqual(store.queuedTurns.count, 1)
        XCTAssertEqual(store.queuedTurns.first?.text, "second question")
    }

    func testCallerCanTellWhetherTheTurnWasAccepted() {
        let store = AgentStore()
        store.isStreaming = true

        // Empty input is refused, so the composer keeps whatever the user has.
        XCTAssertFalse(store.enqueueIfBusy(text: "   ", images: []))
        XCTAssertFalse(store.enqueueIfBusy(text: "", images: []))
        XCTAssertTrue(store.queuedTurns.isEmpty)
    }

    func testQueueDrainsInFIFOOrder() {
        let store = AgentStore()
        store.isStreaming = true
        _ = store.enqueueIfBusy(text: "first", images: [])
        _ = store.enqueueIfBusy(text: "second", images: [])
        _ = store.enqueueIfBusy(text: "third", images: [])

        XCTAssertEqual(store.dequeueNextTurn()?.text, "first")
        XCTAssertEqual(store.dequeueNextTurn()?.text, "second")
        XCTAssertEqual(store.dequeueNextTurn()?.text, "third")
        XCTAssertNil(store.dequeueNextTurn())
    }

    func testStoppingDiscardsTheQueue() {
        let store = AgentStore()
        store.isStreaming = true
        _ = store.enqueueIfBusy(text: "queued one", images: [])
        _ = store.enqueueIfBusy(text: "queued two", images: [])

        store.cancelStreaming()

        XCTAssertTrue(store.queuedTurns.isEmpty,
                      "stop means stop — a queue that fires anyway is worse than no queue")
        XCTAssertFalse(store.isStreaming)
    }

    func testQueuedCountIsObservableForTheComposer() {
        let store = AgentStore()
        store.isStreaming = true
        XCTAssertEqual(store.queuedCount, 0)
        _ = store.enqueueIfBusy(text: "a", images: [])
        _ = store.enqueueIfBusy(text: "b", images: [])
        XCTAssertEqual(store.queuedCount, 2)
    }

    func testQueueIsBounded() {
        let store = AgentStore()
        store.isStreaming = true
        for i in 0..<(AgentStore.maxQueuedTurns + 5) {
            _ = store.enqueueIfBusy(text: "msg \(i)", images: [])
        }
        XCTAssertEqual(store.queuedTurns.count, AgentStore.maxQueuedTurns,
                       "an unbounded queue lets a stuck stream bank an unlimited burst of paid turns")
        // Refusing tells the composer to KEEP the text rather than silently eat it.
        XCTAssertFalse(store.enqueueIfBusy(text: "one too many", images: []))
    }

    func testNotStreamingMeansNoQueueing() {
        let store = AgentStore()
        store.isStreaming = false
        XCTAssertFalse(store.enqueueIfBusy(text: "should dispatch instead", images: []),
                       "when idle the turn goes straight out; enqueueIfBusy must decline it")
        XCTAssertTrue(store.queuedTurns.isEmpty)
    }

    func testStartingANewChatDiscardsQueuedTurns() {
        // The queue is conversation-scoped. `drainQueue` only runs inside the stream's
        // `gen == generation` block, so navigating away leaves it orphaned instead of drained —
        // and the next stream to finish, in a DIFFERENT thread, would fire these into it. The
        // user would watch text they typed in one conversation get sent, and billed, in another.
        let store = AgentStore()
        store.isStreaming = true
        XCTAssertTrue(store.enqueueIfBusy(text: "meant for this thread", images: []))
        XCTAssertEqual(store.queuedTurns.count, 1)

        store.newChat()

        XCTAssertEqual(store.queuedTurns.count, 0,
                       "a queued turn must not survive into a different conversation")
        XCTAssertFalse(store.isStreaming)
    }

    func testResetDiscardsQueuedTurns() {
        // Sign-out / account switch. Leaving a queue behind would send one person's drafts
        // from the next session.
        let store = AgentStore()
        store.isStreaming = true
        XCTAssertTrue(store.enqueueIfBusy(text: "private draft", images: []))

        store.reset()

        XCTAssertEqual(store.queuedTurns.count, 0)
    }
}
