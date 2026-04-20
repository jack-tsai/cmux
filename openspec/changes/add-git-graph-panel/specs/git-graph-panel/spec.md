## ADDED Requirements

### Requirement: Git Graph Panel as main-area panel type

The system SHALL provide a new panel type `gitGraph` that participates in the existing main-area panel infrastructure (tabs, splits, workspace lifecycle, session persistence) alongside `terminal`, `browser`, and `markdown` panels. Users SHALL be able to open a Git Graph panel from the tab creation menu and through a user-configurable keyboard shortcut registered in keyboard shortcut settings.

#### Scenario: Open Git Graph panel from tab creation menu

- **WHEN** the user opens the tab creation menu in a workspace and selects "Git Graph"
- **THEN** a new Git Graph panel SHALL appear as a new tab bound to the current workspace's root directory

#### Scenario: Open Git Graph panel via keyboard shortcut

- **WHEN** the user invokes the configured keyboard shortcut for "Open Git Graph Panel"
- **THEN** the system SHALL open a new Git Graph panel in the active workspace

#### Scenario: Persist Git Graph panel across app restart

- **WHEN** a workspace with a Git Graph panel is restored from session persistence
- **THEN** the Git Graph panel SHALL reappear bound to the same workspace directory, with branch filter restored, the search mode (highlight vs filter) restored, and scroll position restored via a persisted anchor commit SHA plus a sub-row pixel offset

#### Scenario: Scroll anchor commit no longer in loaded window

- **WHEN** a panel is restored and its persisted anchor commit SHA is not present in the newly fetched first 500 commits
- **THEN** the panel SHALL scroll to the top of the commit list and SHALL NOT treat this as an error

### Requirement: Commit graph rendering with lanes and ref badges

The system SHALL render commits as a vertical list of rows with a dedicated graph column that draws commit dots, branch lanes with distinct colors, and merge line connections between parent and child commits. Each commit row SHALL display ref badges for branches, tags, and remote-tracking refs that point to that commit.

#### Scenario: Render linear history with single lane

- **WHEN** the current repository has a single linear branch with no merges
- **THEN** the system SHALL render one lane with commit dots connected by a single vertical line

#### Scenario: Render merge commit with multiple parents

- **WHEN** a commit has two or more parents
- **THEN** the system SHALL render the merge commit's dot joined to each parent lane with a visible connector

#### Scenario: Display ref badges on commit rows

- **WHEN** a commit is pointed to by one or more refs (local branch, remote branch, or tag)
- **THEN** each ref SHALL be displayed as a distinct badge on that commit's row

### Requirement: HEAD indicator on current commit

The system SHALL visually distinguish where `HEAD` resolves for the workspace's repository using a distinct HEAD marker. When the working tree is clean, the HEAD marker SHALL appear on the commit row pointed to by `HEAD`. When the Uncommitted Changes virtual row is present (i.e., working tree has changes), the HEAD marker SHALL appear on the Uncommitted Changes row instead, and the commit row pointed to by `HEAD` SHALL render as a regular commit dot (representing the parent of the uncommitted state).

#### Scenario: Clean working tree — HEAD on commit

- **WHEN** the repository HEAD resolves to a commit present in the rendered list and the working tree is clean
- **THEN** that commit's row SHALL show the HEAD marker distinct from ordinary commit dots

#### Scenario: Dirty working tree — HEAD on Uncommitted Changes

- **WHEN** the working tree has uncommitted changes so the Uncommitted Changes virtual row is rendered
- **THEN** the HEAD marker SHALL appear on the Uncommitted Changes row, and the commit at `HEAD` SHALL render as an ordinary commit dot without the HEAD marker

#### Scenario: Detached HEAD

- **WHEN** the repository is in detached HEAD state and the working tree is clean
- **THEN** the commit at detached HEAD SHALL be marked as HEAD and no local branch badge SHALL be shown at HEAD

### Requirement: Uncommitted Changes virtual row

The system SHALL render a virtual row at the top of the commit list labeled "Uncommitted Changes (N)" where N is the count of modified, added, deleted, or untracked paths returned by `git status --porcelain`. When N is zero, the row SHALL NOT be rendered.

#### Scenario: Uncommitted changes exist

- **WHEN** the working tree has one or more changes reported by `git status --porcelain`
- **THEN** the panel SHALL display a row "Uncommitted Changes (N)" at the top, above all commit rows

#### Scenario: Clean working tree

- **WHEN** the working tree is clean
- **THEN** the panel SHALL NOT display the Uncommitted Changes row

### Requirement: Inline commit detail expansion

The system SHALL allow the user to expand a commit row inline to reveal commit metadata (full SHA, parent SHAs, author, committer, date, full message) and a file tree showing changed files with per-file `+N / -M` numstat values obtained from `git show --numstat <sha>`. At most one row SHALL be expanded at a time; clicking an expanded row or another row SHALL collapse the first.

Clicking a file entry in the file tree SHALL dispatch the command `git show <sha> -- <file>` to an appropriate terminal panel in the same workspace, following this precedence:

1. If a terminal panel already exists in the same workspace, the system SHALL send the command text followed by a newline to that terminal's active surface and focus that panel.
2. If multiple terminal panels exist, the system SHALL target the most recently focused terminal panel in the workspace.
3. If no terminal panel exists in the workspace, the system SHALL open a new terminal panel in the workspace's root directory and then dispatch the command.

Clicking a directory entry in the file tree SHALL only expand/collapse the directory and SHALL NOT dispatch a command.

#### Scenario: Expand commit row

- **WHEN** the user clicks a commit row
- **THEN** the row SHALL expand inline to display full SHA, parents, author, committer, date, full message, and a file tree with numstat

#### Scenario: Only one row expanded at a time

- **WHEN** a row is already expanded and the user clicks a different commit row
- **THEN** the previously expanded row SHALL collapse and the newly clicked row SHALL expand

#### Scenario: File tree displays numstat

- **WHEN** a commit detail is expanded and `git show --numstat` returns added/deleted line counts per file
- **THEN** each file node in the tree SHALL display `+<added> / -<deleted>`

#### Scenario: Click file with existing terminal panel

- **WHEN** the user clicks a file entry in the expanded commit detail and a terminal panel exists in the same workspace
- **THEN** the system SHALL focus the most recently focused terminal panel in that workspace and send `git show <sha> -- <file>` followed by a newline to that terminal

#### Scenario: Click file with no terminal panel

- **WHEN** the user clicks a file entry and no terminal panel exists in the workspace
- **THEN** the system SHALL create a new terminal panel in the workspace root and dispatch `git show <sha> -- <file>` to it

#### Scenario: Click directory entry

- **WHEN** the user clicks a directory entry in the file tree
- **THEN** the directory SHALL toggle expanded/collapsed state and SHALL NOT produce any terminal command

### Requirement: Refs sidebar listing branches, tags, stashes, and worktrees

The system SHALL provide a collapsible sidebar within the Git Graph panel listing local branches, remote-tracking branches, tags, stashes, and worktrees in distinct collapsible sections. Clicking a branch or tag SHALL scroll the commit list to the commit that ref points to.

#### Scenario: Sidebar sections render

- **WHEN** the panel loads a repository with at least one branch, one tag, one stash, and one worktree
- **THEN** the sidebar SHALL show four sections: Branches, Tags, Stashes, Worktrees, each listing the corresponding entries

#### Scenario: Clicking a branch scrolls to its tip

- **WHEN** the user clicks a branch entry in the sidebar
- **THEN** the commit list SHALL scroll to make the branch's tip commit visible

#### Scenario: Empty sections collapse

- **WHEN** a section has zero entries (e.g., no stashes)
- **THEN** that section SHALL still be shown as collapsible but display an empty-state label

### Requirement: Single-branch filter

The system SHALL provide a branch filter control that allows the user to select exactly one branch; when a branch is selected, the commit list SHALL show only commits reachable from that branch (equivalent to `git log <branch>`). An "All" option SHALL restore the default view (`git log --all`).

#### Scenario: Select a branch filter

- **WHEN** the user selects a branch named `feature-x` in the branch filter
- **THEN** the commit list SHALL display only commits reachable from `feature-x`

#### Scenario: Restore "All" filter

- **WHEN** the user selects "All" in the branch filter
- **THEN** the commit list SHALL display commits from `git log --all`

#### Scenario: HEAD outside current filter

- **WHEN** a branch filter is active and the commit pointed to by `HEAD` is not reachable from the filtered branch (and the working tree is clean)
- **THEN** the commit list SHALL NOT show a HEAD marker on any row, AND a toolbar banner SHALL render showing "HEAD is on <branch-name>, not in current filter" with a "Show All" action that clears the filter

#### Scenario: HEAD outside current filter with dirty working tree

- **WHEN** a branch filter is active, the working tree is dirty, and `HEAD`'s commit is not reachable from the filtered branch
- **THEN** the Uncommitted Changes virtual row SHALL NOT render while the filter is active, AND the toolbar banner SHALL render showing "HEAD is on <branch-name> (uncommitted changes), not in current filter" with a "Show All" action

### Requirement: Commit search with highlight

The system SHALL provide a search input that performs case-insensitive substring matching against each loaded commit's message, author name, and SHA prefix. The system SHALL support two modes, selectable via a toggle control adjacent to the search input:

- **Highlight mode (default)**: all commit rows remain visible; matching rows SHALL render with a distinct highlighted background and the matched substring SHALL be rendered with a distinct foreground emphasis. The list SHALL scroll to the first matching row when the query changes.
- **Filter mode**: non-matching rows SHALL be hidden; only matching rows SHALL be rendered. Graph lanes that become discontinuous due to hidden rows SHALL be rendered as dashed placeholder segments rather than omitted.

When the search input is empty, both modes SHALL show all rows without highlighting.

#### Scenario: Highlight mode matches commit messages

- **WHEN** the user is in highlight mode (default) and types `dashboard` into the search input
- **THEN** all commit rows remain visible, rows whose commit message, author name, or SHA prefix contains `dashboard` (case-insensitive) SHALL render with a highlighted background and matched-substring emphasis, and the list SHALL scroll to the first match

#### Scenario: Filter mode hides non-matching rows

- **WHEN** the user switches the search mode toggle to filter and types `dashboard`
- **THEN** only rows matching `dashboard` SHALL be rendered; hidden rows SHALL NOT occupy vertical space; lane gaps SHALL be drawn as dashed placeholder segments

#### Scenario: Clear search

- **WHEN** the user clears the search input in either mode
- **THEN** all commit rows SHALL be shown without highlighting or filtering

#### Scenario: Toggle preserves query

- **WHEN** the user toggles between highlight and filter modes with a non-empty query
- **THEN** the query text SHALL be preserved and the display SHALL re-render in the newly selected mode

### Requirement: Stash entries displayed read-only

The system SHALL display stash entries in the Refs sidebar under a "Stashes" section using `git stash list`. When the user clicks a stash entry, the panel SHALL render that stash as a highlighted row at the top of the commit list (below Uncommitted Changes) and SHALL allow expanding that row to view file changes via `git stash show --numstat <stash-ref>`.

#### Scenario: Stash list in sidebar

- **WHEN** the repository has stashed changes
- **THEN** each stash SHALL appear as an entry in the sidebar's Stashes section with its index and message

#### Scenario: Click stash to view contents

- **WHEN** the user clicks a stash entry in the sidebar
- **THEN** a highlighted row representing that stash SHALL appear at the top of the commit list and SHALL be expandable to show file numstat

### Requirement: Worktree occupancy indication

The system SHALL query `git worktree list --porcelain` and display worktrees in the Refs sidebar. When a local branch is checked out in a worktree other than the panel's own workspace, the branch's ref badge in the commit list SHALL display a worktree-indicator icon with a tooltip showing the occupying worktree's path. The worktree containing the panel's workspace SHALL be marked distinctly in the sidebar.

#### Scenario: Branch checked out in another worktree

- **WHEN** branch `feature-x` is checked out in a worktree at path `/tmp/wt-feature-x` different from the panel's workspace
- **THEN** the `feature-x` ref badge SHALL display a worktree-indicator icon and its tooltip SHALL include the path `/tmp/wt-feature-x`

#### Scenario: Current worktree marker

- **WHEN** the sidebar lists worktrees
- **THEN** the worktree whose path matches the panel's workspace directory SHALL be visually marked distinct from others

#### Scenario: Worktree path no longer exists

- **WHEN** a worktree entry returned by `git worktree list` points to a path that does not exist on disk
- **THEN** that entry SHALL be rendered in a stale state with a tooltip indicating the missing path

### Requirement: Empty and non-repository states

The system SHALL detect the repository state of the workspace directory before rendering the commit list and SHALL distinguish three initial states: (a) a valid git repository with commits, (b) a valid git repository with no commits (newly initialized), and (c) a path that is not a git repository.

#### Scenario: Newly initialized repo with no commits

- **WHEN** the workspace is a git repository but `git log` returns no commits
- **THEN** the main commit area SHALL render a localized empty-state message "No commits yet", the Uncommitted Changes virtual row SHALL still render if the working tree has any staged or untracked files, and the Refs sidebar SHALL still render (Branches section will show the default branch if created, Tags/Stashes/Worktrees sections show empty-state labels)

#### Scenario: Newly initialized repo with nothing staged

- **WHEN** the workspace is a newly initialized git repository with no commits and the working tree is empty
- **THEN** the panel SHALL render only the "No commits yet" empty-state and the empty Refs sidebar; no Uncommitted Changes row SHALL appear

#### Scenario: Path is not a git repository

- **WHEN** the workspace directory is not inside any git repository
- **THEN** the panel SHALL render a localized error state "Not a git repository" with the workspace path displayed, and SHALL NOT attempt to execute any `git log` or related command

### Requirement: Local and SSH workspace support

The system SHALL retrieve git data through two code paths: a local execution path invoking `git` in the workspace directory, and an SSH execution path issuing the same commands via SSH to the remote workspace host using the workspace's existing SSH destination, port, identity file, and options. Both paths SHALL produce the same in-memory snapshot structure.

#### Scenario: Local workspace loads graph

- **WHEN** the panel is bound to a local workspace directory containing a git repository
- **THEN** the panel SHALL execute `git` locally and render the commit graph

#### Scenario: SSH workspace loads graph

- **WHEN** the panel is bound to an SSH workspace with a valid SSH destination
- **THEN** the panel SHALL execute `git` commands over SSH in the remote workspace directory and render the commit graph

#### Scenario: Remote host lacks git — prompt user

- **WHEN** the SSH workspace's remote host does not have `git` available on `PATH`
- **THEN** the panel SHALL display a localized error state with the message `git not found on <host>` (where `<host>` is the SSH destination) and SHALL present a dialog offering two user-initiated actions: "Install git on <host>" and "Cancel"

#### Scenario: User declines install prompt

- **WHEN** the user selects "Cancel" in the "git not found" dialog
- **THEN** the panel SHALL remain in the error state and SHALL NOT execute any remote install command

#### Scenario: User confirms install — supported OS with sudo

- **WHEN** the user selects "Install git on <host>" and the remote OS is detected as one of `debian/ubuntu`, `rhel/fedora/centos`, `alpine`, or `macos (homebrew available)` and the SSH user has passwordless `sudo` (or the OS does not require it, e.g., macOS homebrew)
- **THEN** the panel SHALL execute the OS-appropriate install command (`apt-get install -y git`, `dnf install -y git`, `apk add git`, or `brew install git`) over SSH, display progress, and on success SHALL automatically refresh and load the graph

#### Scenario: User confirms install — sudo required but not available

- **WHEN** the user selects "Install git on <host>" and the remote install command requires `sudo` but the SSH user does not have passwordless sudo
- **THEN** the panel SHALL abort the install, display a localized error stating sudo is required, and SHALL show the exact command the user can run manually over SSH

#### Scenario: User confirms install — unknown OS

- **WHEN** the user selects "Install git on <host>" and the remote OS cannot be classified into a supported family (via `uname -s` + detecting `apt`/`dnf`/`apk`/`brew` on `PATH`)
- **THEN** the panel SHALL abort the install, display a localized error stating the remote OS is unsupported for auto-install, and SHALL show a generic suggestion to install `git` manually

#### Scenario: Install command fails

- **WHEN** the install command executes but exits non-zero
- **THEN** the panel SHALL display a localized error containing the command's stderr tail (last 10 lines) and SHALL remain in the error state

#### Scenario: Remote host git becomes available after error

- **WHEN** the panel is in the "git not found" error state and the user activates the refresh control
- **THEN** the panel SHALL re-probe `git` availability and, if present, SHALL load the graph normally

### Requirement: Read-only scope (no mutations)

The system SHALL NOT provide any UI control that mutates repository state. The panel SHALL NOT support checkout, branch creation, branch deletion, stash pop, stash apply, stash drop, worktree add, worktree remove, rebase, merge, cherry-pick, reset, or any other git command that modifies refs, working tree, or stash storage.

#### Scenario: No mutation controls exposed

- **WHEN** the user interacts with any part of the Git Graph panel UI
- **THEN** no interaction SHALL produce a git command that modifies repository state

### Requirement: Commit fetch window and load-more

The system SHALL expose a user-configurable commit fetch batch size in the app's Settings, named "Git Graph: Commits per load" (or equivalent localized label), with a default of 500 and an inclusive valid range of 100 to 2000. The effective batch size `N` SHALL be read from this setting at load time; values outside the range SHALL be clamped and a localized validation message SHALL be shown in Settings.

The system SHALL initially fetch at most `N` commits per load using topological ordering (`git log --topo-order ... -n N`). When the commit list has reached the fetch limit and more commits exist, the panel SHALL provide a "Load More" control that fetches the next `N` commits and appends them to the list. The system SHALL NOT expose alternative orderings (`--date-order`, `--author-date-order`) to the user.

#### Scenario: Initial load capped at configured batch size

- **WHEN** the repository has more commits than the configured batch size `N`
- **THEN** the initial render SHALL display `N` commits and expose a Load More control

#### Scenario: Load more appends next batch

- **WHEN** the user activates the Load More control
- **THEN** the next `N` commits (by `--skip` offset) SHALL be fetched and appended to the list

#### Scenario: Small repository

- **WHEN** the repository has fewer commits than `N`
- **THEN** the full history SHALL be loaded and no Load More control SHALL be displayed

#### Scenario: User changes batch size in Settings

- **WHEN** the user changes "Git Graph: Commits per load" in Settings while a Git Graph panel is open
- **THEN** the next refresh (manual or triggered) SHALL use the new value; already-loaded commits SHALL NOT be truncated until refresh

#### Scenario: Setting value out of range

- **WHEN** the user attempts to save a value less than 100 or greater than 2000 in Settings
- **THEN** Settings SHALL clamp the value to the nearest boundary and display a localized validation message indicating the valid range

### Requirement: Refresh triggers

The system SHALL refresh the graph data on exactly these triggers: explicit user activation of a refresh control, workspace switch to a panel's workspace, and the panel transitioning to focused state when the last successful refresh occurred more than 30 seconds ago. The system SHALL NOT observe filesystem events on the `.git` directory.

When a refresh is triggered while a previous refresh or Load More fetch is still in flight, the in-flight fetch SHALL be cancelled and its results SHALL be discarded; the refresh SHALL proceed as a full reload starting from the first 500 commits.

#### Scenario: Manual refresh

- **WHEN** the user activates the refresh control in the panel toolbar
- **THEN** the panel SHALL re-fetch the graph, uncommitted changes, stashes, tags, and worktrees

#### Scenario: Focus-triggered stale refresh

- **WHEN** the panel gains focus and its last successful refresh is older than 30 seconds
- **THEN** the panel SHALL refresh automatically

#### Scenario: Focus-triggered fresh refresh skipped

- **WHEN** the panel gains focus and its last successful refresh is within 30 seconds
- **THEN** the panel SHALL NOT trigger a refresh

#### Scenario: Refresh cancels in-flight Load More

- **WHEN** a Load More fetch is in progress and the user activates refresh (or a workspace-switch refresh fires)
- **THEN** the in-flight Load More SHALL be cancelled and its partial results SHALL NOT be applied to the snapshot; the refresh SHALL perform a full reload of the first 500 commits

### Requirement: Localized user-facing strings

Every user-facing string in the Git Graph panel (column headers, empty-state text, tooltips, button labels, toolbar labels, error messages, sidebar section titles) SHALL be declared via `String(localized:defaultValue:)` with a unique key and SHALL have translations in the project's supported languages (English, Japanese, Traditional Chinese).

#### Scenario: String uses localization key

- **WHEN** any user-facing string appears in the Git Graph panel UI
- **THEN** it SHALL be declared with a `gitGraph.`-prefixed localization key and SHALL resolve to a translation in the current app language

#### Scenario: Fallback to default value

- **WHEN** the app is running in a language for which a translation is missing
- **THEN** the string SHALL fall back to the default value supplied in `String(localized:defaultValue:)`

### Requirement: Off-main git execution

The system SHALL execute all git subprocess invocations on a background queue; the main actor SHALL only receive ready-to-render snapshot value types. No git subprocess invocation SHALL block the main thread.

#### Scenario: Initial load runs off main

- **WHEN** the panel performs its initial data load
- **THEN** the `git` subprocesses SHALL execute on a background queue and only the final snapshot SHALL be dispatched to the main actor

#### Scenario: Refresh does not block main thread

- **WHEN** a refresh is in progress
- **THEN** the main thread SHALL remain responsive and other panels' typing latency SHALL NOT be affected
