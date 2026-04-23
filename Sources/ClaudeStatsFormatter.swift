import Foundation

/// String formatters used by the sidebar Claude stats UI. All pure so they
/// run in unit tests without touching locales or timers.
enum ClaudeStatsFormatter {

    // MARK: - Tokens

    /// "123" / "1.2K" / "1.8M" / "47.3M" — no trailing zeros, one decimal
    /// above 1 K.
    static func formatTokens(_ value: Int) -> String {
        if value < 0 { return "0" }
        if value < 1_000 { return String(value) }
        let absValue = Double(value)
        if absValue < 1_000_000 {
            let k = absValue / 1_000
            return trimmingDecimal(k) + "K"
        }
        if absValue < 1_000_000_000 {
            let m = absValue / 1_000_000
            return trimmingDecimal(m) + "M"
        }
        let b = absValue / 1_000_000_000
        return trimmingDecimal(b) + "B"
    }

    private static func trimmingDecimal(_ value: Double) -> String {
        // 1.00 → "1"; 1.20 → "1.2"; 1.25 → "1.3" (rounded to 1 dp).
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    // MARK: - Percent

    /// Rounds to an integer. 28.4 → 28, 28.6 → 29. Clamps to [0, 100] so UI
    /// bars don't overflow when Claude Code reports >100 in edge cases.
    static func formatPercent(_ value: Double) -> String {
        let clamped = max(0, min(100, value))
        return "\(Int(clamped.rounded()))%"
    }

    // MARK: - Reset countdown

    /// Format the time remaining until `unixEpoch` relative to `now`.
    /// Rules (per spec `claude-stats-sidebar`):
    /// - < 1 minute                    → "0h00m"
    /// - < 24 hours                    → "HhMm"  (e.g. "0h40m", "23h05m")
    /// - ≥ 24 hours                    → "DdHh" (e.g. "1d19h", "2d06h")
    /// - already past                  → "now"
    static func formatResetRemaining(unixEpoch: Int, now: Date = Date()) -> String {
        let remaining = TimeInterval(unixEpoch) - now.timeIntervalSince1970
        if remaining <= 0 { return "now" }
        let totalMinutes = Int(remaining / 60)
        if totalMinutes < 60 * 24 {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return "\(hours)h\(String(format: "%02d", mins))m"
        }
        let totalHours = Int(remaining / 3600)
        let days = totalHours / 24
        let hours = totalHours % 24
        return "\(days)d\(String(format: "%02d", hours))h"
    }

    // MARK: - Model short name

    /// Spec `claude-stats-sidebar` — inline-row model segment:
    /// `claude-opus-*` → "opus", `claude-sonnet-*` → "son",
    /// `claude-haiku-*` → "hai"; anything else → nil (caller omits segment).
    static func shortModelName(from modelId: String?) -> String? {
        guard let id = modelId?.lowercased() else { return nil }
        if id.hasPrefix("claude-opus") { return "opus" }
        if id.hasPrefix("claude-sonnet") { return "son" }
        if id.hasPrefix("claude-haiku") { return "hai" }
        return nil
    }
}
