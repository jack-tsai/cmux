import AppKit
import Foundation
import QuickLookThumbnailing

/// LRU thumbnail cache keyed by `(absoluteURL, mtime)` so in-place edits
/// miss naturally after the watcher refreshes the entry's mtime.
/// Spec: `screenshot-panel-view` → "Thumbnail cache keyed by URL and mtime".
final class ScreenshotThumbnailCache {
    static let shared = ScreenshotThumbnailCache()

    /// Public constant so callers and tests agree on the ceiling.
    static let capacity = 200

    private let cache: NSCache<NSString, NSImage>

    init(capacity: Int = ScreenshotThumbnailCache.capacity) {
        self.cache = NSCache<NSString, NSImage>()
        self.cache.countLimit = capacity
    }

    /// Composite key: `path|mtime-in-whole-seconds`.
    static func cacheKey(url: URL, mtime: Date) -> String {
        "\(url.path)|\(Int(mtime.timeIntervalSince1970))"
    }

    func cached(for url: URL, mtime: Date) -> NSImage? {
        cache.object(forKey: Self.cacheKey(url: url, mtime: mtime) as NSString)
    }

    func store(_ image: NSImage, for url: URL, mtime: Date) {
        cache.setObject(image, forKey: Self.cacheKey(url: url, mtime: mtime) as NSString)
    }

    func clear() { cache.removeAllObjects() }

    // MARK: - Async thumbnail generation

    /// Request a thumbnail at the given size. Uses the cached representation if
    /// `(url, mtime)` already matches; otherwise asks QuickLook and stores the
    /// result. The completion runs on the main queue.
    ///
    /// - Parameter pixelSize: longest-edge in points. 120 for grid cells,
    ///   1024 for preview. Scale is picked up from the main screen.
    func requestThumbnail(
        for url: URL,
        mtime: Date,
        pixelSize: CGFloat,
        completion: @escaping (NSImage?) -> Void
    ) {
        if let cached = cached(for: url, mtime: mtime) {
            completion(cached)
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                if let image {
                    self?.store(image, for: url, mtime: mtime)
                }
                completion(image)
            }
        }
    }
}
