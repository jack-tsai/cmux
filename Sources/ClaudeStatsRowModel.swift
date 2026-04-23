import Foundation

/// Value-type snapshots for sidebar Claude stats rendering. Per CLAUDE.md
/// "snapshot boundary" rule, every row subview in the sidebar LazyVStack MUST
/// receive immutable snapshots — never a reference to `ClaudeStatsStore` or
/// another `ObservableObject`.

// MARK: - Full block (focused workspace row)

struct ClaudeStatsBlockSnapshot: Equatable, Hashable {
    /// Left side of tokens row — all-time session total, formatted.
    let tokensTotalLabel: String
    /// Right side of tokens row — current-usage breakdown or "session NK".
    let tokensSessionLabel: String

    struct BarRow: Equatable, Hashable {
        /// Percentage used, 0…100. Drives the bar fill width.
        let percent: Double
        /// "28%" — pre-formatted right-hand value.
        let percentLabel: String
        /// "compact 0×" / "0h40m" / "1d19h" — the extra segment after percent.
        let extraLabel: String
    }

    let ctx: BarRow
    /// 5-hour quota row; nil when `rate_limits` absent (free-tier user).
    let fiveHour: BarRow?
    /// 7-day quota row; nil under the same condition.
    let sevenDay: BarRow?

    /// Non-nil when we should render the free-tier helper hint instead of the
    /// 5h/7d rows. Set only when the snapshot is a free-tier session.
    let freeTierHint: String?

    let isStale: Bool
}

// MARK: - Inline (unfocused workspace row)

struct ClaudeStatsInlineSnapshot: Equatable, Hashable {
    /// `nil` when model id is unknown — caller omits the model segment.
    let modelShort: String?
    let ctxPercent: Double?
    let fiveHourPercent: Double?
    let sevenDayPercent: Double?
    let isStale: Bool

    /// True when we have at least one numeric field to show — otherwise
    /// caller renders nothing.
    var hasAnyContent: Bool {
        ctxPercent != nil || fiveHourPercent != nil || sevenDayPercent != nil
    }
}
