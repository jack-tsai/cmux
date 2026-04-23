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

- **WHEN** a file's `mtime` is less than 1 second ago
- **THEN** the rendered time label SHALL be "0s"

- **WHEN** a file's `mtime` is 30 seconds ago
- **THEN** the rendered time label SHALL be "30s"

- **WHEN** a file's `mtime` is 59 seconds ago
- **THEN** the rendered time label SHALL be "59s"

- **WHEN** a file's `mtime` is 90 seconds ago
- **THEN** the rendered time label SHALL be "1m"

- **WHEN** a file's `mtime` is 2.5 hours ago
- **THEN** the rendered time label SHALL be "2h"

- **WHEN** a file's `mtime` is 3 days ago
- **THEN** the rendered time label SHALL be "3d"

The formatter SHALL use `Ns` (integer seconds, floor) when `age < 60 s`, `Nm` (integer minutes, floor) when `60 s ≤ age < 3600 s`, `Nh` (integer hours, floor) when `3600 s ≤ age < 86400 s`, and `Nd` (integer days, floor) when `age ≥ 86400 s`. The formatter SHALL never produce a negative value; for mtimes in the future (clock skew), it SHALL clamp to `"0s"`.

### Requirement: Single-selection model only in v1

The gallery SHALL maintain exactly one `selectedId: UUID?`. `⌘-click` and `shift-click` SHALL behave identically to a plain left-click — they SHALL set `selectedId` to the clicked entry with no additive or range-extending behavior. All actions (paste, copy, rename, trash, drag-out) SHALL target exactly the `selectedId` entry, never a set.

#### Scenario: ⌘-click behaves like a plain click

- **WHEN** `entries[0]` is selected and the user `⌘`-clicks `entries[5]`
- **THEN** `selectedId` SHALL become `entries[5].id`
- **AND** `entries[0].id` SHALL NOT remain selected
- **AND** no multi-selection state SHALL be surfaced in the UI

#### Scenario: shift-click behaves like a plain click

- **WHEN** `entries[0]` is selected and the user shift-clicks `entries[5]`
- **THEN** `selectedId` SHALL become `entries[5].id`
- **AND** `entries[1]..entries[4]` SHALL NOT enter any selected state

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

### Requirement: Keyboard navigation in the gallery

When `ScreenshotPanelView` has key-window focus, the following keys SHALL act on the gallery selection:

- `ArrowUp` / `ArrowDown` / `ArrowLeft` / `ArrowRight` SHALL move `selectedId` by one entry in the corresponding direction in the current gallery layout. In List mode, Left/Right SHALL behave the same as Up/Down.
- `Enter` / `Return` SHALL trigger the paste-to-terminal action on the currently selected entry (identical to a double-click).
- `Space` SHALL be a no-op beyond ensuring the preview reflects the current selection (single-key preview; MUST NOT paste).
- `Delete` / `Backspace` SHALL invoke the `Move to Trash` action on the currently selected entry, with no confirmation dialog (recovery is via Finder Undo, consistent with the context menu's safety stance).
- `Escape` SHALL return focus to the last-focused terminal surface of the current workspace and SHALL NOT mutate the selection.

The gallery SHALL scroll the selected cell/row into view when selection changes via keyboard.

#### Scenario: ArrowDown advances selection in grid

- **WHEN** grid view is active and `selectedId` points to `entries[2]`
- **AND** the gallery has 4 columns
- **AND** the user presses `ArrowDown`
- **THEN** `selectedId` SHALL become `entries[6].id` (one row below)
- **AND** the preview SHALL update to show `entries[6]`

#### Scenario: Enter triggers paste

- **WHEN** `entries[0]` is selected and the user presses `Enter`
- **THEN** the paste-to-terminal action SHALL fire exactly once on `entries[0]`

#### Scenario: Delete trashes selected entry

- **WHEN** `entries[3]` is selected and the user presses `Delete`
- **THEN** `entries[3]` SHALL be moved to Trash via `FileManager.trashItem`
- **AND** no confirmation dialog SHALL appear
- **AND** after the next reload, `selectedId` SHALL advance to the file that now occupies index 3 (or the new last index if the trashed file was the last entry)

#### Scenario: Escape returns focus to terminal

- **WHEN** the gallery has keyboard focus and the user presses `Escape`
- **THEN** first-responder status SHALL move to the workspace's last-focused terminal surface
- **AND** `selectedId` SHALL remain unchanged

### Requirement: Drag-out restricted to terminal surfaces only in v1

Drag operations originating from the gallery SHALL be accepted only by terminal surfaces within cmux. Non-terminal drop targets — including but not limited to the File Explorer panel, the Sessions panel, the left workspace sidebar, the Finder, and other external applications — SHALL reject the drag and the system cursor SHALL display the "not allowed" indicator (the NSDragOperation.none badge) while hovering over them.

Implementation SHALL advertise a private drag type identifier `com.cmux.screenshot-panel-drag` alongside the public `fileURL` / `image` types. Non-terminal drop handlers SHALL inspect for this private identifier and reject the drop. Terminal surfaces SHALL accept the drag and invoke the existing `TerminalImageTransfer` file-URL drop path.

#### Scenario: User drags a gallery cell over the File Explorer panel

- **WHEN** the user begins dragging a gallery cell and hovers over the File Explorer panel's drop zone
- **THEN** the cursor SHALL show the "not allowed" badge
- **AND** releasing the drag SHALL have no effect (no file operation, no panel state change)

#### Scenario: User drags a gallery cell into Finder

- **WHEN** the user drags outside of the cmux window and hovers over a Finder window
- **THEN** the cursor SHALL show the "not allowed" badge
- **AND** releasing the drag SHALL NOT copy or move the file to the Finder location

#### Scenario: User drags a gallery cell onto a terminal surface

- **WHEN** the user drags the cell onto a terminal surface
- **THEN** the cursor SHALL show the `.copy` drag operation indicator
- **AND** the drop SHALL invoke the existing terminal drop handler, which processes the drop via the existing `TerminalImageTransfer` file-URL path

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

#### Scenario: Rename target filename already exists in folder

- **WHEN** the user types a new filename that matches an existing file in the same folder (case-insensitive match on APFS default volumes) and presses Enter
- **THEN** the renamer SHALL check `FileManager.fileExists(atPath:)` before invoking `moveItem`
- **AND** no `moveItem` call SHALL be made
- **AND** no file SHALL be overwritten
- **AND** an inline error SHALL render directly below the rename text field with the message "File name already exists" (localized)
- **AND** the text field SHALL remain in edit mode with its current content so the user can amend without reopening Rename

### Requirement: Preview uses QLThumbnailGenerator with 512 KB direct-read fallback

The preview area SHALL obtain its image via `QLThumbnailGenerator.generateBestRepresentation(for:)` requesting a representation whose longest edge is 1024 pt. The panel SHALL NOT decode the original full-resolution file for preview. As an exception, files whose on-disk byte size is ≤ 512 KB MAY be rendered directly via `Image(nsImage: NSImage(contentsOf:))` (no thumbnail round-trip), because for small screenshots the direct path is measurably sharper without memory risk.

#### Scenario: Preview for a 10 MB PNG

- **WHEN** the selected entry's file is 10 MB
- **THEN** the preview SHALL be generated via `QLThumbnailGenerator` at 1024 pt longest edge
- **AND** the full 10 MB file SHALL NOT be loaded into an `NSImage` / `CGImage` in-memory representation for preview rendering

#### Scenario: Preview for a 100 MB PNG

- **WHEN** the selected entry's file is 100 MB
- **THEN** the preview SHALL still be generated via `QLThumbnailGenerator` at 1024 pt
- **AND** the panel's peak memory delta attributable to preview rendering SHALL NOT exceed 50 MB
- **AND** the main thread SHALL NOT block for more than 50 ms on preview setup (thumbnail generation is async; placeholder icon SHALL display during generation)

#### Scenario: Preview for a 200 KB PNG

- **WHEN** the selected entry's file is 200 KB
- **THEN** the preview MAY be rendered by directly loading the file via `NSImage(contentsOf:)`
- **AND** the direct-read path SHALL only be taken when `fileSize ≤ 512 KB`

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

### Requirement: Thumbnail cache keyed by URL and mtime

Generated thumbnails (grid cells, list rows, and the preview area's QLThumbnail representation) SHALL be stored in an in-process cache whose lookup key is the tuple `(absoluteURL, mtime)` — where `mtime` is the modification date in whole seconds. A cache hit SHALL require exact match on both fields. The cache SHALL implement LRU eviction with a maximum of 200 entries; eviction SHALL drop least-recently-used entries first.

This key design ensures that in-place edits to a file (e.g. the user annotates the screenshot in Preview and saves in-place) naturally miss the cache after the file watcher reload updates the entry's mtime, and a fresh thumbnail is generated without any explicit invalidation call.

#### Scenario: In-place edit causes a natural cache miss

- **WHEN** `entries[0]` points to `/Users/x/a.png` with `mtime = t1`
- **AND** the thumbnail for `(a.png, t1)` is already cached
- **AND** the user opens `a.png` in Preview, edits, and saves in-place so the file's mtime is now `t2 > t1`
- **AND** the ScreenshotStore file watcher reloads and `entries[0]` now carries `mtime = t2`
- **THEN** the gallery's cache lookup with key `(a.png, t2)` SHALL miss
- **AND** the thumbnail SHALL be regenerated via `QLThumbnailGenerator`
- **AND** the old `(a.png, t1)` entry SHALL become eligible for LRU eviction

#### Scenario: Different files do not evict each other prematurely

- **WHEN** 200 distinct files each have a cached thumbnail
- **AND** the user views `entries[5]` (making it most-recently-used)
- **AND** a 201st file is added and thumbnailed
- **THEN** the LRU victim SHALL be the oldest-accessed of the original 200 (not `entries[5]`)

### Requirement: Theme-aware rendering

The panel's backgrounds, borders, and text SHALL derive from the active ghostty config, matching the pattern used by the sidebar workspace rows and Claude stats views. The panel SHALL re-render on the `com.cmuxterm.themes.reload-config` notification.

#### Scenario: User switches ghostty theme

- **WHEN** the user changes the ghostty theme while the panel is visible
- **THEN** the `com.cmuxterm.themes.reload-config` notification fires
- **AND** the panel SHALL re-render with the new color palette on the next redraw cycle
