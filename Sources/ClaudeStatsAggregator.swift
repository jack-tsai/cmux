import Foundation

/// Pure functions that turn one or more `ClaudeStatsSnapshot`s into
/// UI-ready value snapshots. Tested in isolation so we don't have to stand up
/// `Workspace` / SwiftUI to verify aggregation rules.
enum ClaudeStatsAggregator {

    // MARK: - Full block (focused workspace)

    /// Build the full stats block snapshot for a single focused-tab snapshot.
    /// Returns nil when the caller should render "none" (eg. snapshot missing,
    /// `current_usage` nil AND no context stats — nothing meaningful to show).
    static func block(for snapshot: ClaudeStatsSnapshot, now: Date = Date()) -> ClaudeStatsBlockSnapshot? {
        let payload = snapshot.payload
        guard let ctx = payload.contextWindow else { return nil }

        // Tokens row — left side is session totals, right side is the current
        // call breakdown when available, else fallback to "session NK".
        let totalInput = ctx.totalInputTokens ?? 0
        let totalOutput = ctx.totalOutputTokens ?? 0
        let tokensTotalLabel = "tokens " + ClaudeStatsFormatter.formatTokens(totalInput + totalOutput)
        let tokensSessionLabel: String
        if let usage = ctx.currentUsage {
            let currentInput = usage.inputTokens ?? 0
            let currentOutput = usage.outputTokens ?? 0
            let currentCacheRead = usage.cacheReadInputTokens ?? 0
            let currentCacheCreate = usage.cacheCreationInputTokens ?? 0
            let combined = currentInput + currentOutput + currentCacheRead + currentCacheCreate
            tokensSessionLabel = "session " + ClaudeStatsFormatter.formatTokens(combined)
        } else {
            tokensSessionLabel = "session " + ClaudeStatsFormatter.formatTokens(totalInput + totalOutput)
        }

        // ctx row
        let ctxPercent = ctx.usedPercentage ?? 0
        let ctxRow = ClaudeStatsBlockSnapshot.BarRow(
            percent: ctxPercent,
            percentLabel: ClaudeStatsFormatter.formatPercent(ctxPercent),
            extraLabel: "" // filled by caller (needs compact count from store)
        )

        // Rate limits — absent for free-tier users.
        var fiveHourRow: ClaudeStatsBlockSnapshot.BarRow?
        var sevenDayRow: ClaudeStatsBlockSnapshot.BarRow?
        var freeTierHint: String?

        if let rl = payload.rateLimits {
            if let fh = rl.fiveHour {
                fiveHourRow = .init(
                    percent: fh.usedPercentage ?? 0,
                    percentLabel: ClaudeStatsFormatter.formatPercent(fh.usedPercentage ?? 0),
                    extraLabel: fh.resetsAt.map {
                        ClaudeStatsFormatter.formatResetRemaining(unixEpoch: $0, now: now)
                    } ?? "—"
                )
            }
            if let sd = rl.sevenDay {
                sevenDayRow = .init(
                    percent: sd.usedPercentage ?? 0,
                    percentLabel: ClaudeStatsFormatter.formatPercent(sd.usedPercentage ?? 0),
                    extraLabel: sd.resetsAt.map {
                        ClaudeStatsFormatter.formatResetRemaining(unixEpoch: $0, now: now)
                    } ?? "—"
                )
            }
        } else {
            // Spec: free-tier user sees only tokens + ctx + a helper hint.
            freeTierHint = "No quota data (Claude.ai free)"
        }

        return ClaudeStatsBlockSnapshot(
            tokensTotalLabel: tokensTotalLabel,
            tokensSessionLabel: tokensSessionLabel,
            ctx: ctxRow,
            fiveHour: fiveHourRow,
            sevenDay: sevenDayRow,
            freeTierHint: freeTierHint,
            isStale: snapshot.isStale(now: now)
        )
    }

    /// Fill the `extraLabel` on the ctx bar row with the per-session compact
    /// count. Kept separate so callers can inject a fresh count without
    /// re-running the full block build.
    static func blockWithCompactCount(
        _ block: ClaudeStatsBlockSnapshot,
        compactCount: Int
    ) -> ClaudeStatsBlockSnapshot {
        var mutable = block
        let suffix = "compact \(compactCount)×"
        let ctx = block.ctx
        mutable = ClaudeStatsBlockSnapshot(
            tokensTotalLabel: block.tokensTotalLabel,
            tokensSessionLabel: block.tokensSessionLabel,
            ctx: .init(percent: ctx.percent, percentLabel: ctx.percentLabel, extraLabel: suffix),
            fiveHour: block.fiveHour,
            sevenDay: block.sevenDay,
            freeTierHint: block.freeTierHint,
            isStale: block.isStale
        )
        return mutable
    }

    // MARK: - Inline (unfocused workspace)

    /// Aggregate multiple tab snapshots into a single inline row. Max per
    /// numeric field; model short-name follows the tab contributing max ctx
    /// (tie-breaker: max 5h, then surface_id ascending).
    static func inline(forTabs snapshots: [ClaudeStatsSnapshot], now: Date = Date()) -> ClaudeStatsInlineSnapshot? {
        let fresh = snapshots.filter { !$0.isStale(now: now) }
        guard !fresh.isEmpty else { return nil }

        // Collect per-field max values with their source tab.
        let maxCtxTab = fresh.max { lhs, rhs in
            let lctx = lhs.payload.contextWindow?.usedPercentage ?? -1
            let rctx = rhs.payload.contextWindow?.usedPercentage ?? -1
            if lctx != rctx { return lctx < rctx }
            let l5 = lhs.payload.rateLimits?.fiveHour?.usedPercentage ?? -1
            let r5 = rhs.payload.rateLimits?.fiveHour?.usedPercentage ?? -1
            if l5 != r5 { return l5 < r5 }
            return lhs.surfaceId.uuidString > rhs.surfaceId.uuidString
        }

        let ctxValues = fresh.compactMap { $0.payload.contextWindow?.usedPercentage }
        let fiveValues = fresh.compactMap { $0.payload.rateLimits?.fiveHour?.usedPercentage }
        let sevenValues = fresh.compactMap { $0.payload.rateLimits?.sevenDay?.usedPercentage }

        let modelShort = maxCtxTab.flatMap { snap in
            ClaudeStatsFormatter.shortModelName(from: snap.payload.model?.id)
        }

        return ClaudeStatsInlineSnapshot(
            modelShort: modelShort,
            ctxPercent: ctxValues.max(),
            fiveHourPercent: fiveValues.max(),
            sevenDayPercent: sevenValues.max(),
            isStale: false
        )
    }
}
