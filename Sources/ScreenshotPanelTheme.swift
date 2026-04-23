import AppKit
import SwiftUI

/// Theme palette for the screenshot panel, derived once per
/// `com.cmuxterm.themes.reload-config` notification.
/// Follows the same pattern as `ClaudeStatsTheme` / `GitGraphTheme` so we never
/// pay ColorSync per row body pass.
struct ScreenshotPanelTheme: Equatable {
    let background: Color
    let foreground: Color
    /// ~72 % fg mix — primary non-heading text (filename).
    let dim: Color
    /// ~40 % fg mix — secondary / faint text (relative time, truncated footer).
    let faint: Color
    /// ~14 % fg mix — divider lines.
    let divider: Color
    /// Accent color used for the selection outline.
    let selection: Color
    /// Cell background / placeholder tint.
    let cellBackground: Color

    static func make(from config: GhosttyConfig) -> ScreenshotPanelTheme {
        let bg = config.backgroundColor
        let fg = config.foregroundColor
        let isDark = !bg.isLightColor

        let dim = fg.blended(withFraction: 0.28, of: bg) ?? fg
        let faint = fg.blended(withFraction: 0.60, of: bg) ?? fg
        let divider = fg.blended(withFraction: 0.86, of: bg) ?? fg
        let cellBg = fg.blended(withFraction: 0.92, of: bg) ?? fg

        // Selection uses palette[4] (ANSI blue) when available, else accent fallback.
        let selection: Color
        if let palette4 = config.palette[4] {
            selection = Color(nsColor: palette4)
        } else {
            selection = isDark
                ? Color(red: 0.26, green: 0.56, blue: 0.92)
                : Color(red: 0.15, green: 0.40, blue: 0.75)
        }

        return ScreenshotPanelTheme(
            background: Color(nsColor: bg),
            foreground: Color(nsColor: fg),
            dim: Color(nsColor: dim),
            faint: Color(nsColor: faint),
            divider: Color(nsColor: divider),
            selection: selection,
            cellBackground: Color(nsColor: cellBg)
        )
    }
}
