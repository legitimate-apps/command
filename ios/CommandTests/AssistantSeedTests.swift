//
//  AssistantSeedTests.swift
//  Command
//
//  "Ask the assistant" from an item's detail view. The seeded question has to identify the
//  record unambiguously — titles are not unique, and an assistant that guesses which "Call
//  Dana" you meant and then acts on the wrong one is worse than one that asks.
//

import XCTest
@testable import Command

final class AssistantSeedTests: XCTestCase {
    private func assignment(id: Int, title: String) -> Assignment {
        Assignment(
            id: id, accountId: 0, goalId: nil, title: title, details: nil, assigneeId: nil,
            scheduleKind: "sporadic", rrule: nil, scheduledStart: nil, scheduledEnd: nil,
            timezone: nil, leadTimeMinutes: nil, status: "todo", priority: 0, hidden: false,
            archivedAt: nil, notes: nil, origin: "manual",
            createdAt: "2026-08-03T00:00:00Z", updatedAt: "2026-08-03T00:00:00Z"
        )
    }

    func testSeedNamesTheRecordAndItsId() {
        let seed = EntityDetailView.assistantPrompt(for: .assignment(assignment(id: 42, title: "Call Dana")))
        XCTAssertTrue(seed.contains("Call Dana"))
        // The id disambiguates duplicates — three "Call Dana" rows are entirely ordinary.
        XCTAssertTrue(seed.contains("42"))
    }

    func testSeedEndsOpenSoTheUserFinishesTheSentence() {
        let seed = EntityDetailView.assistantPrompt(for: .assignment(assignment(id: 1, title: "Thing")))
        XCTAssertTrue(seed.hasSuffix(" "), "the seed is a prefix the user completes, not a question")
        XCTAssertFalse(seed.hasSuffix("?"))
    }

    func testEverySubjectKindProducesADistinctSeed() {
        let goal = Goal(id: 7, accountId: 0, title: "Ship it", description: nil, status: "open",
                        targetDate: nil, notes: nil, createdAt: "2026-08-03T00:00:00Z",
                        updatedAt: "2026-08-03T00:00:00Z")
        let seeds = [
            EntityDetailView.assistantPrompt(for: .assignment(assignment(id: 1, title: "A"))),
            EntityDetailView.assistantPrompt(for: .goal(goal)),
        ]
        XCTAssertEqual(Set(seeds).count, seeds.count, "each kind must name what it is")
        XCTAssertTrue(seeds[0].contains("assignment"))
        XCTAssertTrue(seeds[1].contains("goal"))
    }
}
