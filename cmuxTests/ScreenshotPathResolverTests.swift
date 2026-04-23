import XCTest

@testable import cmux

final class ScreenshotPathResolverTests: XCTestCase {

    // MARK: - Helpers

    private func makeEnvironment(
        userDefaultsPath: String? = nil,
        systemLocation: String? = nil,
        home: String = "/Users/test",
        existingDirectories: Set<String>
    ) -> ScreenshotPanelPathResolverEnvironment {
        ScreenshotPanelPathResolverEnvironment(
            userDefaultsPath: { userDefaultsPath },
            systemScreenCaptureLocation: { systemLocation },
            homeDirectory: { home },
            directoryExists: { existingDirectories.contains($0) }
        )
    }

    // MARK: - Path resolver scenarios

    func testUserSetPathTakesPrecedence() {
        let env = makeEnvironment(
            userDefaultsPath: "/Users/test/Pictures/螢幕載圖",
            systemLocation: "/Users/test/Desktop/Screenshots",
            existingDirectories: [
                "/Users/test/Pictures/螢幕載圖",
                "/Users/test/Desktop/Screenshots",
                "/Users/test/Desktop",
                "/Users/test/Pictures",
            ]
        )
        XCTAssertEqual(
            ScreenshotPanelPathResolver.resolve(environment: env),
            "/Users/test/Pictures/螢幕載圖"
        )
    }

    func testSystemLocationUsedWhenUserPathUnset() {
        let env = makeEnvironment(
            userDefaultsPath: nil,
            systemLocation: "/Users/test/Desktop/Screenshots",
            existingDirectories: [
                "/Users/test/Desktop/Screenshots",
                "/Users/test/Desktop",
                "/Users/test/Pictures",
            ]
        )
        XCTAssertEqual(
            ScreenshotPanelPathResolver.resolve(environment: env),
            "/Users/test/Desktop/Screenshots"
        )
    }

    func testDesktopUsedWhenUserAndSystemBothUnset() {
        let env = makeEnvironment(
            userDefaultsPath: nil,
            systemLocation: nil,
            existingDirectories: ["/Users/test/Desktop", "/Users/test/Pictures"]
        )
        XCTAssertEqual(
            ScreenshotPanelPathResolver.resolve(environment: env),
            "/Users/test/Desktop"
        )
    }

    func testFallsThroughWhenUserPathMissing() {
        let env = makeEnvironment(
            userDefaultsPath: "/Users/test/deleted-folder",
            systemLocation: "/Users/test/Desktop/Screenshots",
            existingDirectories: [
                "/Users/test/Desktop/Screenshots",
                "/Users/test/Desktop",
                "/Users/test/Pictures",
            ]
        )
        XCTAssertEqual(
            ScreenshotPanelPathResolver.resolve(environment: env),
            "/Users/test/Desktop/Screenshots"
        )
    }

    func testFallsThroughWhenSystemLocationMissing() {
        let env = makeEnvironment(
            userDefaultsPath: nil,
            systemLocation: "/Volumes/nonexistent/Shots",
            existingDirectories: ["/Users/test/Desktop", "/Users/test/Pictures"]
        )
        XCTAssertEqual(
            ScreenshotPanelPathResolver.resolve(environment: env),
            "/Users/test/Desktop"
        )
    }

    func testPicturesFallbackWhenDesktopMissing() {
        let env = makeEnvironment(
            userDefaultsPath: nil,
            systemLocation: nil,
            existingDirectories: ["/Users/test/Pictures"]
        )
        XCTAssertEqual(
            ScreenshotPanelPathResolver.resolve(environment: env),
            "/Users/test/Pictures"
        )
    }

    func testTildeExpansionInSystemLocation() {
        let env = makeEnvironment(
            userDefaultsPath: nil,
            systemLocation: "~/Desktop/Screenshots",
            home: "/Users/test",
            existingDirectories: ["/Users/test/Desktop/Screenshots", "/Users/test/Pictures"]
        )
        XCTAssertEqual(
            ScreenshotPanelPathResolver.resolve(environment: env),
            "/Users/test/Desktop/Screenshots"
        )
    }

    // MARK: - ScreenshotViewMode

    func testViewModeUnsetResolvesToGrid() {
        XCTAssertEqual(ScreenshotViewMode.resolve(rawValue: nil), .grid)
    }

    func testViewModeExplicitList() {
        XCTAssertEqual(ScreenshotViewMode.resolve(rawValue: "list"), .list)
    }

    func testViewModeExplicitGrid() {
        XCTAssertEqual(ScreenshotViewMode.resolve(rawValue: "grid"), .grid)
    }

    func testViewModeCorruptedResolvesToGrid() {
        XCTAssertEqual(ScreenshotViewMode.resolve(rawValue: "wall"), .grid)
        XCTAssertEqual(ScreenshotViewMode.resolve(rawValue: ""), .grid)
    }
}
