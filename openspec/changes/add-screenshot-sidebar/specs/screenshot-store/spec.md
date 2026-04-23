# Screenshot Store

## ADDED Requirements

### Requirement: Scan folder for image files by extension

`ScreenshotStore` SHALL enumerate every regular file in its configured folder whose extension (case-insensitive) is one of `png`, `jpg`, `jpeg`, `heic`, `gif`, or `webp`. The store SHALL NOT include directories, symlinks whose targets are directories, or files with other extensions.

#### Scenario: Folder contains a mix of images and non-image files

- **WHEN** the configured folder contains `a.png`, `b.JPG`, `c.pdf`, `d.heic`, and a subdirectory `sub/`
- **THEN** the store's entries SHALL include `a.png`, `b.JPG`, and `d.heic`
- **AND** the entries SHALL NOT include `c.pdf` or `sub/`

#### Scenario: Folder does not exist

- **WHEN** the configured folder path does not exist on disk
- **THEN** the store's entries SHALL be an empty array
- **AND** the store SHALL NOT raise a runtime exception
- **AND** the store SHALL expose a `loadError` value describing "folder missing"

#### Scenario: Folder exists but is not readable

- **WHEN** the configured folder exists but the process does not have read permission
- **THEN** the store's entries SHALL be an empty array
- **AND** the store SHALL expose a `loadError` value describing "permission denied"

### Requirement: Entries sorted by modification time, most recent first

The store's `entries` array SHALL be sorted by file modification time in strictly descending order. The entry whose `mtime` is greatest (most recent) SHALL appear at index 0.

#### Scenario: Multiple files with different mtimes

- **WHEN** the folder contains `a.png` (mtime t=100), `b.png` (mtime t=200), and `c.png` (mtime t=150)
- **THEN** `entries[0]` SHALL be `b.png`, `entries[1]` SHALL be `c.png`, and `entries[2]` SHALL be `a.png`

#### Scenario: Files with equal mtime tie-break by filename

- **WHEN** two files have identical mtime
- **THEN** the store SHALL sort them by filename in ascending lexicographic order

### Requirement: Scanning cap at 1000 entries with truncation flag

The store SHALL enumerate at most 1000 image files per folder scan. When the folder contains more than 1000 matching files, the store SHALL expose `isTruncated = true` and a `totalCountInFolder` count of the full match size. `entries` SHALL still be the 1000 most-recent items (not a random 1000).

#### Scenario: Folder has 2500 image files

- **WHEN** the configured folder contains 2500 image files
- **THEN** `entries.count` SHALL equal 1000
- **AND** `entries[0]` SHALL be the most-recently-modified file among all 2500
- **AND** `isTruncated` SHALL be `true`
- **AND** `totalCountInFolder` SHALL be `2500`

#### Scenario: Folder has 300 image files

- **WHEN** the configured folder contains 300 image files
- **THEN** `entries.count` SHALL equal 300
- **AND** `isTruncated` SHALL be `false`

### Requirement: File system watcher triggers reload on folder changes

The store SHALL install a `DispatchSource` file system object watcher on the configured folder's file descriptor with the event mask `{.write, .extend, .delete, .rename, .link}`. When any such event fires, the store SHALL reload its entries within 300 ms of the last event (debounced).

#### Scenario: A new screenshot is written to the folder

- **WHEN** the configured folder is being watched and `screencapture -c` writes a new `.png` to it at time t
- **THEN** by time `t + 300 ms` the store's `entries[0]` SHALL be the new file
- **AND** no explicit `reload()` call from the caller SHALL be required

#### Scenario: Multiple file events arrive within the debounce window

- **WHEN** five file-system events fire within 50 ms of each other
- **THEN** the store SHALL perform exactly one folder re-scan, not five

#### Scenario: Path changes to a different folder

- **WHEN** the caller assigns a new folder path to the store
- **THEN** the watcher on the old folder SHALL be cancelled
- **AND** a new watcher SHALL be installed on the new folder
- **AND** the entries SHALL be reloaded from the new folder

### Requirement: Watcher fallback to polling on network file systems

When the configured folder resides on a file system type of `nfs`, `smbfs`, `webdav`, or `osxfuse` (detected via `statfs`), the store SHALL replace the `DispatchSource` watcher with a 5-second polling timer. Local APFS / HFS+ volumes SHALL use the `DispatchSource` watcher.

#### Scenario: Path is on a local APFS volume

- **WHEN** the configured folder path is on APFS
- **THEN** the store SHALL use a `DispatchSource` file-system-object watcher
- **AND** the polling timer SHALL NOT be started

#### Scenario: Path is on an SMB network share

- **WHEN** `statfs` reports the folder's `f_fstypename` as `smbfs`
- **THEN** the store SHALL NOT install a `DispatchSource` watcher
- **AND** the store SHALL run a 5-second polling timer that calls `reload()` if the folder's listing fingerprint (set of `(name, mtime, size)` tuples) has changed

### Requirement: Published snapshots are value types

`ScreenshotStore.entries` SHALL be an array of value-type `ScreenshotEntry` structs containing the absolute file URL, last modification date, byte size, and a stable `id: UUID` derived deterministically from the absolute URL so list views can `ForEach(id: \.id)` across reloads without losing row identity.

#### Scenario: Same file observed across two reloads

- **WHEN** the folder is scanned at time t1 and again at time t2 and the file `a.png` exists at both scans with the same path
- **THEN** the `id` field of the entry for `a.png` in scan at t1 SHALL equal the `id` in scan at t2
