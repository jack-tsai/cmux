import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers `ClaudeStatsStatuslinePayload` decoding + `ClaudeStatsStore.ingestStatusline`.
/// Corresponds to spec `claude-statusline-ingest`: Valid statusline message is
/// received, Schema tolerance for Claude Code version drift, Staleness flag.
@MainActor
final class StatuslineIngestTests: XCTestCase {

    // MARK: - Decode

    func testDecode_fullPayload_allFieldsPopulated() throws {
        let json = Data(#"""
        {
          "cwd": "/work/repo",
          "session_id": "abc-123",
          "transcript_path": "/path/to/transcript.jsonl",
          "model": { "id": "claude-opus-4-7", "display_name": "Opus" },
          "workspace": { "current_dir": "/work/repo", "project_dir": "/work" },
          "version": "2.1.90",
          "cost": { "total_cost_usd": 0.012, "total_duration_ms": 45000,
                    "total_api_duration_ms": 2300, "total_lines_added": 156,
                    "total_lines_removed": 23 },
          "context_window": {
            "total_input_tokens": 15234,
            "total_output_tokens": 4521,
            "context_window_size": 200000,
            "used_percentage": 8,
            "remaining_percentage": 92,
            "current_usage": {
              "input_tokens": 8500, "output_tokens": 1200,
              "cache_creation_input_tokens": 5000, "cache_read_input_tokens": 2000
            }
          },
          "exceeds_200k_tokens": false,
          "rate_limits": {
            "five_hour":  { "used_percentage": 23.5, "resets_at": 1738425600 },
            "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(ClaudeStatsStatuslinePayload.self, from: json)
        XCTAssertEqual(decoded.sessionId, "abc-123")
        XCTAssertEqual(decoded.model?.id, "claude-opus-4-7")
        XCTAssertEqual(decoded.model?.displayName, "Opus")
        XCTAssertEqual(decoded.contextWindow?.usedPercentage, 8)
        XCTAssertEqual(decoded.contextWindow?.currentUsage?.cacheReadInputTokens, 2000)
        XCTAssertEqual(decoded.rateLimits?.fiveHour?.usedPercentage, 23.5)
        XCTAssertEqual(decoded.rateLimits?.sevenDay?.resetsAt, 1738857600)
    }

    func testDecode_freeTierMissingRateLimits_decodesWithNilRateLimits() throws {
        let json = Data(#"""
        {
          "session_id": "free-1",
          "context_window": { "used_percentage": 42 }
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(ClaudeStatsStatuslinePayload.self, from: json)
        XCTAssertEqual(decoded.sessionId, "free-1")
        XCTAssertEqual(decoded.contextWindow?.usedPercentage, 42)
        XCTAssertNil(decoded.rateLimits)
    }

    func testDecode_unknownTopLevelField_isIgnored() throws {
        // Forward-compat: a new Claude Code version adds "some_new_feature".
        // We must still decode all the known fields.
        let json = Data(#"""
        {
          "session_id": "x",
          "some_new_feature": { "nested": true, "values": [1,2,3] },
          "context_window": { "used_percentage": 12 }
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(ClaudeStatsStatuslinePayload.self, from: json)
        XCTAssertEqual(decoded.sessionId, "x")
        XCTAssertEqual(decoded.contextWindow?.usedPercentage, 12)
    }

    // MARK: - Store ingest

    func testIngestStatusline_writesSnapshotByTab() {
        let store = ClaudeStatsStore(persistence: ClaudeCompactCountPersistence(fileURL: Self.tmpFileURL()))
        let surface = UUID()
        let payload = ClaudeStatsStatuslinePayload(
            sessionId: "s1",
            contextWindow: .init(
                totalInputTokens: 100, totalOutputTokens: 50,
                contextWindowSize: 200000, usedPercentage: 1,
                remainingPercentage: 99, currentUsage: nil
            )
        )
        store.ingestStatusline(surfaceId: surface, sessionId: "s1", payload: payload)
        XCTAssertEqual(store.snapshot(forSurface: surface)?.sessionId, "s1")
        XCTAssertEqual(store.snapshot(forSurface: surface)?.payload.contextWindow?.usedPercentage, 1)
    }

    func testIngestStatusline_latestWins() {
        let store = ClaudeStatsStore(persistence: ClaudeCompactCountPersistence(fileURL: Self.tmpFileURL()))
        let surface = UUID()
        let first = ClaudeStatsStatuslinePayload(sessionId: "s", contextWindow: .init(totalInputTokens: nil, totalOutputTokens: nil, contextWindowSize: nil, usedPercentage: 10, remainingPercentage: nil, currentUsage: nil))
        let second = ClaudeStatsStatuslinePayload(sessionId: "s", contextWindow: .init(totalInputTokens: nil, totalOutputTokens: nil, contextWindowSize: nil, usedPercentage: 20, remainingPercentage: nil, currentUsage: nil))
        store.ingestStatusline(surfaceId: surface, sessionId: "s", payload: first)
        store.ingestStatusline(surfaceId: surface, sessionId: "s", payload: second)
        XCTAssertEqual(store.snapshot(forSurface: surface)?.payload.contextWindow?.usedPercentage, 20)
    }

    // MARK: - Staleness

    func testSnapshotIsStale_after30Seconds() {
        let surface = UUID()
        let ancient = Date(timeIntervalSinceNow: -35)
        let snap = ClaudeStatsSnapshot(
            surfaceId: surface, sessionId: "s",
            receivedAt: ancient,
            payload: ClaudeStatsStatuslinePayload(sessionId: "s")
        )
        XCTAssertTrue(snap.isStale())
    }

    func testSnapshotIsFresh_within30Seconds() {
        let surface = UUID()
        let snap = ClaudeStatsSnapshot(
            surfaceId: surface, sessionId: "s",
            receivedAt: Date(timeIntervalSinceNow: -5),
            payload: ClaudeStatsStatuslinePayload(sessionId: "s")
        )
        XCTAssertFalse(snap.isStale())
    }

    // MARK: - Helpers

    private static func tmpFileURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
        return tmp.appendingPathComponent("claude-compact-\(UUID().uuidString).json")
    }
}
