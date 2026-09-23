//
//  DrainAllTests.swift
//  CommandTests
//
//  `drainAll` exists because the stores used to read only the first page, which made a user's
//  older notes/tasks/log silently invisible in-app. Its loop guard therefore matters: it is the
//  thing standing between "load everything" and either an infinite loop or a silent truncation.
//
//  The guard used to be a page count alone, which conflated two unrelated hazards — a server
//  handing back a cursor that never advances, and simply having more data than we hold in memory.
//  A count "handles" the first only by spending 50 identical requests first.
//

import XCTest
@testable import Command

final class DrainAllTests: XCTestCase {

    private func client() -> APIClient {
        APIClient(baseURL: URL(string: "http://stub.invalid")!)
    }

    func testDrainsEveryPageAndStopsOnANilCursor() async throws {
        let pages: [Page<Int>] = [
            Page(items: [1, 2], nextCursor: "b"),
            Page(items: [3, 4], nextCursor: "c"),
            Page(items: [5], nextCursor: nil),
        ]
        var calls = 0
        let all = try await client().drainAll(pageSize: 2) { _, _ in
            defer { calls += 1 }
            return pages[calls]
        }
        XCTAssertEqual(all, [1, 2, 3, 4, 5])
        XCTAssertEqual(calls, 3, "one request per page, no trailing request after a nil cursor")
    }

    func testACursorThatNeverAdvancesStopsImmediatelyInsteadOfBurning50Requests() async throws {
        // A server bug that keeps returning the same cursor. The old count-only guard made 50
        // identical requests before giving up; repeats are detectable on sight.
        var calls = 0
        let all = try await client().drainAll(pageSize: 2) { _, _ in
            calls += 1
            return Page(items: [calls], nextCursor: "stuck")
        }
        XCTAssertEqual(calls, 2, "the repeat must be caught the second time the cursor appears")
        XCTAssertEqual(all, [1, 2], "pages fetched before the repeat was detected are still kept")
    }

    func testAnEndlesslyAdvancingCursorIsStillBoundedByThePageCap() async throws {
        // The other hazard: a cursor that does advance, forever. That is what the page cap is
        // actually for, and it must still bite.
        var calls = 0
        let all = try await client().drainAll(pageSize: 1) { _, _ in
            calls += 1
            return Page(items: [calls], nextCursor: "cursor-\(calls)")
        }
        XCTAssertEqual(calls, APIClient.maxDrainPages)
        XCTAssertEqual(all.count, APIClient.maxDrainPages)
    }

    func testAnEmptyFirstPageDrainsToNothingWithoutASecondRequest() async throws {
        var calls = 0
        let all: [Int] = try await client().drainAll { _, _ in
            calls += 1
            return Page(items: [], nextCursor: nil)
        }
        XCTAssertEqual(all, [])
        XCTAssertEqual(calls, 1)
    }
}
