import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Corresponds to task 3.5: token abbrev, reset countdown, percent rounding.
final class ClaudeStatsFormatterTests: XCTestCase {

    // MARK: - Tokens

    func testFormatTokens_belowOneThousand_plainInteger() {
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(0), "0")
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(7), "7")
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(999), "999")
    }

    func testFormatTokens_thousandsCompactToK() {
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(1_000), "1K")
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(1_200), "1.2K")
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(1_234), "1.2K")
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(174_400), "174.4K")
    }

    func testFormatTokens_millionsCompactToM() {
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(1_000_000), "1M")
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(1_800_000), "1.8M")
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(4_700_000), "4.7M")
    }

    func testFormatTokens_billionsCompactToB() {
        XCTAssertEqual(ClaudeStatsFormatter.formatTokens(2_500_000_000), "2.5B")
    }

    // MARK: - Percent

    func testFormatPercent_roundsHalfUp() {
        XCTAssertEqual(ClaudeStatsFormatter.formatPercent(28.4), "28%")
        XCTAssertEqual(ClaudeStatsFormatter.formatPercent(28.6), "29%")
        XCTAssertEqual(ClaudeStatsFormatter.formatPercent(28.5), "29%")
    }

    func testFormatPercent_clampsToHundred() {
        XCTAssertEqual(ClaudeStatsFormatter.formatPercent(101), "100%")
        XCTAssertEqual(ClaudeStatsFormatter.formatPercent(-5), "0%")
    }

    // MARK: - Reset countdown

    func testFormatResetRemaining_underOneHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let epoch = Int(now.timeIntervalSince1970 + 40 * 60) // 40 minutes ahead
        XCTAssertEqual(ClaudeStatsFormatter.formatResetRemaining(unixEpoch: epoch, now: now), "0h40m")
    }

    func testFormatResetRemaining_betweenOneHourAndOneDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let epoch = Int(now.timeIntervalSince1970 + 4 * 3600 + 12 * 60)
        XCTAssertEqual(ClaudeStatsFormatter.formatResetRemaining(unixEpoch: epoch, now: now), "4h12m")
    }

    func testFormatResetRemaining_overOneDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let epoch = Int(now.timeIntervalSince1970 + (1 * 24 * 3600) + (19 * 3600))
        XCTAssertEqual(ClaudeStatsFormatter.formatResetRemaining(unixEpoch: epoch, now: now), "1d19h")
    }

    func testFormatResetRemaining_alreadyPast_returnsNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let epoch = Int(now.timeIntervalSince1970 - 10)
        XCTAssertEqual(ClaudeStatsFormatter.formatResetRemaining(unixEpoch: epoch, now: now), "now")
    }

    // MARK: - Model short name

    func testShortModelName_recognizedModels() {
        XCTAssertEqual(ClaudeStatsFormatter.shortModelName(from: "claude-opus-4-7"), "opus")
        XCTAssertEqual(ClaudeStatsFormatter.shortModelName(from: "claude-sonnet-4-6"), "son")
        XCTAssertEqual(ClaudeStatsFormatter.shortModelName(from: "claude-haiku-4-5"), "hai")
    }

    func testShortModelName_unknown_returnsNil() {
        XCTAssertNil(ClaudeStatsFormatter.shortModelName(from: "gpt-4"))
        XCTAssertNil(ClaudeStatsFormatter.shortModelName(from: nil))
        XCTAssertNil(ClaudeStatsFormatter.shortModelName(from: ""))
    }
}
