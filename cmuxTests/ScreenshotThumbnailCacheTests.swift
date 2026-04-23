import AppKit
import XCTest

@testable import cmux

final class ScreenshotThumbnailCacheTests: XCTestCase {

    private func makeStubImage(width: CGFloat = 16, height: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return image
    }

    func testHitWhenKeyMatches() {
        let cache = ScreenshotThumbnailCache(capacity: 10)
        let url = URL(fileURLWithPath: "/tmp/test/a.png")
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let image = makeStubImage()

        cache.store(image, for: url, mtime: mtime)
        XCTAssertNotNil(cache.cached(for: url, mtime: mtime))
    }

    func testMissAfterMtimeChange() {
        let cache = ScreenshotThumbnailCache(capacity: 10)
        let url = URL(fileURLWithPath: "/tmp/test/b.png")
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let after = Date(timeIntervalSince1970: 1_700_000_100)

        cache.store(makeStubImage(), for: url, mtime: before)
        XCTAssertNotNil(cache.cached(for: url, mtime: before))
        XCTAssertNil(
            cache.cached(for: url, mtime: after),
            "mtime change must produce a cache miss"
        )
    }

    func testKeyEncodingStable() {
        let url = URL(fileURLWithPath: "/tmp/test/c.png")
        let mtime = Date(timeIntervalSince1970: 1_700_000_123)
        let key = ScreenshotThumbnailCache.cacheKey(url: url, mtime: mtime)
        XCTAssertEqual(key, "/tmp/test/c.png|1700000123")
    }

    func testDifferentURLsDoNotCollide() {
        let cache = ScreenshotThumbnailCache(capacity: 10)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let a = URL(fileURLWithPath: "/tmp/test/a.png")
        let b = URL(fileURLWithPath: "/tmp/test/b.png")

        let imgA = makeStubImage(width: 8)
        let imgB = makeStubImage(width: 32)
        cache.store(imgA, for: a, mtime: mtime)
        cache.store(imgB, for: b, mtime: mtime)

        XCTAssertEqual(cache.cached(for: a, mtime: mtime)?.size.width, 8)
        XCTAssertEqual(cache.cached(for: b, mtime: mtime)?.size.width, 32)
    }

    func testClearDropsAllEntries() {
        let cache = ScreenshotThumbnailCache(capacity: 10)
        let url = URL(fileURLWithPath: "/tmp/test/d.png")
        let mtime = Date()
        cache.store(makeStubImage(), for: url, mtime: mtime)
        cache.clear()
        XCTAssertNil(cache.cached(for: url, mtime: mtime))
    }
}
