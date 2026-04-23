import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers spec `claude-compact-tracking` scenarios:
/// - Per-session counter increments
/// - Counter is per-session, not per-tab (session_id key)
/// - Disk persistence round-trip (new + legacy formats)
/// - LRU prune at 500 entries
@MainActor
final class ClaudeCompactCounterTests: XCTestCase {

    // MARK: - In-memory semantics

    func testIncrementCompact_firstEventReturnsOne() {
        let store = makeStore()
        store.incrementCompact(sessionId: "S1")
        XCTAssertEqual(store.compactCount(for: "S1"), 1)
    }

    func testIncrementCompact_multipleEventsAccumulate() {
        let store = makeStore()
        store.incrementCompact(sessionId: "S1")
        store.incrementCompact(sessionId: "S1")
        store.incrementCompact(sessionId: "S1")
        XCTAssertEqual(store.compactCount(for: "S1"), 3)
    }

    func testIncrementCompact_perSessionNotPerTab() {
        let store = makeStore()
        store.incrementCompact(sessionId: "S1")
        store.incrementCompact(sessionId: "S1")
        store.incrementCompact(sessionId: "S2") // different session, same "tab" concept
        XCTAssertEqual(store.compactCount(for: "S1"), 2)
        XCTAssertEqual(store.compactCount(for: "S2"), 1)
    }

    // MARK: - Persistence

    func testPersistence_newFormatRoundTrip() throws {
        let url = Self.tmpFileURL()
        let persistence = ClaudeCompactCountPersistence(fileURL: url, maxEntries: 500, flushDebounce: 0)
        persistence.flushNow([
            "S1": ClaudeCompactCountEntry(count: 4, lastSeen: Date(timeIntervalSince1970: 1_000_000)),
            "S2": ClaudeCompactCountEntry(count: 7, lastSeen: Date(timeIntervalSince1970: 2_000_000)),
        ])
        let loaded = persistence.load()
        XCTAssertEqual(loaded["S1"]?.count, 4)
        XCTAssertEqual(loaded["S2"]?.count, 7)
    }

    func testPersistence_legacyFlatFormatMigratesOnLoad() throws {
        let url = Self.tmpFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let legacy = Data(#"{"S_legacy": 5}"#.utf8)
        try legacy.write(to: url)
        let persistence = ClaudeCompactCountPersistence(fileURL: url)
        let now = Date()
        let loaded = persistence.load(now: now)
        XCTAssertEqual(loaded["S_legacy"]?.count, 5)
        XCTAssertEqual(loaded["S_legacy"]?.lastSeen, now)
    }

    func testStoreRestart_reloadsPersistedCounts() throws {
        let url = Self.tmpFileURL()
        let persistence1 = ClaudeCompactCountPersistence(fileURL: url, flushDebounce: 0)
        persistence1.flushNow([
            "S1": ClaudeCompactCountEntry(count: 9, lastSeen: Date())
        ])

        let persistence2 = ClaudeCompactCountPersistence(fileURL: url)
        let store = ClaudeStatsStore(persistence: persistence2)
        XCTAssertEqual(store.compactCount(for: "S1"), 9)
    }

    // MARK: - LRU prune

    func testLRUPrune_below500_noOp() {
        var entries: [String: ClaudeCompactCountEntry] = [:]
        for i in 0..<200 {
            entries["s\(i)"] = ClaudeCompactCountEntry(
                count: 1, lastSeen: Date(timeIntervalSince1970: Double(i))
            )
        }
        let pruned = ClaudeCompactCountPersistence.applyLRUPrune(entries, maxEntries: 500)
        XCTAssertEqual(pruned.count, 200)
    }

    func testLRUPrune_above500_dropsOldest() {
        var entries: [String: ClaudeCompactCountEntry] = [:]
        for i in 0..<550 {
            entries["s\(i)"] = ClaudeCompactCountEntry(
                count: 1, lastSeen: Date(timeIntervalSince1970: Double(i))
            )
        }
        let pruned = ClaudeCompactCountPersistence.applyLRUPrune(entries, maxEntries: 500)
        XCTAssertEqual(pruned.count, 500)
        // The 50 oldest (s0..s49) should be gone; s50 onward retained.
        XCTAssertNil(pruned["s0"])
        XCTAssertNil(pruned["s49"])
        XCTAssertNotNil(pruned["s50"])
        XCTAssertNotNil(pruned["s549"])
    }

    func testLRUPrune_touchingRefreshesLastSeen() {
        var entries: [String: ClaudeCompactCountEntry] = [:]
        for i in 0..<500 {
            entries["s\(i)"] = ClaudeCompactCountEntry(
                count: 1, lastSeen: Date(timeIntervalSince1970: Double(i))
            )
        }
        // Touch the oldest entry ("s0") — simulate `incrementCompact("s0")`.
        entries["s0"] = ClaudeCompactCountEntry(
            count: 2, lastSeen: Date(timeIntervalSince1970: 10_000)
        )
        // Add one new entry ("s_new") so we overflow.
        entries["s_new"] = ClaudeCompactCountEntry(
            count: 1, lastSeen: Date(timeIntervalSince1970: 10_001)
        )
        let pruned = ClaudeCompactCountPersistence.applyLRUPrune(entries, maxEntries: 500)
        XCTAssertEqual(pruned.count, 500)
        XCTAssertNotNil(pruned["s0"], "s0 was just touched — must not be evicted")
        XCTAssertNil(pruned["s1"], "s1 is now the oldest and should be evicted")
    }

    // MARK: - Helpers

    private func makeStore() -> ClaudeStatsStore {
        let url = Self.tmpFileURL()
        let persistence = ClaudeCompactCountPersistence(fileURL: url, flushDebounce: 0)
        return ClaudeStatsStore(persistence: persistence)
    }

    private static func tmpFileURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
        return tmp.appendingPathComponent("claude-compact-\(UUID().uuidString).json")
    }
}
