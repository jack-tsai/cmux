import Foundation
import Combine

/// Central store of Claude Code session stats, keyed by `surface_id`.
/// Updated via cmuxd socket routes `claude.statusline` and `claude.compact`;
/// read by sidebar UI via per-row value snapshots (CLAUDE.md "snapshot
/// boundary" rule).
@MainActor
final class ClaudeStatsStore: ObservableObject {

    /// Shared instance wired in from `AppDelegate` / cmuxd socket route.
    static let shared = ClaudeStatsStore()

    @Published private(set) var snapshots: [UUID: ClaudeStatsSnapshot] = [:]
    @Published private(set) var compactCounts: [String: ClaudeCompactCountEntry] = [:]

    private let persistence: ClaudeCompactCountPersistence

    init(persistence: ClaudeCompactCountPersistence = ClaudeCompactCountPersistence()) {
        self.persistence = persistence
        self.compactCounts = persistence.load()
    }

    // MARK: - Ingest

    /// Called from the cmuxd socket route after it parses a
    /// `claude.statusline` envelope. Updates the snapshot map on main actor.
    /// The caller is responsible for hopping to main before invoking this
    /// (see `DispatchQueue.main.async` in `TerminalController`).
    func ingestStatusline(
        surfaceId: UUID,
        sessionId: String,
        payload: ClaudeStatsStatuslinePayload,
        receivedAt: Date = Date()
    ) {
        let snap = ClaudeStatsSnapshot(
            surfaceId: surfaceId,
            sessionId: sessionId,
            receivedAt: receivedAt,
            payload: payload
        )
        snapshots[surfaceId] = snap
    }

    /// Called from the cmuxd socket route when a `PreCompact` hook fires.
    /// Increments the per-session counter and schedules a debounced disk flush.
    func incrementCompact(sessionId: String, now: Date = Date()) {
        var entry = compactCounts[sessionId] ?? ClaudeCompactCountEntry(count: 0, lastSeen: now)
        entry.count += 1
        entry.lastSeen = now
        compactCounts[sessionId] = entry
        persistence.scheduleFlush(compactCounts)
    }

    // MARK: - Query

    func snapshot(forSurface surfaceId: UUID) -> ClaudeStatsSnapshot? {
        snapshots[surfaceId]
    }

    func compactCount(for sessionId: String) -> Int {
        compactCounts[sessionId]?.count ?? 0
    }

    // MARK: - Test hooks

    /// Test-only helper to synthesize a snapshot with an older receivedAt,
    /// exercising `isStale` paths.
    @inline(never)
    func _testInjectSnapshot(_ snap: ClaudeStatsSnapshot) {
        snapshots[snap.surfaceId] = snap
    }
}
