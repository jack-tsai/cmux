# Git Graph panel

Read-only Fork-style git graph for a workspace. Opens as a main-area panel
(same layout slot as terminal / browser / markdown), shares the workspace's
ghostty theme, and stays in lock-step with the underlying repo via explicit
user refresh + focus-staleness checks (no filesystem watching).

## Opening a panel

Three equivalent entry points:

| Entry | How |
|---|---|
| Keyboard | `⌘G` (configurable in **Settings → Shortcuts → Open Git Graph**) |
| Titlebar | Click the `chart.bar.doc.horizontal` button right of the `+` |
| Command Palette | `⌘⇧P` → `>git graph` → **New Tab (Git Graph)** |

Opening a panel while one already exists in the current workspace just focuses
the existing panel — there is only ever a single read-only view of a repo.

## Reading the graph

```
[⎘] ~/repo  [🌿 All branches ⌄]  [🔍 Search …  ✖]  [⟳]
│
○ Uncommitted Changes (3)                          now       —      —
│
●  main   origin/main       Most recent commit     12 min    Jack   a0cbc3a4
│
● \
│  ●  feature-x             Side branch tip        1 hr      Jack   e83b32f9
│ /
●    Trunk commit before the branch                2 hr      Jack   85c4c90d
```

- **Lane colors** come from ANSI palette entries 1–6 in the current ghostty
  theme; tokyonight / dracula / rose-pine / solarized will all look native.
- **Head marker**: the yellow-ringed dot marks where `HEAD` resolves.
  When the working tree is dirty the marker moves onto the Uncommitted
  Changes row — that's the real next-parent, not the previous HEAD commit.
- **Ref badges**:
  - blue = local branch (e.g. `main`)
  - gray = remote-tracking (e.g. `origin/main`)
  - purple = tag
  - yellow = `HEAD` synthetic ref
  - `⎘` icon on a local branch badge = that branch is checked out in
    another worktree; hover for the occupying path.

## Refs sidebar (⌘⌥B of the panel)

Four sections, each collapsible:

- **Branches** — local + remote-tracking; `origin/HEAD` alias is hidden.
- **Tags** — lightweight and annotated (annotated tags resolve to the
  target commit SHA).
- **Stashes** — `stash@{N} — subject`. Click once to pin the stash as a
  purple row at the top of the commit list (below Uncommitted Changes);
  click again to unpin. Clicking the pinned row expands its per-file
  numstat from `git stash show --numstat <ref>`.
- **Worktrees** — every worktree in the repo. The one hosting this
  panel gets a gold star; a worktree whose directory no longer exists
  on disk is greyed out with a "path no longer exists" tooltip.

Clicking a Branch / Tag entry scrolls the main commit list to that ref's
commit.

## Filtering

### Branch filter

Toolbar dropdown. Pick a branch to restrict the commit list to
`git log <branch>`; "All branches" returns to `git log --all`. When a
filter is active and `HEAD` is on a branch outside the filter, a yellow
banner appears above the list with the branch name and a **Show All**
action; the Uncommitted Changes row is also suppressed (it belongs to
`HEAD`'s branch, not the filtered one).

### Search

Search input accepts case-insensitive substring against commit message,
author name, or SHA prefix. Two modes, togglable via the icon next to
the clear button:

- **Highlight** (default) — every row still visible, matches get a
  yellow background and emphasised substring.
- **Filter** — only matching rows are rendered. The first match auto-
  scrolls into view on every query change.

## Opening a file in the terminal

Expand a commit (click its row) to see the changed-file list. Clicking a
file sends `git show <sha> -- <file>` to a terminal panel in the same
workspace (focused terminal first, then any terminal, creating a new
terminal if none exist). Paths are POSIX-quoted so filenames with
spaces / quotes work.

Commits with more than 500 files skip the per-file render and instead
offer an **Open in terminal** button that runs `git show <sha>` with no
path filter — preserves panel responsiveness on giant merge commits.

## Settings

| Default | Key | Range |
|---|---|---|
| `gitGraph.commitsPerLoad` | 500 | 100 – 2000 |

Adjust via `defaults write com.cmuxterm.app gitGraph.commitsPerLoad -int 1000`.
Changes take effect on the next refresh (pressing ⟳ or re-focusing the tab
more than 30 s after the last refresh).

## Refresh

Three refresh triggers, no filesystem watching:

1. Toolbar ⟳ button.
2. Workspace switch: SwiftUI remounts the panel → `.onAppear` →
   `panel.refreshIfStale()`.
3. Panel gains focus with `lastRefreshAt` more than 30 s old.

A refresh cancels any in-flight Load More via a monotonic generation
counter — late results get dropped.

## Non-goals

- **Mutation** — the panel never runs `git checkout / reset / rebase /
  cherry-pick / stash pop / worktree add`. Run those from a terminal.
- **Submodule traversal** — a panel shows one repo's graph; submodules
  need their own workspace + panel.
- **Diff viewer** — file rows dispatch to terminal instead; a diff
  viewer would duplicate the terminal's built-in `git show` / pager.

## Implementation notes (for editors of this panel)

- `GitGraphTheme` is stored as `@State` on `GitGraphPanelView` and
  recomputed only when `com.cmuxterm.themes.reload-config` fires — making
  it a computed property causes ColorSync to dominate the main thread
  during typing / scrolling because `GitGraphTheme.make` uses
  `NSColor.blended(withFraction:of:)`, which round-trips through
  ColorSync for every read.
- Every git subprocess runs on a background queue through
  `GitGraphProvider`. The view must not observe cross-panel
  `@Published` stores (typing-latency pitfall — see `CLAUDE.md`).
- Parser uses `\u{1E}` (Record Separator) to delimit commit records
  and `\u{00}` (NUL) as field separator inside each record for `git
  log --format`. **`git for-each-ref` uses a different format language
  that does not expand `%x00`** — branch / tag queries use Tab as the
  separator instead.
