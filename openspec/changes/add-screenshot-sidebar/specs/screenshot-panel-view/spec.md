# Screenshot Panel View

## ADDED Requirements

### Requirement: Third mode in RightSidebarMode

`RightSidebarMode` enum SHALL contain a new case `.screenshots`. The chip bar in `RightSidebarPanelView` SHALL render a chip labelled "Shots" (localized) that activates this mode. Clicking the chip SHALL replace the content area with `ScreenshotPanelView`.

#### Scenario: User clicks the Shots chip

- **WHEN** the Files chip is active and the user clicks the Shots chip
- **THEN** `fileExplorerState.mode` SHALL become `.screenshots`
- **AND** the visible content SHALL be `ScreenshotPanelView`

### Requirement: Preview + gallery vertical layout

`ScreenshotPanelView` SHALL render an upper preview area at fixed 4:3 aspect ratio and a lower gallery area below it. The preview and gallery SHALL NOT be placed in a horizontal split.

#### Scenario: Panel renders with a selected entry

- **WHEN** the store has at least one entry and one entry is selected
- **THEN** the preview area SHALL render the selected entry's image content at 4:3 aspect ratio
- **AND** the gallery area SHALL render below the preview

### Requirement: Auto-select most recent entry on first render

When `ScreenshotPanelView` first appears, and when the store's `entries` transitions from empty to non-empty, the panel SHALL automatically set `selectedId` to `entries[0].id` (the most recent file). The panel SHALL NOT auto-change selection when entries are already present and the user has already selected a different file.

#### Scenario: Panel opened with existing screenshots

- **WHEN** the panel is first shown and `entries` contains three files
- **THEN** `selectedId` SHALL equal `entries[0].id` without any user interaction

#### Scenario: New screenshot arrives while user has selected an older one

- **WHEN** the user has selected `entries[5]` (an older file) and a new screenshot is added that becomes `entries[0]`
- **THEN** `selectedId` SHALL remain `entries[5].id`
- **AND** the selection SHALL NOT jump to the new top entry

### Requirement: Grid and List view modes with user-toggleable toolbar

The panel SHALL support two gallery view modes: `grid` and `list`. A toolbar control SHALL let the user toggle between them. The chosen mode SHALL persist across sessions via `@AppStorage("screenshotPanel.viewMode")`. The default for fresh installs SHALL be `grid`.

#### Scenario: First launch

- **WHEN** the panel is opened for the first time after install
- **THEN** the view mode SHALL be `grid`

#### Scenario: User switches to list and restarts app

- **WHEN** the user toggles to `list`, quits cmux, and relaunches
- **THEN** the panel SHALL open in `list` mode

### Requirement: Grid view renders thumbnail cells

The Grid view SHALL render a `LazyVGrid` with adaptive columns of minimum 56 pt. Each cell SHALL display a thumbnail at 4:3 aspect ratio, rounded corners 4 pt, with a selection outline on the currently selected entry.

#### Scenario: Grid selection visual

- **WHEN** the user single-clicks a grid cell
- **THEN** that cell SHALL gain a 2 pt accent-color outline
- **AND** any previously selected cell SHALL lose its outline
- **AND** the preview area SHALL update to show the clicked file

### Requirement: List view renders thumbnail + filename + mtime rows

The List view SHALL render a vertical `LazyVStack` of rows. Each row SHALL contain, left to right: a 32×24 pt thumbnail, the filename (monospace), and the relative modification time (e.g. "1m", "3h", "2d"). Rows SHALL be vertically aligned.

#### Scenario: Relative time formatting

- **WHEN** a file's `mtime` is 90 seconds ago
- **THEN** the rendered time label SHALL be "1m"

- **WHEN** a file's `mtime` is 2.5 hours ago
- **THEN** the rendered time label SHALL be "2h"

- **WHEN** a file's `mtime` is 3 days ago
- **THEN** the rendered time label SHALL be "3d"

### Requirement: Single-click selects, double-click pastes

A single left-click on any gallery entry SHALL update the selection (preview refresh) only. A double-click SHALL trigger the paste-to-terminal action on the clicked entry regardless of whether it was previously selected.

#### Scenario: Single-click on an unselected entry

- **WHEN** the user single-clicks a gallery entry that is not currently selected
- **THEN** the entry SHALL become selected
- **AND** NO paste action SHALL fire

#### Scenario: Double-click on any entry

- **WHEN** the user double-clicks any gallery entry
- **THEN** the entry SHALL become selected (if not already)
- **AND** the paste-to-terminal action SHALL fire exactly once

### Requirement: Drag-out emits NSItemProvider for file URL + image

Each gallery entry SHALL be draggable. The drag source SHALL register an `NSItemProvider` exposing both `.fileURL` and `.image` (or PNG data) representations of the entry.

#### Scenario: User drags a grid cell onto the terminal surface

- **WHEN** the user drags a cell and drops it on a terminal surface
- **THEN** the terminal drop handler SHALL receive an `NSItemProvider` whose type identifiers include `public.file-url`
- **AND** the terminal drop handler SHALL process the drop via the existing `TerminalImageTransfer` file-URL path

### Requirement: Right-click context menu with five actions

Any gallery entry SHALL expose a right-click context menu with these five items in order:

1. `Copy to pasteboard`
2. `Paste to terminal` (shortcut: Enter)
3. `Reveal in Finder`
4. `Rename…`
5. `Move to Trash`

Items 1–4 SHALL be safe. Item 5 SHALL use `FileManager.default.trashItem(at:resultingItemURL:)` so recovery via Finder Undo is possible.

#### Scenario: User selects "Reveal in Finder"

- **WHEN** the user right-clicks an entry and selects "Reveal in Finder"
- **THEN** Finder SHALL open the containing folder with the entry pre-selected

#### Scenario: User selects "Move to Trash"

- **WHEN** the user right-clicks an entry and selects "Move to Trash"
- **THEN** the file SHALL be moved to the user's Trash via `FileManager.trashItem`
- **AND** the file SHALL NOT be permanently deleted

#### Scenario: Rename dialog commits on Enter

- **WHEN** the user selects "Rename…" and types a new name, then presses Enter
- **THEN** the file SHALL be renamed via `FileManager.moveItem(at:to:)`
- **AND** the gallery SHALL reflect the new name on next reload (triggered by the file watcher)

#### Scenario: Rename dialog cancels on Esc or blur

- **WHEN** the user opens "Rename…" and presses Esc (or clicks outside)
- **THEN** the filename SHALL remain unchanged
- **AND** no `moveItem` call SHALL be made

### Requirement: Empty state with folder picker

When the store has no entries and no error, the panel SHALL render an empty-state UI containing a title "No screenshots yet" and a hint showing the current folder path. When the store reports `.folderMissing` or `.permissionDenied`, the empty state SHALL additionally show a `Choose folder…` button that opens `NSOpenPanel`.

#### Scenario: Folder missing

- **WHEN** the configured folder path does not exist
- **THEN** the panel SHALL show the `Choose folder…` button
- **AND** clicking it SHALL open `NSOpenPanel` in directory-only mode

### Requirement: Truncated warning when folder exceeds 1000 entries

When `store.isTruncated == true`, a footer below the gallery SHALL display `Showing most recent 1000 of <totalCountInFolder>`.

#### Scenario: Folder has 2500 files

- **WHEN** the store reports `isTruncated = true` with `totalCountInFolder = 2500`
- **THEN** the gallery SHALL show 1000 cells / rows
- **AND** a footer SHALL display the text `Showing most recent 1000 of 2500`

### Requirement: Theme-aware rendering

The panel's backgrounds, borders, and text SHALL derive from the active ghostty config, matching the pattern used by the sidebar workspace rows and Claude stats views. The panel SHALL re-render on the `com.cmuxterm.themes.reload-config` notification.

#### Scenario: User switches ghostty theme

- **WHEN** the user changes the ghostty theme while the panel is visible
- **THEN** the `com.cmuxterm.themes.reload-config` notification fires
- **AND** the panel SHALL re-render with the new color palette on the next redraw cycle
