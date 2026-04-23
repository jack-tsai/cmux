# Claude Statusline Setup

## ADDED Requirements

### Requirement: Detect whether cmux statusline is wired into Claude Code

On cmuxd launch and after any change to `ClaudeStatsStore`, the system SHALL inspect `~/.claude/settings.json` and classify the connection status as one of:
- `connected`: `statusLine.command` is set to a string that starts with `cmux statusline`, `cmux-dev statusline`, or an absolute path that resolves to a cmux-managed CLI binary whose first argument is `statusline`.
- `disconnected`: the file exists but `statusLine.command` is absent or points elsewhere.
- `fileMissing`: the file `~/.claude/settings.json` does not exist.

#### Scenario: Settings file points at cmux statusline

- **WHEN** `~/.claude/settings.json` contains `"statusLine": { "type": "command", "command": "cmux statusline" }`
- **THEN** the classification SHALL be `connected`

#### Scenario: Settings file points at another statusline tool

- **WHEN** `~/.claude/settings.json` contains `"statusLine": { "type": "command", "command": "npx cc-statusline" }`
- **THEN** the classification SHALL be `disconnected`

#### Scenario: Settings file does not exist yet

- **WHEN** `~/.claude/settings.json` is not present on disk
- **THEN** the classification SHALL be `fileMissing`

### Requirement: Sidebar setup card on the focused workspace row

When the connection status is `disconnected` or `fileMissing`, the sidebar SHALL render a one-time setup card inside the focused workspace row (in place of the stats block) that offers exactly three actions: `Auto-configure`, `I'll edit it myself`, and `Don't show again`. When the status is `connected`, the setup card SHALL NOT appear.

#### Scenario: First launch with cc-statusline already configured

- **WHEN** connection status is `disconnected` because the user has `cc-statusline` configured
- **THEN** the focused workspace row SHALL show the setup card with the three actions above
- **AND** the stats block SHALL NOT render in place of the card

#### Scenario: Already connected

- **WHEN** connection status is `connected`
- **THEN** the setup card SHALL NOT appear and the stats block SHALL render normally

#### Scenario: User dismisses the card permanently

- **WHEN** the user clicks `Don't show again`
- **THEN** the system SHALL record the dismissal in `@AppStorage("sidebar.claudeSetupCardDismissed")`
- **AND** the card SHALL NOT appear again until `sidebar.claudeSetupCardDismissed` is reset

### Requirement: Atomic auto-configure writes with backup

When the user selects `Auto-configure`, the system SHALL write `statusLine.command = "cmux statusline"` into `~/.claude/settings.json` using an atomic replace, after copying the current file to `~/.claude/settings.json.bak` **only when `.bak` does not already exist**. When `.bak` already exists, the system SHALL NOT overwrite it, preserving the user's pre-cmux settings snapshot even across repeated Auto-configure clicks. For `fileMissing`, the system SHALL create a new `settings.json` containing exactly `{"statusLine": {"type": "command", "command": "cmux statusline"}}` and SHALL NOT create any `.bak` file (nothing to back up).

#### Scenario: Existing settings file has unrelated keys

- **WHEN** `~/.claude/settings.json` currently contains `{"autoAcceptEdits": true}` and the user clicks `Auto-configure`
- **THEN** the system SHALL create `~/.claude/settings.json.bak` with the original contents
- **AND** the system SHALL atomically replace `~/.claude/settings.json` with `{"autoAcceptEdits": true, "statusLine": {"type": "command", "command": "cmux statusline"}}`
- **AND** the resulting file SHALL be parseable as JSON

#### Scenario: Existing settings file has a different statusLine

- **WHEN** the file contains `"statusLine": { "type": "command", "command": "old-script.sh" }` and the user clicks `Auto-configure`
- **THEN** the backup SHALL preserve the old `statusLine` value
- **AND** the replaced file SHALL have `statusLine.command == "cmux statusline"`

#### Scenario: Auto-configure clicked twice; .bak already exists

- **WHEN** the user has previously run `Auto-configure` (producing `~/.claude/settings.json.bak`), later reverts the `statusLine.command` manually, and clicks `Auto-configure` again
- **THEN** the existing `~/.claude/settings.json.bak` SHALL remain unchanged, preserving the pre-cmux snapshot
- **AND** `~/.claude/settings.json` SHALL be replaced with the new content containing `statusLine.command == "cmux statusline"`

#### Scenario: Atomic write fails

- **WHEN** the atomic replace fails (disk full, permission denied)
- **THEN** the original `~/.claude/settings.json` SHALL remain untouched
- **AND** the UI SHALL surface an inline error message describing the reason and SHALL NOT dismiss the setup card

### Requirement: PreCompact hook is written alongside auto-configure

When `Auto-configure` is selected, the same atomic write SHALL add a `PreCompact` hook entry invoking `cmux record-compact`, unless such an entry already exists.

#### Scenario: Auto-configure on a file with no hooks section

- **WHEN** the user clicks `Auto-configure` on a settings file without a `hooks` key
- **THEN** the written file SHALL contain a `hooks.PreCompact` array with one entry whose `hooks[0].command == "cmux record-compact"`

#### Scenario: Auto-configure on a file that already has the PreCompact hook

- **WHEN** the settings file already contains a PreCompact hook entry referencing `cmux record-compact`
- **THEN** the write SHALL NOT duplicate the entry

### Requirement: Setup card behavior on dev (tagged) cmux builds

Tagged development builds (`cmux DEV <tag>.app`) SHALL offer `Auto-configure` targeting the `cmux-dev` CLI shim rather than the production `cmux` binary, so the Release and Debug apps do not overwrite each other's configuration.

#### Scenario: User clicks Auto-configure in a tagged Debug build

- **WHEN** `Auto-configure` is clicked inside a Debug build launched by `./scripts/reload.sh --tag <tag>`
- **THEN** the written `statusLine.command` SHALL be `cmux-dev statusline`
- **AND** the `PreCompact` hook command SHALL be `cmux-dev record-compact`
