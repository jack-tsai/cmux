import XCTest
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers spec `claude-stats-sidebar` Color thresholds derived from ghostty palette
/// and decision "Theme color mapping". Uses three representative ghostty
/// palettes to ensure the derived colors follow the palette.
final class ClaudeStatsThemeTests: XCTestCase {

    // MARK: - Threshold cutoffs

    func testThresholdColor_below60_isDefault() {
        let defaultColor = Color.blue
        let warn = Color.yellow
        let danger = Color.red
        let result = ClaudeStatsTheme.thresholdColor(
            for: 59, barDefault: defaultColor, barWarn: warn, barDanger: danger
        )
        XCTAssertEqual(result, defaultColor)
    }

    func testThresholdColor_between60And84_isWarn() {
        let defaultColor = Color.blue
        let warn = Color.yellow
        let danger = Color.red
        for value in [60.0, 72.0, 84.9] {
            let result = ClaudeStatsTheme.thresholdColor(
                for: value, barDefault: defaultColor, barWarn: warn, barDanger: danger
            )
            XCTAssertEqual(result, warn, "value=\(value) should be warn")
        }
    }

    func testThresholdColor_atOrAbove85_isDanger() {
        let defaultColor = Color.blue
        let warn = Color.yellow
        let danger = Color.red
        for value in [85.0, 92.0, 100.0] {
            let result = ClaudeStatsTheme.thresholdColor(
                for: value, barDefault: defaultColor, barWarn: warn, barDanger: danger
            )
            XCTAssertEqual(result, danger, "value=\(value) should be danger")
        }
    }

    // MARK: - Palette derivation

    func testTheme_darkConfig_derivesBlueYellowRedFromPalette4_3_1() {
        let config = GhosttyConfig()
        // Override with well-known palette entries so we can assert them verbatim.
        var cfg = config
        cfg.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        cfg.foregroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        cfg.palette[1] = NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1) // red sentinel
        cfg.palette[3] = NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1) // yellow sentinel
        cfg.palette[4] = NSColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1) // blue sentinel
        let theme = ClaudeStatsTheme.make(from: cfg)
        XCTAssertEqual(theme.barDefault, Color(nsColor: cfg.palette[4]!))
        XCTAssertEqual(theme.barWarn, Color(nsColor: cfg.palette[3]!))
        XCTAssertEqual(theme.barDanger, Color(nsColor: cfg.palette[1]!))
    }

    func testTheme_missingPaletteEntries_fallsBackToAnsiApproximation() {
        // An empty palette dict should not crash; fallback colors are applied.
        var cfg = GhosttyConfig()
        cfg.backgroundColor = NSColor.black
        cfg.foregroundColor = NSColor.white
        cfg.palette = [:]
        let theme = ClaudeStatsTheme.make(from: cfg)
        // Simply assert they are distinct — exact hex depends on the fallback table.
        XCTAssertNotEqual(theme.barDefault, theme.barWarn)
        XCTAssertNotEqual(theme.barWarn, theme.barDanger)
    }
}
