# File Open Dispatch

## ADDED Requirements

### Requirement: Central file-open decision function

The system SHALL expose a pure function `decide(path:workspace:) -> Decision` that, given an absolute file path and the owning workspace, returns exactly one of the following decisions: `.markdown`, `.diff(workingCopyVsHEAD)`, `.preview`, `.unsupported`. The function MUST NOT perform UI side effects.

#### Scenario: Markdown file in local workspace

- **WHEN** the path ends with `.md` (case-insensitive) or `.markdown` and the workspace is local
- **THEN** the function SHALL return `.markdown`

#### Scenario: Dirty non-markdown file in local workspace

- **WHEN** the path does not match markdown extensions and `git status --porcelain -- <path>` reports the file as modified (status `M`), added-to-index (`A`), or renamed (`R`)
- **THEN** the function SHALL return `.diff(workingCopyVsHEAD)`

#### Scenario: Untracked file

- **WHEN** `git status --porcelain -- <path>` reports the file as untracked (status `??`)
- **THEN** the function SHALL return `.preview`
- **AND** the function SHALL NOT return `.diff`, because no HEAD baseline exists

#### Scenario: Clean non-markdown file

- **WHEN** `git status --porcelain -- <path>` returns an empty result AND the path does not match markdown extensions
- **THEN** the function SHALL return `.preview`

#### Scenario: Path outside a git repository

- **WHEN** the path is not inside a git repository (toplevel lookup fails)
- **THEN** the function SHALL return `.preview` for non-markdown paths
- **AND** `.markdown` for markdown paths

#### Scenario: SSH workspace

- **WHEN** the workspace's `remoteConfiguration` is non-nil
- **THEN** the function SHALL return `.unsupported`

### Requirement: File Explorer Cmd+Click routes through dispatch

The File Explorer sidebar SHALL bind the Cmd+Click (or equivalent `Command-modifier + primary click`) gesture on a file row to invoke `decide(...)` and then open the corresponding panel.

#### Scenario: Cmd+Click opens markdown

- **WHEN** the user Cmd+Clicks a `.md` file row in the File Explorer
- **THEN** a new split tab SHALL open with the markdown panel type
- **AND** the existing markdown viewer SHALL be reused (not a new filePreview panel)

#### Scenario: Cmd+Click opens diff for dirty file

- **WHEN** the user Cmd+Clicks a file row whose file is modified in the working tree
- **THEN** a new split tab SHALL open with the `.diff` panel type in `workingCopyVsHEAD` mode

#### Scenario: Cmd+Click opens preview for clean file

- **WHEN** the user Cmd+Clicks a file row whose file is clean relative to HEAD (or is outside a repo)
- **THEN** a new split tab SHALL open with the `.filePreview` panel type

#### Scenario: Cmd+Click on directory row

- **WHEN** the user Cmd+Clicks a directory row
- **THEN** no panel SHALL open
- **AND** the existing outline expand/collapse behavior SHALL be unaffected

### Requirement: Git Graph file row dispatches to diff panel

The Git Graph commit-detail file list SHALL open the `.diff` panel (mode `commit-vs-parent`) on single tap of a file row, replacing any previous behavior that dispatched `git show` text to a terminal.

#### Scenario: Tapping a file in a commit's file list

- **WHEN** the user taps a file row under an expanded commit with sha `abc123` and path `src/foo.swift`
- **THEN** a new split tab SHALL open with the `.diff` panel type
- **AND** the diff mode SHALL be `commit-vs-parent` with sha `abc123` and path `src/foo.swift`
- **AND** no text SHALL be dispatched to any terminal

### Requirement: Symlinks are resolved before dispatch

When the clicked path is a symbolic link, the dispatch function SHALL resolve the link to its canonical target path and use the target path as the input to the dispatch decision (extension detection, `git status`, and panel routing).

#### Scenario: Cmd+Click on a symlink to a markdown file

- **WHEN** the user Cmd+Clicks `<workspace>/README.md` where `README.md` is a symlink to `docs/README.md`
- **THEN** the dispatch function SHALL resolve the path to `<workspace>/docs/README.md`
- **AND** the returned Decision SHALL be `.markdown` with the resolved path

#### Scenario: Cmd+Click on a broken symlink

- **WHEN** the user Cmd+Clicks a symlink whose target does not exist on disk
- **THEN** the dispatch function SHALL return `.unsupported`
- **AND** no panel SHALL open

### Requirement: Duplicate open focuses existing tab

When the user invokes the open action for a target that already has an open panel tab of the same type and the same underlying identity, the system SHALL focus the existing tab instead of creating a duplicate.

Panel identity used for dedup:
- `.filePreview` — identity is the absolute file path.
- `.diff` with mode `.workingCopyVsHEAD(path)` — identity is (`workingCopyVsHEAD`, absolute path).
- `.diff` with mode `.commitVsParent(sha, path)` — identity is (`commitVsParent`, sha, path).
- `.markdown` — identity is the absolute file path (existing behavior).

#### Scenario: Re-opening the same file preview

- **WHEN** a preview tab for `<workspace>/a.txt` is already open and the user Cmd+Clicks `a.txt` again
- **THEN** the system SHALL focus the existing tab
- **AND** the system SHALL NOT create a second preview tab

#### Scenario: Re-opening the same diff

- **WHEN** a diff tab with mode `workingCopyVsHEAD` for `a.swift` is already open and the user Cmd+Clicks `a.swift` (still dirty) again
- **THEN** the system SHALL focus the existing diff tab

#### Scenario: Opening the same path in a different mode

- **WHEN** a `.filePreview` tab for `<workspace>/a.txt` is already open and the user opens a `.diff` tab for the same path
- **THEN** the system SHALL open a new `.diff` tab
- **AND** the existing preview tab SHALL remain open

### Requirement: Non-interference with plain left-click

Plain (non-Cmd) left-click on File Explorer rows SHALL preserve the existing selection and expand/collapse semantics of the outline view; the dispatch logic MUST NOT be invoked.

#### Scenario: User clicks a file row without Cmd

- **WHEN** the user clicks a file row without holding the Command key
- **THEN** the row SHALL follow the existing selection behavior
- **AND** no file preview or diff panel SHALL open
