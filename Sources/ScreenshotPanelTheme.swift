import AppKit
import SwiftUI

/// Theme palette for the screenshot panel.
///
/// Previously derived from GhosttyConfig so panel colors matched terminal
/// colors. That worked for dark terminal themes but ignored macOS Appearance
/// entirely — users in Light Mode still saw a dark panel when their ghostty
/// theme was dark, and it looked inconsistent with the sibling FileExplorer /
/// Sessions panels which use `Color(.windowBackgroundColor)` / `Color.primary`
/// and therefore flip with system Appearance.
///
/// We now use macOS system colors so the panel flips with Appearance, matching
/// the rest of the right sidebar. `make(from:)` is kept as a no-op shim so the
/// call sites that pass a GhosttyConfig compile unchanged.
struct ScreenshotPanelTheme: Equatable {
    let background: Color
    let foreground: Color
    /// Primary non-heading text (filename).
    let dim: Color
    /// Secondary / faint text (relative time, truncated footer).
    let faint: Color
    let divider: Color
    /// Accent color used for the selection outline.
    let selection: Color
    /// Cell / placeholder tint.
    let cellBackground: Color

    static func make(from config: GhosttyConfig) -> ScreenshotPanelTheme {
        _ = config // unused — system colors follow Appearance automatically
        return ScreenshotPanelTheme(
            background: Color(nsColor: .windowBackgroundColor),
            foreground: .primary,
            dim: .primary,
            faint: .secondary,
            divider: Color(nsColor: .separatorColor),
            selection: .accentColor,
            cellBackground: Color(nsColor: .controlBackgroundColor)
        )
    }
}
