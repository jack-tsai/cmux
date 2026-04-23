# Screenshot Terminal Paste

## ADDED Requirements

### Requirement: pasteFileURL helper on TerminalImageTransfer

`TerminalImageTransfer` SHALL expose a new `@MainActor` static entry point:

```
static func pasteFileURL(
    _ fileURL: URL,
    to workspace: Workspace,
    tabManager: TabManager
) throws
```

The helper SHALL synthesize a temporary `NSPasteboard` instance, write the file URL (as `public.file-url`) and image bytes (as the UTI matching the file extension) onto it, and invoke the existing `prepare(...)` → `materializedFileURLs(...)` pipeline. The result SHALL be dispatched to the currently focused terminal surface within `workspace`.

#### Scenario: Pasting a local PNG with a focused local terminal

- **WHEN** the caller invokes `pasteFileURL(URL(fileURLWithPath: "/Users/x/a.png"), to: workspace, tabManager: tm)` for a local workspace whose focused panel is a terminal
- **THEN** the focused terminal SHALL receive the same text reference it would have received if the user pasted `a.png` from Finder via ⌘V
- **AND** no modal dialog SHALL appear

#### Scenario: Pasting a PNG to an SSH workspace

- **WHEN** the caller invokes `pasteFileURL` for a workspace whose `remoteConfiguration != nil`
- **THEN** the helper SHALL delegate to the existing SSH upload path in `TerminalImageTransfer`
- **AND** the remote terminal SHALL receive a text reference to the uploaded remote path

### Requirement: Focused terminal resolution with fallback

When `pasteFileURL` is called, the target terminal SHALL be resolved in this order:

1. The focused terminal panel of the given workspace, if any and if it is a `TerminalPanel`.
2. The last-focused terminal panel of the given workspace (tracked by `workspace.lastFocusedTerminalPanelId`).
3. If neither exists, the helper SHALL throw `TerminalImageTransferError.noFocusedTerminal` without mutating any state.

#### Scenario: Workspace has no focused panel

- **WHEN** `workspace.focusedPanelId` is nil and `lastFocusedTerminalPanelId` is nil
- **THEN** `pasteFileURL` SHALL throw `noFocusedTerminal`
- **AND** no pasteboard SHALL be written, no upload SHALL start

#### Scenario: Focused panel is not a terminal

- **WHEN** `workspace.focusedPanelId` points to a BrowserPanel but `lastFocusedTerminalPanelId` points to a valid TerminalPanel
- **THEN** the helper SHALL target the `lastFocusedTerminalPanelId` terminal

### Requirement: Workspace tracks last-focused terminal panel

`Workspace` SHALL maintain a `lastFocusedTerminalPanelId: UUID?` property that updates whenever a `TerminalPanel` gains focus. When that terminal is closed, the property SHALL reset to the next-most-recently-focused terminal (if any) or nil.

#### Scenario: Multiple terminals, focus switched then closed

- **WHEN** the workspace has three terminal panels T1, T2, T3; the user focuses T1 then T2, then closes T2
- **THEN** `lastFocusedTerminalPanelId` SHALL equal T1's id
- **AND** not nil, not T3's id

### Requirement: Drag-out uses same pipeline

The drag-out code path from `ScreenshotPanelView` SHALL route drops into terminal surfaces through the existing terminal drop handler, which uses the same `TerminalImageTransfer` APIs as ⌘V pasting. No parallel drop implementation SHALL be created.

#### Scenario: User drags a grid cell onto a local terminal surface

- **WHEN** the user drags a gallery cell and drops it on a local terminal surface
- **THEN** the resulting text insertion in that terminal SHALL be identical to what the user would get by double-clicking the same cell

### Requirement: Context-menu Copy writes both fileURL and image

The "Copy to pasteboard" action in the gallery context menu SHALL clear `NSPasteboard.general` and write both a `public.file-url` entry and the decoded image bytes (under the UTI matching the source file's extension). Callers downstream — e.g. Finder, Preview, other apps — SHALL be able to paste either representation.

#### Scenario: Copy then paste into Finder

- **WHEN** the user right-clicks a gallery entry and selects "Copy to pasteboard", then switches to Finder and presses ⌘V
- **THEN** Finder SHALL paste the file (Finder's file-URL flavour handler)

#### Scenario: Copy then paste into Preview or another image consumer

- **WHEN** the user copies a gallery entry, then in Preview selects "New from Clipboard"
- **THEN** Preview SHALL create a new document containing the image
