# Screenshot Panel Settings

## ADDED Requirements

### Requirement: screenshotPanel.path resolved via 4-step fallback chain

The effective screenshot folder path SHALL be resolved by the following ordered lookup, returning the first non-empty, absolute, existing directory path:

1. `screenshotPanel.path` from `UserDefaults` / `@AppStorage` (written by Debug menu or `settings.json` sync).
2. macOS system screenshot location read from `CFPreferencesCopyAppValue("location", "com.apple.screencapture")`.
3. `~/Desktop` (the macOS default screenshot location).
4. `~/Pictures` (last-resort fallback — always exists on first-boot user accounts).

Any step that returns a non-existing or non-directory path SHALL be skipped, and the resolver SHALL advance to the next step.

#### Scenario: User has set screenshotPanel.path to an existing folder

- **WHEN** `UserDefaults.standard.string(forKey: "screenshotPanel.path")` returns `/Users/jack/Pictures/螢幕載圖` and that folder exists
- **THEN** the resolver SHALL return that path

#### Scenario: User has not set path, macOS has system screenshot location

- **WHEN** `screenshotPanel.path` is unset in UserDefaults
- **AND** `CFPreferencesCopyAppValue("location", "com.apple.screencapture")` returns `/Users/jack/Desktop/Screenshots`
- **AND** that directory exists
- **THEN** the resolver SHALL return `/Users/jack/Desktop/Screenshots`

#### Scenario: Neither user setting nor system setting, Desktop exists

- **WHEN** both `screenshotPanel.path` and `com.apple.screencapture` location are unset
- **THEN** the resolver SHALL return `~/Desktop` (after `NSString.expandingTildeInPath` resolution)

#### Scenario: User-provided path no longer exists

- **WHEN** `screenshotPanel.path` is `/Users/jack/deleted-folder`
- **AND** that folder does not exist
- **THEN** the resolver SHALL fall through to step 2 (and beyond)
- **AND** SHALL NOT return the non-existing path

### Requirement: screenshotPanel.viewMode with default grid

`screenshotPanel.viewMode` SHALL be stored via `@AppStorage` with key `"screenshotPanel.viewMode"`. Legal values SHALL be exactly `"grid"` and `"list"`. Any unrecognized stored value SHALL resolve to `"grid"` (fresh-install default).

#### Scenario: First launch after install

- **WHEN** `screenshotPanel.viewMode` is unset
- **THEN** the panel SHALL render in grid mode

#### Scenario: Stored value is `"list"`

- **WHEN** `screenshotPanel.viewMode` is `"list"`
- **THEN** the panel SHALL render in list mode

#### Scenario: Stored value is corrupted

- **WHEN** `screenshotPanel.viewMode` is any value other than `"grid"` or `"list"` (e.g. legacy migration, manual edit)
- **THEN** the panel SHALL render in grid mode
- **AND** the corrupted value SHALL be overwritten to `"grid"` on next toggle

### Requirement: Debug menu folder picker

The cmux Debug menu SHALL contain a `Screenshot Panel Path…` menu item that, when clicked, opens an `NSOpenPanel` configured for directory selection only (`canChooseFiles = false`, `canChooseDirectories = true`, `allowsMultipleSelection = false`). The chosen path SHALL be written to `screenshotPanel.path`. The menu SHALL also display the currently resolved path in the menu item's detail text.

#### Scenario: User picks a new folder

- **WHEN** the user clicks `Screenshot Panel Path…` and selects `/Users/jack/Pictures/螢幕載圖` in the open panel
- **THEN** `UserDefaults.standard.string(forKey: "screenshotPanel.path")` SHALL equal `/Users/jack/Pictures/螢幕載圖`
- **AND** the `ScreenshotStore` SHALL reload from the new path on the next UI redraw

#### Scenario: User cancels the picker

- **WHEN** the user opens the picker and presses Cancel
- **THEN** `screenshotPanel.path` SHALL remain unchanged

### Requirement: Reset to auto-detect option

Debug menu SHALL provide a `Reset to Auto-detect` action that clears `screenshotPanel.path` from UserDefaults. After reset, the resolver SHALL fall through to steps 2–4 of the fallback chain.

#### Scenario: Reset after explicit override

- **WHEN** `screenshotPanel.path` is `/Users/jack/Pictures/螢幕載圖` and the user clicks Reset to Auto-detect
- **THEN** the key SHALL be removed from UserDefaults
- **AND** the resolver SHALL re-evaluate using step 2 onwards
- **AND** the panel SHALL reload from the newly-resolved path

### Requirement: settings.json sync for screenshotPanel.* keys

`screenshotPanel.path`, `screenshotPanel.viewMode`, and `screenshotPanel.showsRightSidebarTab` SHALL be mirrored to `~/.config/cmux/settings.json` under the top-level object key `screenshotPanel` so the configuration is portable and version-control-friendly. The semantics SHALL be:

- **On app startup**: if `~/.config/cmux/settings.json` exists and contains a `screenshotPanel` object, each recognized sub-key (`path`, `viewMode`, `showsRightSidebarTab`) SHALL be imported into `UserDefaults.standard` under the corresponding key. Unrecognized sub-keys SHALL be ignored (forward-compat). Malformed JSON or type mismatches SHALL be logged and SHALL NOT crash the app; existing UserDefaults values SHALL be preserved in that case.
- **On every write** via the Debug menu or other UI (path picker, view-mode toggle, Shots-tab toggle): the value SHALL be written to both `UserDefaults.standard` AND `~/.config/cmux/settings.json`. The JSON file SHALL be written atomically (`Data.write(to:options:.atomic)`) and MUST preserve any existing top-level keys belonging to other settings domains (e.g. keyboard shortcuts under `keyboardShortcuts`).
- **Reset to Auto-detect**: SHALL remove the `path` sub-key both from UserDefaults and from the `screenshotPanel` object in `settings.json` (leaving other `screenshotPanel` sub-keys intact).

The pattern SHALL follow `KeyboardShortcutSettingsFileStore` (existing precedent for `~/.config/cmux/settings.json` portability in cmux).

#### Scenario: settings.json has screenshotPanel block on startup

- **WHEN** `~/.config/cmux/settings.json` contains `{"screenshotPanel": {"path": "/Users/jack/Pictures/螢幕載圖", "viewMode": "list"}}` and the app launches
- **THEN** `UserDefaults.standard.string(forKey: "screenshotPanel.path")` SHALL equal `/Users/jack/Pictures/螢幕載圖`
- **AND** `UserDefaults.standard.string(forKey: "screenshotPanel.viewMode")` SHALL equal `"list"`

#### Scenario: Debug menu writes are mirrored to settings.json

- **WHEN** the user picks a folder via the Debug menu and `settings.json` previously contained `{"keyboardShortcuts": {...}, "screenshotPanel": {"viewMode": "grid"}}`
- **THEN** after the write, `settings.json` SHALL contain a `screenshotPanel.path` sub-key with the picked path
- **AND** the pre-existing `keyboardShortcuts` top-level key SHALL remain byte-identical
- **AND** the pre-existing `screenshotPanel.viewMode = "grid"` SHALL remain

#### Scenario: Malformed settings.json at startup

- **WHEN** `~/.config/cmux/settings.json` contains invalid JSON or `screenshotPanel` is not an object
- **THEN** the import SHALL be skipped
- **AND** the app SHALL log a warning via `dlog(...)`
- **AND** the app SHALL NOT crash
- **AND** any pre-existing UserDefaults values under `screenshotPanel.*` SHALL remain untouched

#### Scenario: Reset to Auto-detect strips only the path key

- **WHEN** `settings.json` contains `{"screenshotPanel": {"path": "...", "viewMode": "list", "showsRightSidebarTab": true}}` and the user clicks Reset to Auto-detect
- **THEN** `settings.json` SHALL still contain `{"screenshotPanel": {"viewMode": "list", "showsRightSidebarTab": true}}`
- **AND** the `path` sub-key SHALL NOT appear in the file

### Requirement: screenshotPanel.showsRightSidebarTab toggle

An `@AppStorage("screenshotPanel.showsRightSidebarTab")` boolean (default `true`) SHALL control whether the Shots chip appears in the RightSidebarMode chip bar. When `false`, the Shots chip SHALL NOT render, and the mode SHALL NOT be accessible from the chip bar. If the mode was previously active when the toggle flips off, the sidebar SHALL switch back to `.files` mode.

#### Scenario: User disables Shots tab

- **WHEN** the user toggles `screenshotPanel.showsRightSidebarTab` to `false`
- **THEN** the chip bar SHALL render only Files and Sessions chips
- **AND** if the current mode was `.screenshots`, it SHALL be reset to `.files`

#### Scenario: User re-enables Shots tab

- **WHEN** the user toggles back to `true`
- **THEN** the Shots chip SHALL reappear at its original position
- **AND** clicking it SHALL activate `.screenshots` mode normally
