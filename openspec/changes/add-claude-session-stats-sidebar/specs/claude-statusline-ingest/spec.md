# Claude Statusline Ingest

## ADDED Requirements

### Requirement: `cmux statusline` subcommand as Claude Code statusLine command

The cmux CLI SHALL expose a `statusline` subcommand that is invoked by Claude Code through the `statusLine.command` setting in `~/.claude/settings.json`. The subcommand SHALL read one JSON payload from stdin, resolve the owning cmux tab, forward the payload to cmuxd, and print an empty line to stdout. The subcommand MUST exit within 500 ms for any reasonably sized payload.

#### Scenario: Claude Code invokes the subcommand with a complete payload

- **WHEN** Claude Code spawns `cmux statusline` and writes the standard stdin JSON payload (containing `session_id`, `cwd`, `transcript_path`, `model`, `context_window`, and optionally `rate_limits`)
- **THEN** the subcommand SHALL parse the JSON without aborting on unknown fields
- **AND** the subcommand SHALL send exactly one `claude.statusline` message to the cmuxd unix socket
- **AND** the subcommand SHALL print an empty string to stdout (terminating with a newline)
- **AND** the subcommand SHALL exit with status code 0

#### Scenario: Stdin JSON is malformed

- **WHEN** the subcommand receives stdin that cannot be decoded as valid JSON
- **THEN** the subcommand SHALL NOT crash or raise a runtime exception
- **AND** the subcommand SHALL print an empty string to stdout
- **AND** the subcommand SHALL exit with status code 0 so Claude Code's UI is not disrupted

### Requirement: Socket and tab binding via environment variables

The subcommand SHALL identify its owning cmux tab by reading the `CMUX_SURFACE_ID` environment variable and SHALL identify the cmuxd socket to connect to by reading the `CMUX_SOCKET` environment variable. cmux SHALL export both variables into every terminal tab's child shell. A tagged Debug build SHALL set `CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock`; a Release build SHALL set `CMUX_SOCKET` to the Release build's cmuxd socket path. This lets Release and Debug cmux apps coexist — each tab's subcommand invocation routes its payload to the cmuxd that owns that tab.

The subcommand SHALL include the resolved `surface_id` verbatim in every `claude.statusline` socket message.

#### Scenario: CMUX_SURFACE_ID is set

- **WHEN** the subcommand is invoked in a process whose environment contains `CMUX_SURFACE_ID=<uuid>`
- **THEN** the outbound socket message SHALL carry `surface_id: <uuid>`

#### Scenario: CMUX_SURFACE_ID is missing

- **WHEN** the subcommand is invoked without `CMUX_SURFACE_ID` in the environment
- **THEN** the subcommand SHALL still send the socket message with `surface_id: null`
- **AND** cmuxd SHALL NOT associate the payload with any tab and SHALL drop it without error

#### Scenario: CMUX_SOCKET is missing

- **WHEN** the subcommand is invoked without `CMUX_SOCKET` in the environment
- **THEN** the subcommand SHALL NOT attempt to open any socket
- **AND** the subcommand SHALL print an empty string to stdout
- **AND** the subcommand SHALL exit with status code 0

#### Scenario: Release and Debug cmux apps coexist

- **WHEN** the user has both a Release cmux app and a tagged Debug cmux app running, each with its own `CMUX_SOCKET` exported into its tabs' shells
- **THEN** a `cmux statusline` invocation in a Release tab SHALL send its payload only to the Release cmuxd socket
- **AND** a `cmux statusline` invocation in a Debug tab SHALL send its payload only to the Debug cmuxd socket
- **AND** neither cmuxd SHALL receive payloads from the other app's tabs

### Requirement: Socket transport is single-writer and fire-and-forget

The subcommand SHALL write a single JSON-line message to cmuxd's unix socket and exit without waiting for any response.

#### Scenario: Sending the statusline message

- **WHEN** the subcommand forwards the payload
- **THEN** the subcommand SHALL open the cmuxd unix socket, write one line of the form `{"cmd":"claude.statusline","v":1,"surface_id":...,"session_id":...,"at":<epoch_seconds>,"payload":{...}}`, and close the socket
- **AND** the subcommand SHALL NOT wait for any acknowledgement message

#### Scenario: cmuxd socket is unavailable

- **WHEN** the subcommand fails to open the cmuxd socket (cmux app not running, permission denied, path missing)
- **THEN** the subcommand SHALL NOT crash
- **AND** the subcommand SHALL print an empty string to stdout
- **AND** the subcommand SHALL exit with status code 0

### Requirement: cmuxd ingest updates ClaudeStatsStore per tab

cmuxd SHALL receive `claude.statusline` messages and update `ClaudeStatsStore` on the main actor, keyed by `surface_id`. The store entry SHALL retain: `sessionId`, `receivedAt` (monotonic timestamp), `model`, `contextWindow`, `rateLimits`, `totalInputTokens`, `totalOutputTokens`, `isCurrentUsageNull`, and `exceeds200kTokens`.

#### Scenario: Valid statusline message is received

- **WHEN** cmuxd receives `{"cmd":"claude.statusline","v":1,"surface_id":"<A>","session_id":"<S>","at":<T>,"payload":{...}}`
- **THEN** `ClaudeStatsStore.snapshots["<A>"]` SHALL be set to a snapshot with `sessionId == "<S>"` and the decoded payload fields
- **AND** `snapshots["<A>"].receivedAt` SHALL equal the cmuxd-side receive time, not the subcommand-emitted `at`

#### Scenario: Unknown `v` version in message

- **WHEN** cmuxd receives a message whose `v` field is greater than cmuxd's known maximum
- **THEN** cmuxd SHALL drop the message silently and SHALL NOT update any store entry

### Requirement: Staleness flag on per-tab snapshots

`ClaudeStatsStore` SHALL mark a tab's snapshot as `isStale == true` when its `receivedAt` is more than 30 seconds old. UI consumers SHALL read `isStale` and dim the stats display accordingly.

#### Scenario: A snapshot has not been updated for 35 seconds

- **WHEN** 35 seconds elapse after the last `claude.statusline` message for a given `surface_id`
- **THEN** `ClaudeStatsStore.snapshots["<tab>"]?.isStale` SHALL return `true`

#### Scenario: A snapshot was just updated

- **WHEN** a `claude.statusline` message for `<tab>` was received less than 30 seconds ago
- **THEN** `ClaudeStatsStore.snapshots["<tab>"]?.isStale` SHALL return `false`

### Requirement: Schema tolerance for Claude Code version drift

The ingest decoder SHALL use optional decoding for every field in the stdin JSON payload. A missing or unrecognized field SHALL NOT cause the whole message to be dropped.

#### Scenario: Payload missing `rate_limits` (free-tier user)

- **WHEN** cmuxd receives a payload without the `rate_limits` object
- **THEN** the snapshot SHALL be stored with `rateLimits == nil` and all other fields populated

#### Scenario: Payload contains an unknown top-level field

- **WHEN** cmuxd receives a payload containing a new top-level key that cmuxd does not yet recognize
- **THEN** the decoder SHALL ignore the unknown field and populate all recognized fields normally
