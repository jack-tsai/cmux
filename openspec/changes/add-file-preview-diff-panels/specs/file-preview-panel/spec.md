# File Preview Panel

## ADDED Requirements

### Requirement: Open file as read-only preview tab

The system SHALL provide a `PanelType.filePreview` panel that opens a given absolute file path as a read-only, monospaced text view inside a new split tab. The panel MUST be usable alongside existing terminal, markdown, and git-graph panels within the same workspace.

#### Scenario: Opening a plain text file

- **WHEN** a caller invokes the open-file-preview action with a valid UTF-8 readable file path
- **THEN** a new tab SHALL appear with the panel type `.filePreview`
- **AND** the panel SHALL display the file contents using a monospaced font
- **AND** the panel SHALL render line numbers in a left gutter, right-aligned, starting at 1

#### Scenario: Tab title reflects filename

- **WHEN** a file preview panel opens `<workspace>/src/foo/bar.swift`
- **THEN** the tab title SHALL be `bar.swift`

### Requirement: Binary file detection

The system SHALL detect binary files and avoid attempting to render their raw bytes as text.

#### Scenario: Preview opens a binary file

- **WHEN** the target file contains a NUL byte within the first 8 KB of content
- **THEN** the panel SHALL display a "Binary file" placeholder message instead of raw content
- **AND** the panel SHALL present a button that dispatches `less <path>` to the focused terminal

### Requirement: Missing file graceful handling

The system SHALL handle the case where the target path does not exist or is unreadable without crashing and without blocking the main thread.

#### Scenario: Preview opens a path that no longer exists

- **WHEN** the target file path returns ENOENT at load time
- **THEN** the panel SHALL display a "File unavailable" placeholder
- **AND** the panel SHALL NOT raise a runtime exception or log an uncaught error

### Requirement: Large file truncation

The system SHALL cap preview rendering to the first 10000 lines OR first 2 MB of content, whichever comes first.

#### Scenario: File with 50000 lines

- **WHEN** a file larger than 10000 lines is opened for preview
- **THEN** the panel SHALL display only the first 10000 lines
- **AND** a footer row SHALL inform the user that the file was truncated
- **AND** the footer SHALL offer an "Open in Terminal" action that dispatches `less <path>` to the focused terminal

### Requirement: Theme synchronization

The panel SHALL render text using the workspace ghostty theme's foreground color, background color, and monospace palette, and MUST refresh its theme when the `com.cmuxterm.themes.reload-config` notification fires.

#### Scenario: User switches ghostty theme

- **WHEN** the user changes ghostty theme while a file preview panel is open
- **THEN** the panel SHALL re-render with the new theme colors on the next redraw cycle

### Requirement: No write path exposed

The panel SHALL NOT provide any UI affordance that modifies the underlying file, including text selection that captures and mutates characters, drag-out-to-save, or keyboard input passthrough that could edit the file.

#### Scenario: User presses a typing key while focused on the preview

- **WHEN** a typing keystroke (a–z, 0–9, etc.) is received while the file preview panel has focus
- **THEN** the file content on disk SHALL NOT change
- **AND** the on-screen text SHALL NOT mutate

### Requirement: Panel state is snapshot at open and on re-focus

The panel SHALL load file content when the tab is first created, and SHALL ALSO re-load file content whenever the dispatch system focuses an existing preview tab as a result of a duplicate open request. The panel SHALL NOT install a continuous file-system watcher.

#### Scenario: File changes on disk while preview is open but not re-clicked

- **WHEN** an already-open preview's underlying file is modified externally AND no duplicate open request arrives
- **THEN** the visible content SHALL remain the version loaded at the previous load cycle
- **AND** no automatic refresh SHALL occur

#### Scenario: Duplicate Cmd+Click re-loads the preview

- **WHEN** the user Cmd+Clicks a file whose preview tab is already open
- **THEN** the system SHALL focus the existing tab
- **AND** the panel SHALL re-read the file contents from disk before the tab becomes visible
- **AND** the new content SHALL appear without the user taking any further action
