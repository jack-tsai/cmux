# Claude Stats Sidebar

## ADDED Requirements

### Requirement: Full stats block on focused workspace row

The sidebar SHALL render a full Claude stats block on the focused workspace row when `sidebar.showClaudeStats` is enabled AND the focused tab within that workspace has a non-stale `ClaudeStatsStore` snapshot. The block SHALL be placed below the existing branch / cwd meta line, separated by a horizontal divider.

The block SHALL contain, in order:
1. A tokens row with left-aligned session total and right-aligned current-usage breakdown.
2. A `ctx` row with a pixel progress bar filled to `context_window.used_percentage` and a right-aligned value showing `<N>%  compact <C>×`.
3. A `5h` row with a pixel progress bar filled to `rate_limits.five_hour.used_percentage` and a right-aligned value showing `<N>%  <remainingHours>h<remainingMinutes>m`.
4. A `7d` row with a pixel progress bar filled to `rate_limits.seven_day.used_percentage` and a right-aligned value showing `<N>%  <days>d<hours>h`.

#### Scenario: Focused workspace with active session and non-stale snapshot

- **WHEN** workspace `W` is focused, its focused tab has a snapshot with `used_percentage=28`, `rate_limits.five_hour.used_percentage=23, resets_at=now+40min`, and `rate_limits.seven_day.used_percentage=38, resets_at=now+1d19h`
- **THEN** the sidebar row for `W` SHALL render the full stats block with three bars in blue (below warn threshold) and right-aligned values `28%  compact 0×`, `23%  0h40m`, and `38%  1d19h`

#### Scenario: Focused workspace's focused tab has no Claude session

- **WHEN** workspace `W` is focused and its focused tab has no `ClaudeStatsStore` snapshot, regardless of whether sibling tabs in `W` do
- **THEN** the sidebar row for `W` SHALL NOT render a stats block (no divider, no empty bars, no fallback to sibling tab stats)

#### Scenario: Focused workspace, focused tab idle, sibling tab running Claude

- **WHEN** workspace `W` is focused, its focused tab has no snapshot, and a sibling tab in `W` has an active Claude session with a non-stale snapshot
- **THEN** the sidebar row for `W` SHALL NOT render the stats block
- **AND** the sibling tab's snapshot SHALL NOT leak into the focused row's display

### Requirement: Inline stats on unfocused workspace rows

Unfocused workspace rows SHALL display a compact monospace single-line summary when the workspace has at least one tab with a non-stale `ClaudeStatsStore` snapshot. The inline line SHALL use `<model> · ctx X% · 5h X% · 7d X%` format, where `<model>` is a 3-to-4-character short form of the snapshot's model id (`opus`, `son`, `hai`) derived from the first recognized substring of `model.id`. Numeric fields aggregate across tabs by taking the **maximum** used percentage. When the workspace has multiple active sessions with different models, the inline line SHALL display the model belonging to the session that contributed the maximum `ctx` value (tie-breaker: maximum `5h`, then first by `surface_id` lexicographic order).

#### Scenario: Unfocused workspace has one active session

- **WHEN** workspace `W` is not focused and has exactly one active Claude session with `model.id="claude-opus-4-7"`, `ctx=62%`, `5h=78%`, `7d=38%`
- **THEN** the sidebar row for `W` SHALL render `opus · ctx 62% · 5h 78% · 7d 38%` below the branch/cwd meta line

#### Scenario: Unfocused workspace has two active sessions with different models

- **WHEN** workspace `W` is not focused and has two tabs with snapshots: (`claude-sonnet-4-6`, ctx 30%, 5h 50%, 7d 20%) and (`claude-opus-4-7`, ctx 75%, 5h 40%, 7d 55%)
- **THEN** the inline row SHALL show `opus · ctx 75% · 5h 50% · 7d 55%` (model from the tab contributing max ctx; max per numeric field)

#### Scenario: Unknown model id

- **WHEN** the snapshot's `model.id` does not start with any of the recognized prefixes (`claude-opus`, `claude-sonnet`, `claude-haiku`)
- **THEN** the inline line SHALL omit the model segment and render `ctx X% · 5h X% · 7d X%`

#### Scenario: Unfocused workspace with no session

- **WHEN** workspace `W` is not focused and has no tabs with a snapshot
- **THEN** the sidebar row for `W` SHALL NOT render the inline line

### Requirement: Color thresholds derived from ghostty palette

Bar fill and numeric-value color SHALL follow the same threshold rules for `ctx`, `5h`, and `7d`:
- Below 60 %: `palette[4]` (ansi blue).
- 60 % – 84 % inclusive: `palette[3]` (ansi yellow), also applied to the numeric percentage text.
- 85 % or above: `palette[1]` (ansi red), also applied to the numeric percentage text.

#### Scenario: ctx percentage at 72 %

- **WHEN** `context_window.used_percentage == 72`
- **THEN** the `ctx` bar fill SHALL be drawn with the ANSI yellow color from the active ghostty palette
- **AND** the `72%` text SHALL be drawn in the same ANSI yellow

#### Scenario: 7d percentage at 92 %

- **WHEN** `rate_limits.seven_day.used_percentage == 92`
- **THEN** the `7d` bar fill SHALL be drawn with the ANSI red color from the active ghostty palette
- **AND** the `92%` text SHALL be drawn in the same ANSI red

### Requirement: Theme tracks ghostty config in real time

The stats block and inline row SHALL derive all colors (bar fills, foreground, dim tones, divider, bar track) from `GhosttyConfig`. Colors SHALL be cached in view-local `@State` and recomputed exactly once when `NotificationCenter` posts `com.cmuxterm.themes.reload-config`.

#### Scenario: User switches ghostty theme while sidebar is open

- **WHEN** the user changes the ghostty theme and the `com.cmuxterm.themes.reload-config` notification fires
- **THEN** the sidebar's stats bars and inline rows SHALL re-render with the new palette on the next redraw cycle
- **AND** the palette SHALL be recomputed from the freshly loaded `GhosttyConfig`, not from a cached pre-change config

### Requirement: Stale snapshot rendering

When `ClaudeStatsStore` reports `isStale == true` for the snapshot backing a row, the UI SHALL dim the entire stats block / inline row to approximately 40 % effective opacity (by blending foreground and background via the same `color-mix` rule used for `fg-faint`) and SHALL append the monospace suffix `(stale)` after the last value.

#### Scenario: Snapshot has not been updated for 35 seconds

- **WHEN** the focused workspace's snapshot is stale (no update for 35 s)
- **THEN** the stats block SHALL render dimmed
- **AND** the last row SHALL include `(stale)` at the end of its right-aligned value

### Requirement: Feature toggle hides the entire stats UI

The setting `sidebar.showClaudeStats` (persisted via `@AppStorage("sidebar.showClaudeStats")` and the `~/.config/cmux/settings.json` key of the same name, default `true`) SHALL gate both the full block and the inline row. When disabled, the sidebar SHALL render exactly as it did before this feature was introduced.

#### Scenario: User disables the feature via Debug menu

- **WHEN** the user toggles `sidebar.showClaudeStats` to `false`
- **THEN** no sidebar workspace row SHALL render any stats block or inline row
- **AND** the existing branch / cwd / message preview layout SHALL remain unchanged

#### Scenario: User re-enables the feature

- **WHEN** the user toggles `sidebar.showClaudeStats` from `false` back to `true` while `ClaudeStatsStore` contains snapshots
- **THEN** stats blocks and inline rows SHALL reappear immediately on the next frame, using the most recent snapshots
- **AND** no fresh statusline tick SHALL be required to render them

### Requirement: Snapshot-boundary compliance for sidebar rows

Sidebar workspace rows, their stats blocks, and inline rows SHALL receive all stats data as immutable value snapshots plus closure action bundles. No row-level view SHALL hold an `@ObservedObject`, `@EnvironmentObject`, `@StateObject`, or plain reference to `ClaudeStatsStore` or to any other `ObservableObject`.

#### Scenario: Row receives only snapshot values

- **WHEN** the sidebar `LazyVStack` creates an instance of the stats block subview
- **THEN** the subview's stored properties SHALL consist exclusively of value types (`struct` snapshots, closures, and primitive types)
- **AND** the subview SHALL NOT contain any property whose type is an `ObservableObject`, `@ObservedObject`, `@EnvironmentObject`, or `@StateObject`

### Requirement: Free-tier user state

When a snapshot has `rateLimits == nil` (Claude.ai free tier), the full stats block SHALL show only the tokens row and the `ctx` row, SHALL NOT show `5h` or `7d` rows, and SHALL show a one-time helper note `No quota data (Claude.ai free)` below the `ctx` row.

#### Scenario: Free user session snapshot arrives

- **WHEN** the focused tab's snapshot has `rateLimits == nil`
- **THEN** the stats block SHALL render only tokens and ctx rows
- **AND** a single hint line `No quota data (Claude.ai free)` SHALL appear once directly below the ctx row
