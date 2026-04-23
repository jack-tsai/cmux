import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the full-block + inline aggregation rules from spec
/// `claude-stats-sidebar`. Pure function tests — no UI, no store.
final class ClaudeStatsAggregatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeSnapshot(
        surfaceId: UUID = UUID(),
        sessionId: String = "s",
        modelId: String? = "claude-opus-4-7",
        ctx: Double? = 28,
        fiveHour: (pct: Double, resetsAt: Int)? = (23, 1_000_000_000 + 40 * 60),
        sevenDay: (pct: Double, resetsAt: Int)? = (38, 1_000_000_000 + (24 * 3600) + (19 * 3600)),
        tokensIn: Int = 1_000,
        tokensOut: Int = 500,
        receivedAgo: TimeInterval = 1
    ) -> ClaudeStatsSnapshot {
        let payload = ClaudeStatsStatuslinePayload(
            sessionId: sessionId,
            model: modelId.map { ClaudeStatsStatuslinePayload.ModelInfo(id: $0, displayName: nil) },
            contextWindow: .init(
                totalInputTokens: tokensIn,
                totalOutputTokens: tokensOut,
                contextWindowSize: 200_000,
                usedPercentage: ctx,
                remainingPercentage: ctx.map { 100 - $0 },
                currentUsage: nil
            ),
            rateLimits: (fiveHour == nil && sevenDay == nil) ? nil : .init(
                fiveHour: fiveHour.map { .init(usedPercentage: $0.pct, resetsAt: $0.resetsAt) },
                sevenDay: sevenDay.map { .init(usedPercentage: $0.pct, resetsAt: $0.resetsAt) }
            )
        )
        return ClaudeStatsSnapshot(
            surfaceId: surfaceId,
            sessionId: sessionId,
            receivedAt: Date(timeIntervalSince1970: 1_000_000_000 - receivedAgo),
            payload: payload
        )
    }

    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    // MARK: - Block

    func testBlock_basicProStatsRoundTrip() {
        let snap = makeSnapshot()
        guard let block = ClaudeStatsAggregator.block(for: snap, now: now) else {
            XCTFail("Expected block for pro-tier snapshot"); return
        }
        XCTAssertEqual(block.ctx.percentLabel, "28%")
        XCTAssertEqual(block.fiveHour?.percentLabel, "23%")
        XCTAssertEqual(block.sevenDay?.percentLabel, "38%")
        XCTAssertEqual(block.fiveHour?.extraLabel, "0h40m")
        XCTAssertEqual(block.sevenDay?.extraLabel, "1d19h")
        XCTAssertNil(block.freeTierHint)
        XCTAssertFalse(block.isStale)
    }

    func testBlock_freeTierUser_noRateLimits_showsHint() {
        let snap = makeSnapshot(fiveHour: nil, sevenDay: nil)
        guard let block = ClaudeStatsAggregator.block(for: snap, now: now) else {
            XCTFail("expected block"); return
        }
        XCTAssertNil(block.fiveHour)
        XCTAssertNil(block.sevenDay)
        XCTAssertEqual(block.freeTierHint, "No quota data (Claude.ai free)")
    }

    func testBlock_staleSnapshot_markedStale() {
        let snap = makeSnapshot(receivedAgo: 40) // > 30 s threshold
        let block = ClaudeStatsAggregator.block(for: snap, now: now)
        XCTAssertEqual(block?.isStale, true)
    }

    func testBlockWithCompactCount_populatesCtxExtra() {
        let base = ClaudeStatsAggregator.block(for: makeSnapshot(), now: now)!
        let withCount = ClaudeStatsAggregator.blockWithCompactCount(base, compactCount: 3)
        XCTAssertEqual(withCount.ctx.extraLabel, "compact 3×")
    }

    // MARK: - Inline

    func testInline_emptySnapshots_returnsNil() {
        XCTAssertNil(ClaudeStatsAggregator.inline(forTabs: [], now: now))
    }

    func testInline_allSnapshotsStale_returnsNil() {
        let stale = makeSnapshot(receivedAgo: 60)
        XCTAssertNil(ClaudeStatsAggregator.inline(forTabs: [stale], now: now))
    }

    func testInline_singleSnapshot_carriesValues() {
        let snap = makeSnapshot(ctx: 62, fiveHour: (78, 1_000_000_000 + 3600),
                                 sevenDay: (38, 1_000_000_000 + 24 * 3600))
        guard let inline = ClaudeStatsAggregator.inline(forTabs: [snap], now: now) else {
            XCTFail("expected inline"); return
        }
        XCTAssertEqual(inline.modelShort, "opus")
        XCTAssertEqual(inline.ctxPercent, 62)
        XCTAssertEqual(inline.fiveHourPercent, 78)
        XCTAssertEqual(inline.sevenDayPercent, 38)
    }

    func testInline_twoTabs_differentModels_maxPerFieldAndMaxCtxModel() {
        let sonnet = makeSnapshot(
            surfaceId: UUID(), modelId: "claude-sonnet-4-6",
            ctx: 30,
            fiveHour: (50, 1_000_000_000 + 3600),
            sevenDay: (20, 1_000_000_000 + 24 * 3600)
        )
        let opus = makeSnapshot(
            surfaceId: UUID(), modelId: "claude-opus-4-7",
            ctx: 75,
            fiveHour: (40, 1_000_000_000 + 3600),
            sevenDay: (55, 1_000_000_000 + 24 * 3600)
        )
        guard let inline = ClaudeStatsAggregator.inline(forTabs: [sonnet, opus], now: now) else {
            XCTFail("expected inline"); return
        }
        XCTAssertEqual(inline.modelShort, "opus", "model follows max-ctx contributor")
        XCTAssertEqual(inline.ctxPercent, 75)
        XCTAssertEqual(inline.fiveHourPercent, 50)
        XCTAssertEqual(inline.sevenDayPercent, 55)
    }

    func testInline_unknownModel_omitsSegment() {
        let snap = makeSnapshot(modelId: "gpt-9")
        let inline = ClaudeStatsAggregator.inline(forTabs: [snap], now: now)
        XCTAssertNil(inline?.modelShort)
    }
}
