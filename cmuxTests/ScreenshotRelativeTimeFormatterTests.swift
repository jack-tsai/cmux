import XCTest

@testable import cmux

final class ScreenshotRelativeTimeFormatterTests: XCTestCase {

    private func format(deltaSeconds: TimeInterval) -> String {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mtime = now.addingTimeInterval(-deltaSeconds)
        return ScreenshotRelativeTimeFormatter.format(mtime, now: now)
    }

    // MARK: - Seconds

    func testZeroSeconds() {
        XCTAssertEqual(format(deltaSeconds: 0), "0s")
    }

    func testFiveSeconds() {
        XCTAssertEqual(format(deltaSeconds: 5), "5s")
    }

    func testThirtySeconds() {
        XCTAssertEqual(format(deltaSeconds: 30), "30s")
    }

    func testJustUnderAMinute() {
        XCTAssertEqual(format(deltaSeconds: 59), "59s")
    }

    // MARK: - Minutes

    func testExactlyOneMinute() {
        XCTAssertEqual(format(deltaSeconds: 60), "1m")
    }

    func testNinetySecondsReadsAsOneMinute() {
        XCTAssertEqual(format(deltaSeconds: 90), "1m")
    }

    func testFiveMinutes() {
        XCTAssertEqual(format(deltaSeconds: 5 * 60), "5m")
    }

    // MARK: - Hours

    func testOneHour() {
        XCTAssertEqual(format(deltaSeconds: 3600), "1h")
    }

    func testTwoAndAHalfHours() {
        XCTAssertEqual(format(deltaSeconds: 2.5 * 3600), "2h")
    }

    // MARK: - Days

    func testThreeDays() {
        XCTAssertEqual(format(deltaSeconds: 3 * 86_400), "3d")
    }

    // MARK: - Future clamp

    func testFutureMtimeClampsToZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(60) // mtime is 60s in the future
        XCTAssertEqual(
            ScreenshotRelativeTimeFormatter.format(future, now: now),
            "0s"
        )
    }
}
