# Diff Panel

## ADDED Requirements

### Requirement: Rename handling uses new-path only

For `workingCopyVsHEAD` mode, the DiffProvider SHALL invoke `git diff HEAD -- <new-path>` without the `-M` rename-detection flag. Renames SHALL be surfaced as the underlying delete + add that git reports by default.

#### Scenario: Diffing a renamed file

- **WHEN** the user Cmd+Clicks a file whose path has been renamed in the working tree (status `R`) at the new path
- **THEN** the DiffProvider SHALL run `git diff HEAD -- <new-path>` (no `-M`)
- **AND** the old path SHALL NOT be passed as a separate argument
- **AND** the panel SHALL render whatever `git diff` emits for the new path, including when the result is an all-added block

### Requirement: Read-only unified diff tab

The system SHALL provide a `PanelType.diff` panel that renders a unified-format diff for a given file in one of two modes: *working-copy-vs-HEAD* or *commit-vs-parent*. The panel MUST open as its own split tab and MUST NOT offer any editing affordance.

#### Scenario: Opening a diff from File Explorer

- **WHEN** the caller opens a diff panel with mode "working-copy-vs-HEAD" and path `<workspace>/src/foo/bar.swift`
- **THEN** a new tab SHALL appear with the panel type `.diff`
- **AND** the panel SHALL display the output of `git diff HEAD -- src/foo/bar.swift` rendered line-by-line

#### Scenario: Opening a diff from Git Graph

- **WHEN** the caller opens a diff panel with mode "commit-vs-parent" for sha `abc123` and path `src/foo/bar.swift`
- **THEN** the panel SHALL display the output of `git show abc123 -- src/foo/bar.swift` (or an equivalent two-sha diff invocation) restricted to that path

#### Scenario: Merge commit diff uses first parent only

- **WHEN** the commit with sha `abc123` has two or more parents (i.e. is a merge commit) and the caller opens a diff panel with mode "commit-vs-parent" for that sha
- **THEN** the panel SHALL display the diff between `abc123` and its FIRST parent (`abc123^1`) only
- **AND** the panel SHALL NOT render a combined diff (git's `-c` / `--cc`) in v1
- **AND** the toolbar scope label SHALL include the first-parent short sha (e.g. `abc123 vs parent def456`) so the user can tell which side is being shown

### Requirement: Diff line type rendering

The panel SHALL render added, removed, and context lines distinctly and MUST render hunk headers distinctly.

#### Scenario: Added line coloring

- **WHEN** a line begins with `+` and is not a file header
- **THEN** the panel SHALL render that line with the success/added color from the theme

#### Scenario: Removed line coloring

- **WHEN** a line begins with `-` and is not a file header
- **THEN** the panel SHALL render that line with the danger/removed color from the theme

#### Scenario: Hunk header rendering

- **WHEN** a line begins with `@@`
- **THEN** the panel SHALL render the line in a hunk-header style distinct from context lines

### Requirement: No-change empty state

The panel SHALL detect the case where the computed diff output is empty and present an explicit empty state rather than a blank panel.

#### Scenario: Working copy identical to HEAD

- **WHEN** the caller opens a diff panel for a file whose working copy matches HEAD exactly
- **THEN** the panel SHALL display a "No changes" message
- **AND** the panel SHALL NOT display any empty rows or ambiguous blank state

### Requirement: Binary diff handling

The system SHALL detect binary diffs reported by `git diff` and display a clear indication instead of attempting line-level rendering.

#### Scenario: Diffing a binary asset

- **WHEN** the `git diff` output contains `Binary files ... differ`
- **THEN** the panel SHALL display a "Binary file changed" notice in place of line-by-line rendering

### Requirement: Diff scope label

The panel SHALL prominently display a label indicating the diff scope (e.g., "Working copy vs HEAD" or "abc123 vs parent").

#### Scenario: Working copy mode label

- **WHEN** the panel opens in mode "working-copy-vs-HEAD"
- **THEN** the toolbar SHALL display the text "Working copy vs HEAD"

### Requirement: Snapshot at open and on re-focus

The panel SHALL compute the diff when the tab is first created, and SHALL ALSO recompute the diff whenever the dispatch system focuses an existing diff tab as a result of a duplicate open request. The panel SHALL NOT install a continuous file-system or git-status watcher. A manual refresh action SHALL also recompute the diff.

#### Scenario: File changes after diff opens and no re-click arrives

- **WHEN** the working copy of an already-open diff's target file is modified AND no duplicate open request arrives
- **THEN** the displayed diff SHALL reflect the version computed at the previous compute cycle
- **AND** invoking the panel's refresh action SHALL recompute the diff and update the view

#### Scenario: Duplicate Cmd+Click re-computes the diff

- **WHEN** the user Cmd+Clicks a file whose diff tab is already open
- **THEN** the system SHALL focus the existing tab
- **AND** the panel SHALL re-run its git invocation before the tab becomes visible
- **AND** the new diff SHALL appear without the user taking any further action

### Requirement: Theme synchronization

The panel SHALL apply the workspace ghostty theme to foreground, background, added, removed, and hunk-header styles, and MUST refresh when the `com.cmuxterm.themes.reload-config` notification fires.

#### Scenario: Theme changes mid-session

- **WHEN** the user changes ghostty theme while a diff panel is open
- **THEN** the panel SHALL re-render with the new theme on the next redraw cycle

### Requirement: Read-only focus behavior

The panel SHALL NOT route typing keystrokes to any text-editing handler; typing keys received with diff panel focus SHALL have no effect on the underlying file.

#### Scenario: User types while diff panel is focused

- **WHEN** a typing keystroke is received while the diff panel has focus
- **THEN** the file content on disk SHALL NOT change
- **AND** the diff output on screen SHALL NOT mutate

### Requirement: SSH workspace fallback

For a workspace whose `remoteConfiguration` is non-nil (SSH), the diff panel open action SHALL be declined cleanly in v1.

#### Scenario: Diff opened on SSH workspace

- **WHEN** the caller invokes the open-diff action inside an SSH-configured workspace
- **THEN** the system SHALL NOT open a diff panel
- **AND** the system SHALL NOT raise a runtime error
