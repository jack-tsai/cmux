import AppKit
import SwiftUI

/// Theme palette for the sidebar Claude stats block + inline row. Derived
/// from the active ghostty config, mirroring `GitGraphTheme.make(from:)`'s
/// shape. Cache the result in SwiftUI `@State` and recompute only on the
/// `com.cmuxterm.themes.reload-config` notification so we never pay ColorSync
/// per row body pass (CLAUDE.md "Never derive theme palettes as computed
/// properties").
struct ClaudeStatsTheme: Equatable {
    /// Background of the row / stats block.
    let background: Color
    /// Primary foreground text.
    let foreground: Color
    /// 72 % mix — used for stats body numbers and labels that are not faint.
    let dim: Color
    /// 40 % mix — used for "stale" suffix, muted labels.
    let faint: Color
    /// 14 % mix — divider above the stats block.
    let divider: Color
    /// 10 % mix — empty portion of progress bars.
    let barTrack: Color

    /// Default bar fill (< 60 %). Pulled from `palette[4]` (ANSI blue).
    let barDefault: Color
    /// Warn bar fill (60–84 %). Pulled from `palette[3]` (ANSI yellow).
    let barWarn: Color
    /// Danger bar fill (≥ 85 %). Pulled from `palette[1]` (ANSI red).
    let barDanger: Color

    /// Threshold boundaries — exposed so tests can assert exact cutoffs.
    static let warnThreshold: Double = 60
    static let dangerThreshold: Double = 85

    /// Pick the bar fill color for a given usage percentage. Pure so tests can
    /// round-trip. Corresponds to spec `claude-stats-sidebar` "Color
    /// thresholds derived from ghostty palette".
    static func thresholdColor(
        for percentage: Double,
        barDefault: Color,
        barWarn: Color,
        barDanger: Color
    ) -> Color {
        if percentage >= Self.dangerThreshold { return barDanger }
        if percentage >= Self.warnThreshold { return barWarn }
        return barDefault
    }

    func thresholdColor(for percentage: Double) -> Color {
        Self.thresholdColor(
            for: percentage,
            barDefault: barDefault,
            barWarn: barWarn,
            barDanger: barDanger
        )
    }

    static func make(from config: GhosttyConfig) -> ClaudeStatsTheme {
        let bg = config.backgroundColor
        let fg = config.foregroundColor
        let isDark = !bg.isLightColor

        // fg ⨉ factor blended over bg matches the GitGraphTheme dim / faint
        // derivation (see design table "Theme color mapping").
        let dim = fg.blended(withFraction: 0.28, of: bg) ?? fg
        let faint = fg.blended(withFraction: 0.60, of: bg) ?? fg
        let divider = fg.blended(withFraction: 0.86, of: bg) ?? fg // ~14 % fg
        let barTrack = fg.blended(withFraction: 0.90, of: bg) ?? fg // ~10 % fg

        // ANSI fallbacks if the ghostty palette doesn't populate a slot.
        func ansi(_ index: Int) -> Color {
            if let c = config.palette[index] { return Color(nsColor: c) }
            return ClaudeStatsTheme.ansiFallback(index: index, onDark: isDark)
        }

        return ClaudeStatsTheme(
            background: Color(nsColor: bg),
            foreground: Color(nsColor: fg),
            dim: Color(nsColor: dim),
            faint: Color(nsColor: faint),
            divider: Color(nsColor: divider),
            barTrack: Color(nsColor: barTrack),
            barDefault: ansi(4),
            barWarn: ansi(3),
            barDanger: ansi(1)
        )
    }

    // Mirror of GitGraphTheme.ansiFallback — kept in sync so both panels look
    // coherent under themes that leave slots blank.
    private static func ansiFallback(index: Int, onDark: Bool) -> Color {
        let dark: [Color] = [
            .black,
            Color(red: 0.80, green: 0.27, blue: 0.30),
            Color(red: 0.40, green: 0.78, blue: 0.31),
            Color(red: 0.84, green: 0.73, blue: 0.18),
            Color(red: 0.26, green: 0.56, blue: 0.92),
            Color(red: 0.67, green: 0.33, blue: 0.83),
            Color(red: 0.24, green: 0.74, blue: 0.78)
        ]
        let light: [Color] = [
            .black,
            Color(red: 0.70, green: 0.18, blue: 0.22),
            Color(red: 0.20, green: 0.55, blue: 0.23),
            Color(red: 0.65, green: 0.52, blue: 0.09),
            Color(red: 0.15, green: 0.40, blue: 0.75),
            Color(red: 0.55, green: 0.24, blue: 0.70),
            Color(red: 0.10, green: 0.55, blue: 0.60)
        ]
        let palette = onDark ? dark : light
        return palette[max(0, min(palette.count - 1, index))]
    }
}
