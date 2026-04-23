# Claude Compact Tracking

## ADDED Requirements

### Requirement: `cmux record-compact` subcommand as PreCompact hook

The cmux CLI SHALL expose a `record-compact` subcommand invoked as a Claude Code `PreCompact` hook. When invoked, the subcommand SHALL read one JSON payload from stdin (the standard Claude Code hook envelope containing at minimum `session_id`), forward a `claude.compact` event to cmuxd, and exit with status 0.

#### Scenario: PreCompact hook fires mid-session

- **WHEN** Claude Code fires the PreCompact hook and spawns `cmux record-compact` with the hook JSON on stdin
- **THEN** the subcommand SHALL parse the JSON and extract `session_id`
- **AND** the subcommand SHALL send exactly one `claude.compact` message to the cmuxd unix socket
- **AND** the subcommand SHALL exit within 500 ms with status 0

#### Scenario: Hook payload is missing session_id

- **WHEN** the stdin JSON has no `session_id` field
- **THEN** the subcommand SHALL NOT crash
- **AND** the subcommand SHALL exit with status 0 without sending a socket message

### Requirement: Per-session compact counter in cmuxd

`ClaudeStatsStore` SHALL maintain a compact counter keyed by `session_id`. Each `claude.compact` event SHALL increment that session's counter by 1.

#### Scenario: First compact event for a session

- **WHEN** cmuxd receives the first `{"cmd":"claude.compact","session_id":"<S>"}` message for session `<S>`
- **THEN** `ClaudeStatsStore.compactCount(for: "<S>")` SHALL return 1

#### Scenario: Multiple compact events for the same session

- **WHEN** cmuxd receives three successive `claude.compact` messages for session `<S>`
- **THEN** `ClaudeStatsStore.compactCount(for: "<S>")` SHALL return 3

### Requirement: Counter persistence across cmux app restarts

The per-session compact count SHALL persist to disk at `~/Library/Application Support/cmux/claude-compact-count.json` as a JSON object of the form `{"entries": {"<session_id>": {"count": <int>, "lastSeen": <epoch_seconds>}}, "version": 1}`. cmuxd SHALL load this file on launch and SHALL flush updates at most once every 10 seconds using debounced writes. Legacy files containing a flat `{session_id: count}` object SHALL be migrated on load by synthesizing `lastSeen = now` for every entry.

#### Scenario: cmux restarts with prior compact counts on disk

- **WHEN** `~/Library/Application Support/cmux/claude-compact-count.json` contains `{"<S>": 4}` at cmux launch
- **THEN** `ClaudeStatsStore.compactCount(for: "<S>")` SHALL return 4 immediately after store initialization

#### Scenario: Compact count is flushed after debounce

- **WHEN** a `claude.compact` event is processed and no further events arrive for 10 seconds
- **THEN** the on-disk `claude-compact-count.json` SHALL reflect the new count

#### Scenario: Compact count write fails

- **WHEN** the debounced flush encounters a filesystem error (disk full, permission denied)
- **THEN** cmuxd SHALL retain the in-memory counter
- **AND** cmuxd SHALL retry the flush on the next debounce cycle
- **AND** cmuxd SHALL NOT crash

### Requirement: LRU prune at 500 entries

When the on-disk `claude-compact-count.json` would contain more than 500 entries after a flush, cmuxd SHALL prune entries by ascending `lastSeen` timestamp until exactly 500 entries remain. `lastSeen` SHALL be updated to the current epoch each time a session's counter is incremented. The prune SHALL run inside the same debounced flush transaction that caused the overflow.

#### Scenario: 501st session gets its first compact event

- **WHEN** cmuxd has 500 distinct sessions in `claude-compact-count.json`, each with `lastSeen` values, and a brand-new session receives its first `claude.compact` event
- **THEN** the debounced flush SHALL add the new session's entry
- **AND** the single oldest entry (smallest `lastSeen`) SHALL be removed
- **AND** the resulting file SHALL contain exactly 500 entries including the new one

#### Scenario: Touching an existing session refreshes lastSeen

- **WHEN** an existing session that was close to the oldest in `lastSeen` order receives a new compact event
- **THEN** that session's `lastSeen` SHALL be updated to the current epoch before any prune check runs
- **AND** the prune (if triggered) SHALL NOT evict the just-touched session

### Requirement: Counter is per-session, not per-tab

Compact counts SHALL be keyed by `session_id` rather than `surface_id`, so a Claude `/resume` that loads an existing session preserves its compact count even when the owning tab changes.

#### Scenario: `/resume` reuses an older session_id

- **WHEN** session `<S>` has compact count 2, the tab is closed, and later a new tab runs `claude --resume <S>`
- **THEN** `ClaudeStatsStore.compactCount(for: "<S>")` SHALL still return 2

#### Scenario: New session in a tab that previously hosted a different session

- **WHEN** tab `<A>` previously hosted session `<S1>` (compact count 5), and a fresh `claude` invocation in `<A>` starts new session `<S2>`
- **THEN** `ClaudeStatsStore.compactCount(for: "<S2>")` SHALL return 0
- **AND** `compactCount(for: "<S1>")` SHALL remain 5
