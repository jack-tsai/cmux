import Foundation
import SwiftUI

// MARK: - UserDefaults keys

enum ScreenshotPanelSettingsKey {
    static let path = "screenshotPanel.path"
    static let viewMode = "screenshotPanel.viewMode"
    static let showsRightSidebarTab = "screenshotPanel.showsRightSidebarTab"
}

// MARK: - View mode

enum ScreenshotViewMode: String, CaseIterable {
    case grid
    case list

    static let defaultValue: ScreenshotViewMode = .grid

    /// Resolve a raw stored string; any unrecognized value falls back to `grid`.
    static func resolve(rawValue: String?) -> ScreenshotViewMode {
        guard let rawValue, let mode = ScreenshotViewMode(rawValue: rawValue) else {
            return defaultValue
        }
        return mode
    }
}

// MARK: - Path resolver

/// Dependency seam so tests can stub UserDefaults / system screenshot location /
/// directory existence without touching the real filesystem or defaults.
struct ScreenshotPanelPathResolverEnvironment {
    var userDefaultsPath: () -> String?
    var systemScreenCaptureLocation: () -> String?
    var homeDirectory: () -> String
    var directoryExists: (String) -> Bool

    static let live = ScreenshotPanelPathResolverEnvironment(
        userDefaultsPath: {
            UserDefaults.standard.string(forKey: ScreenshotPanelSettingsKey.path)
        },
        systemScreenCaptureLocation: {
            // macOS stores the user's configured screenshot location here.
            // `defaults read com.apple.screencapture location` reads the same value.
            CFPreferencesCopyAppValue(
                "location" as CFString,
                "com.apple.screencapture" as CFString
            ) as? String
        },
        homeDirectory: {
            FileManager.default.homeDirectoryForCurrentUser.path
        },
        directoryExists: { path in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && isDir.boolValue
        }
    )
}

enum ScreenshotPanelPathResolver {
    /// Returns the first existing, directory path from the 4-step fallback chain:
    /// UserDefaults → com.apple.screencapture location → ~/Desktop → ~/Pictures.
    /// `~/Pictures` is always included because it exists on every macOS user account.
    static func resolve(
        environment: ScreenshotPanelPathResolverEnvironment = .live
    ) -> String {
        let candidates: [String?] = [
            environment.userDefaultsPath(),
            environment.systemScreenCaptureLocation().flatMap { expandTilde($0, home: environment.homeDirectory()) },
            (environment.homeDirectory() as NSString).appendingPathComponent("Desktop"),
            (environment.homeDirectory() as NSString).appendingPathComponent("Pictures"),
        ]

        for candidate in candidates {
            guard let path = candidate, !path.isEmpty else { continue }
            let expanded = expandTilde(path, home: environment.homeDirectory())
            if environment.directoryExists(expanded) {
                return expanded
            }
        }
        // Unreachable in practice: `~/Pictures` always exists. Return it verbatim
        // so callers have something stable even if the probe somehow fails.
        return (environment.homeDirectory() as NSString).appendingPathComponent("Pictures")
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let suffix = String(path.dropFirst())
        return (home as NSString).appendingPathComponent(suffix)
    }
}

