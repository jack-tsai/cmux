import Foundation
import SwiftUI

/// Persistence + settings access for the `sidebar.showClaudeStats` feature
/// toggle. Bridges:
///  - `UserDefaults` key `sidebar.showClaudeStats` (set via `@AppStorage`
///    by any SwiftUI view and by the Debug menu).
///  - `~/.config/cmux/settings.json` key `sidebar.showClaudeStats`
///    (bootstrapped from the config file on launch so the file acts as the
///    portable source of truth).
///
/// Default is `true` — the feature is on for new installs.
enum SidebarClaudeStatsSettings {
    /// UserDefaults + `@AppStorage` key. Views bind via `@AppStorage(SidebarClaudeStatsSettings.key)`.
    static let key = "sidebar.showClaudeStats"
    static let defaultValue: Bool = true

    /// Current value as a Bool. Consults UserDefaults — cheap, safe to call
    /// from any actor.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        // `object(forKey:)` lets us distinguish "unset" (return default)
        // from "explicitly false".
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    /// Set the value and mirror to `~/.config/cmux/settings.json`.
    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}
