import Foundation

/// Formats a file's mtime as a short relative-time label used in the list view
/// (e.g. "5s", "30s", "1m", "2h", "3d"). Pure so tests can round-trip.
/// Spec: `screenshot-panel-view` → "Relative time formatting".
enum ScreenshotRelativeTimeFormatter {
    static func format(_ mtime: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(mtime)
        // Future mtimes (clock skew) clamp to "0s".
        if delta <= 0 { return "0s" }

        if delta < 60 {
            return "\(Int(delta))s"
        }
        if delta < 3600 {
            return "\(Int(delta / 60))m"
        }
        if delta < 86_400 {
            return "\(Int(delta / 3600))h"
        }
        return "\(Int(delta / 86_400))d"
    }
}
