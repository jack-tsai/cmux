import XCTest

@testable import cmux

final class RightSidebarModeTests: XCTestCase {

    // MARK: - RightSidebarModeGate.resolve

    func testScreenshotsModeFlipsToFilesWhenToggleOff() {
        let resolved = RightSidebarModeGate.resolve(
            current: .screenshots, showsScreenshotsTab: false
        )
        XCTAssertEqual(resolved, .files)
    }

    func testScreenshotsModePreservedWhenToggleOn() {
        let resolved = RightSidebarModeGate.resolve(
            current: .screenshots, showsScreenshotsTab: true
        )
        XCTAssertEqual(resolved, .screenshots)
    }

    func testOtherModesUnaffectedByToggle() {
        XCTAssertEqual(
            RightSidebarModeGate.resolve(current: .files, showsScreenshotsTab: false),
            .files
        )
        XCTAssertEqual(
            RightSidebarModeGate.resolve(current: .sessions, showsScreenshotsTab: false),
            .sessions
        )
        XCTAssertEqual(
            RightSidebarModeGate.resolve(current: .files, showsScreenshotsTab: true),
            .files
        )
    }

    // MARK: - RightSidebarModeGate.visibleModes

    func testVisibleModesIncludesScreenshotsWhenToggleOn() {
        let modes = RightSidebarModeGate.visibleModes(showsScreenshotsTab: true)
        XCTAssertEqual(modes, [.files, .sessions, .screenshots])
    }

    func testVisibleModesExcludesScreenshotsWhenToggleOff() {
        let modes = RightSidebarModeGate.visibleModes(showsScreenshotsTab: false)
        XCTAssertEqual(modes, [.files, .sessions])
    }

    // MARK: - Enum label / symbol

    func testScreenshotsModeLabelIsLocalized() {
        // Label resolves via String(localized:) — we only verify it's non-empty
        // because xcstrings may not be present in the test bundle yet.
        XCTAssertFalse(RightSidebarMode.screenshots.label.isEmpty)
    }

    func testScreenshotsModeSymbolIsCamera() {
        XCTAssertEqual(RightSidebarMode.screenshots.symbolName, "camera")
    }
}
