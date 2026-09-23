//
//  CalendarDragTests.swift
//  CommandTests
//
//  Dragging a one-off to another day must move its end with its start.
//

import XCTest
@testable import Command

final class CalendarDragTests: XCTestCase {
    func test_shiftedEnd_keepsTheDuration() throws {
        let newStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T10:00:00Z"))
        let end = CalendarStore.shiftedEnd(start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:30:00Z", to: newStart)
        XCTAssertEqual(end.map { ISO8601DateFormatter().string(from: $0) }, "2026-08-12T11:30:00Z")
    }

    func test_shiftedEnd_isNilWithoutAnEnd() throws {
        let newStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T10:00:00Z"))
        XCTAssertNil(CalendarStore.shiftedEnd(start: "2026-08-10T10:00:00Z", end: nil, to: newStart))
    }
}
