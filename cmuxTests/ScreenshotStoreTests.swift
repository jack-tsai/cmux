import XCTest

@testable import cmux

final class ScreenshotStoreTests: XCTestCase {

    private var tempFolder: URL!

    override func setUpWithError() throws {
        tempFolder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-screenshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempFolder, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempFolder { try? FileManager.default.removeItem(at: tempFolder) }
    }

    // MARK: - Helpers

    /// Write a zero-byte file with the given mtime. Returns the URL.
    @discardableResult
    private func writeFile(
        name: String,
        mtime: Date,
        bytes: Int = 1
    ) throws -> URL {
        let url = tempFolder.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: url.path
        )
        return url
    }

    private func writeSubdirectory(name: String) throws -> URL {
        let url = tempFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Extension filtering

    func testScanIncludesSupportedExtensionsIgnoringCase() throws {
        let base = Date().addingTimeInterval(-60)
        try writeFile(name: "a.png", mtime: base)
        try writeFile(name: "b.JPG", mtime: base)
        try writeFile(name: "c.pdf", mtime: base)
        try writeFile(name: "d.heic", mtime: base)
        _ = try writeSubdirectory(name: "sub")

        let result = ScreenshotFolderScanner.scan(folderPath: tempFolder.path)

        let names = result.entries.map { $0.url.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["a.png", "b.JPG", "d.heic"])
        XCTAssertNil(result.loadError)
    }

    // MARK: - Missing folder / permission

    func testScanMissingFolderReturnsFolderMissingError() {
        let missing = tempFolder.appendingPathComponent("does-not-exist").path
        let result = ScreenshotFolderScanner.scan(folderPath: missing)
        XCTAssertEqual(result.loadError, .folderMissing)
        XCTAssertEqual(result.entries, [])
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.totalCountInFolder, 0)
    }

    // MARK: - Sort order

    func testEntriesSortedByMtimeDescending() throws {
        let now = Date().addingTimeInterval(-60)
        try writeFile(name: "a.png", mtime: now.addingTimeInterval(-100))
        try writeFile(name: "b.png", mtime: now)
        try writeFile(name: "c.png", mtime: now.addingTimeInterval(-50))

        let result = ScreenshotFolderScanner.scan(folderPath: tempFolder.path)
        let names = result.entries.map { $0.url.lastPathComponent }
        XCTAssertEqual(names, ["b.png", "c.png", "a.png"])
    }

    func testEqualMtimeTieBreaksByFilenameAscending() throws {
        let mtime = Date().addingTimeInterval(-60)
        try writeFile(name: "bravo.png", mtime: mtime)
        try writeFile(name: "alpha.png", mtime: mtime)

        let result = ScreenshotFolderScanner.scan(folderPath: tempFolder.path)
        let names = result.entries.map { $0.url.lastPathComponent }
        XCTAssertEqual(names, ["alpha.png", "bravo.png"])
    }

    // MARK: - Truncation cap

    func testTruncationKeepsMostRecentThousand() throws {
        let base = Date().addingTimeInterval(-3600)
        for i in 0..<1005 {
            // Stagger mtimes so the 5 newest are distinctly identifiable.
            try writeFile(
                name: String(format: "shot-%04d.png", i),
                mtime: base.addingTimeInterval(TimeInterval(i))
            )
        }
        let result = ScreenshotFolderScanner.scan(folderPath: tempFolder.path)
        XCTAssertEqual(result.entries.count, 1000)
        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.totalCountInFolder, 1005)
        // Newest file (index 1004) must appear first.
        XCTAssertEqual(result.entries.first?.url.lastPathComponent, "shot-1004.png")
        XCTAssertEqual(result.entries.last?.url.lastPathComponent, "shot-0005.png")
    }

    func testBelowCapNotTruncated() throws {
        let base = Date().addingTimeInterval(-3600)
        for i in 0..<300 {
            try writeFile(
                name: String(format: "p-%04d.png", i),
                mtime: base.addingTimeInterval(TimeInterval(i))
            )
        }
        let result = ScreenshotFolderScanner.scan(folderPath: tempFolder.path)
        XCTAssertEqual(result.entries.count, 300)
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.totalCountInFolder, 300)
    }

    // MARK: - Stability delay (in-flight writes)

    func testRecentlyModifiedFileExcludedFromScan() throws {
        let now = Date()
        try writeFile(name: "fresh.png", mtime: now) // too fresh
        try writeFile(name: "stable.png", mtime: now.addingTimeInterval(-60))

        let result = ScreenshotFolderScanner.scan(folderPath: tempFolder.path, now: now)
        let names = result.entries.map { $0.url.lastPathComponent }
        XCTAssertEqual(names, ["stable.png"])
    }

    func testRecentFileAppearsAfterStabilityWindow() throws {
        let firstScanTime = Date()
        let fileMtime = firstScanTime.addingTimeInterval(-0.1) // fresh on first scan
        try writeFile(name: "shot.png", mtime: fileMtime)

        let first = ScreenshotFolderScanner.scan(folderPath: tempFolder.path, now: firstScanTime)
        XCTAssertEqual(first.entries.count, 0)

        let laterScanTime = fileMtime.addingTimeInterval(1.0) // well past 300 ms window
        let later = ScreenshotFolderScanner.scan(folderPath: tempFolder.path, now: laterScanTime)
        XCTAssertEqual(later.entries.map { $0.url.lastPathComponent }, ["shot.png"])
    }

    // MARK: - ScreenshotEntry id stability

    func testDeterministicIDIsStableAcrossCalls() {
        let id1 = ScreenshotEntry.deterministicID(for: "/Users/test/a.png")
        let id2 = ScreenshotEntry.deterministicID(for: "/Users/test/a.png")
        XCTAssertEqual(id1, id2)
    }

    func testDifferentPathsProduceDifferentIDs() {
        let id1 = ScreenshotEntry.deterministicID(for: "/Users/test/a.png")
        let id2 = ScreenshotEntry.deterministicID(for: "/Users/test/b.png")
        XCTAssertNotEqual(id1, id2)
    }

    func testIDUsesUUIDVersion5BitLayout() {
        let uuid = ScreenshotEntry.deterministicID(for: "/Users/test/a.png")
        let bytes = uuid.uuid
        // Version nibble = 5
        XCTAssertEqual(bytes.6 & 0xF0, 0x50)
        // RFC 4122 variant = 10xx xxxx
        XCTAssertEqual(bytes.8 & 0xC0, 0x80)
    }
}
