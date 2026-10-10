import XCTest
@testable import Claudemeter

final class UsageResponseParserTests: XCTestCase {
    // Shape derived from CodexBar's decoder; replace with a real (token-free) dump once captured.
    private let fixture = """
    {
      "five_hour": {"utilization": 8.0, "resets_at": "2026-10-10T09:39:59.852Z"},
      "seven_day": {"utilization": 41.0, "resets_at": "2026-10-11T18:59:59.852Z"},
      "seven_day_opus": {"utilization": null, "resets_at": null},
      "limits": [
        {"kind": "weekly_scoped", "group": "weekly", "percent": 4.0, "resets_at": "2026-10-11T18:59:59Z",
         "scope": {"model": {"id": "claude-fable-5-1", "display_name": "Fable"}}, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 41.0, "resets_at": "2026-10-11T18:59:59Z",
         "scope": {"model": {"id": "all", "display_name": "All models"}}},
        {"kind": "session", "group": "session", "percent": 8.0}
      ],
      "extra_usage": {"is_enabled": true, "monthly_limit": 200.0, "used_credits": 0.0, "utilization": 0.0, "currency": "USD"}
    }
    """

    func testParsesKnownWindowsInOrder() throws {
        let snapshot = try UsageResponseParser.parse(Data(fixture.utf8))
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "limit:claude-fable-5-1"])
        XCTAssertEqual(snapshot.fiveHour?.utilization, 8)
        XCTAssertEqual(snapshot.sevenDay?.utilization, 41)
        XCTAssertEqual(snapshot.windows[2].shortLabel, "Fable")
        XCTAssertEqual(snapshot.windows[2].title, "週次 · Fable")
        XCTAssertEqual(snapshot.maxUtilization, 41)
    }

    func testParsesResetDatesWithAndWithoutFractionalSeconds() throws {
        let snapshot = try UsageResponseParser.parse(Data(fixture.utf8))
        XCTAssertEqual(snapshot.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0, 1_791_625_199.852, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[2].resetsAt?.timeIntervalSince1970 ?? 0, 1_791_745_199, accuracy: 0.001)
    }

    func testParsesExtraUsage() throws {
        let snapshot = try UsageResponseParser.parse(Data(fixture.utf8))
        XCTAssertEqual(snapshot.extraUsage?.isEnabled, true)
        XCTAssertEqual(snapshot.extraUsage?.monthlyLimit, 200)
        XCTAssertEqual(snapshot.extraUsage?.currency, "USD")
    }

    func testSevenDayModelKeyWinsOverDuplicateLimitEntry() throws {
        let json = """
        {"five_hour": {"utilization": 1}, "seven_day": {"utilization": 2},
         "seven_day_fable": {"utilization": 3, "resets_at": "2026-10-11T18:59:59Z"},
         "limits": [{"kind": "weekly_scoped", "group": "weekly", "percent": 99,
                     "scope": {"model": {"id": "x", "display_name": "fable"}}}]}
        """
        let snapshot = try UsageResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(snapshot.windows[2].utilization, 3)
    }

    func testThrowsWhenNoWindows() {
        XCTAssertThrowsError(try UsageResponseParser.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try UsageResponseParser.parse(Data("[]".utf8)))
    }
}

final class SessionLogWatcherTests: XCTestCase {
    func testOnlyProjectTranscriptsCount() {
        XCTAssertTrue(SessionLogWatcher.isSessionLog("/Users/x/.claude/projects/-Users-x-app/abc.jsonl"))
        XCTAssertFalse(SessionLogWatcher.isSessionLog("/Users/x/.claude/history.jsonl"))
        XCTAssertFalse(SessionLogWatcher.isSessionLog("/Users/x/.claude/projects/-Users-x-app/notes.txt"))
    }
}
