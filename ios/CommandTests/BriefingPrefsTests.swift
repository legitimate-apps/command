//
//  BriefingPrefsTests.swift
//  Command
//
//  The client half of proactive briefings. The server owns the truth; what's tested here is
//  the decoding contract (snake_case ↔ camelCase, which is where a silently-ignored setting
//  would come from) and the defaults, since "off unless the user asked" is a promise.
//

import XCTest
@testable import Command

final class BriefingPrefsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    func testDefaultsAreOff() {
        // A release must never start pushing at people who didn't ask.
        XCTAssertFalse(BriefingPrefs().enabled)
    }

    func testDecodesTheServerShape() throws {
        let prefs = try decode(BriefingPrefs.self, """
        {"enabled": true, "cadence": "weekdays", "hour_local": 7,
         "kinds": {"due_today": true, "overdue": false, "blocked": true, "unprocessed_notes": true}}
        """)
        XCTAssertTrue(prefs.enabled)
        XCTAssertEqual(prefs.cadence, "weekdays")
        // hour_local -> hourLocal is exactly the mapping that would silently drop the setting.
        XCTAssertEqual(prefs.hourLocal, 7)
        XCTAssertEqual(prefs.kinds["overdue"], false)
    }

    func testDecodesTheSettingsEnvelope() throws {
        let response = try decode(BriefingSettingsResponse.self, """
        {"briefings": {"enabled": false, "cadence": "daily", "hour_local": 8, "kinds": {}}}
        """)
        XCTAssertFalse(response.briefings.enabled)
        XCTAssertEqual(response.briefings.hourLocal, 8)
    }

    func testPatchOmitsUntouchedFields() throws {
        // A partial update must not send nulls that would clobber other settings.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(BriefingPrefsPatch(enabled: true))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("enabled"))
        XCTAssertFalse(json.contains("cadence"), "an untouched field must not be transmitted")
        XCTAssertFalse(json.contains("hour_local"))
    }

    func testEveryKindHasAHumanLabel() {
        for kind in BriefingPrefs.kindOrder {
            XCTAssertFalse(BriefingPrefs.label(for: kind).isEmpty)
            XCTAssertNotEqual(BriefingPrefs.label(for: kind), kind, "\(kind) is showing its raw key")
        }
    }

    func testHourLabelsCoverTheWholeDay() {
        let labels = (0..<24).map { AccountView.hourLabel($0) }
        XCTAssertEqual(Set(labels).count, 24, "every hour needs a distinct label")
    }
}
