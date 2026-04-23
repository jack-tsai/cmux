# Add File Preview & Diff Panels

## Why

目前使用者在 cmux 的 workspace 裡要看一個檔案的內容，只能靠 terminal 下指令（`cat`、`less`、`git diff`）；在 Git Graph panel 展開 commit 的檔案列表時，點檔案會把 `git show <sha> -- <path>` dispatch 到 terminal，不是讓檔案內容直接出現在一個獨立、可留存、可切換的 tab。Right sidebar 的 File Explorer 雖已能被看到，但雙擊 / Cmd+Click 沒有任何「打開檔案」的行為，異動檔案（dirty files）也沒有視覺化的方式直接看 diff。

使用者實際會用到的情境：
1. 瀏覽 commit 時想快速看某個檔案在那個 commit 的樣貌 / 跟父 commit 的 diff，不希望佔用 terminal scroll buffer。
2. 在工作中途想對照 working copy 和 HEAD 的差異（「我改了什麼還沒 commit」），而不要切到別的 app（Fork / Sourcetree）。
3. 打開一份純文字 / config / JSON 做 reference 閱讀，不需要 edit，只要 read-only 可捲動。

現有 MarkdownPanel 已經驗證「split view 開檔案」是可行且符合 cmux 風格的模式（read-only、可多開 tab、跟 terminal 並存），但它只處理 markdown。將此模式延伸到一般檔案預覽與 diff 顯示是自然的一步，且可以取代 Git Graph 目前 dispatch `git show` 到 terminal 的 workaround。

## What Changes

- 新增 `PanelType.filePreview`：唯讀檔案預覽面板。顯示 plain text 內容、行號、offer binary 偵測 fallback。使用 monospace；不做 syntax highlighting（v1）。
- 新增 `PanelType.diff`：唯讀 unified diff 面板。顯示 `+ / -` 行、hunk header、file header。只做 **working copy vs HEAD** 比對（File Explorer 入口）與 **sha vs parent** 比對（Git Graph 入口）。
- **File Explorer Cmd+Click 派送規則**：
  - `.md` / `.markdown` → 沿用現有 `newMarkdownSurface`
  - 檔案在 git working tree 有異動（modified / staged / untracked 但 tracked） → 開 `DiffPanel`（working copy vs HEAD）
  - 其他 → 開 `FilePreviewPanel`
- **Git Graph commit 展開區 fileRow 點擊**：改為開啟 `DiffPanel`（sha vs parent），取代現在的 dispatch `git show` 到 terminal 的行為。
- **Dirty 偵測**：Cmd+Click 當下 lazily 跑一次 `git status --porcelain -- <path>`；不維護 FileExplorer 的全域 dirty watcher。
- **SSH workspace**：v1 僅支援本機 workspace。遠端 workspace 的 Cmd+Click 會 fall back 到既有行為（no-op 或現況），不會 crash。
- i18n：新增 ~10 個 en/ja/zh-Hant 字串（標題、binary notice、not-found、no-changes 等）。

## Non-Goals

- **Syntax highlighting**：v1 純文字 + monospace；語法上色延後。
- **Editable preview**：兩個 panel 都只讀；編輯請另開 terminal 用 `$EDITOR`。
- **Side-by-side diff**：v1 只做 unified diff；split view 延後。
- **全域 dirty 指示器**：File Explorer 每個檔案旁邊 **不** 加 dirty icon；diff 是 Cmd+Click 當下 on-demand 決定的。
- **SSH 遠端檔案**：v1 不支援；第一次開遠端 workspace 的 Cmd+Click 直接沿用現況（目前就是無動作或 fall back）。
- **Staged / unstaged 分離**：v1 不區分，直接 `git diff HEAD -- <path>`（working tree vs HEAD），涵蓋兩者合起來的變更。
- **Large-file protection**：> 2 MB 的檔案開 preview 時只載入前 10000 行 + footer 提示（避免把 UI 卡住），但不另做 pagination / 分頁載入。
- **File watcher / auto-refresh**：open 當下 snapshot 一次；手動按「Refresh」或重開 tab 才更新（與 MarkdownPanel 一致）。

## Capabilities

### New Capabilities

- `file-preview-panel`: Read-only 檔案內容預覽面板。支援 plain text、monospace、行號、binary 偵測、大檔截斷，以獨立 tab 開啟。
- `diff-panel`: Read-only unified diff 顯示面板。可在兩種模式之一運作：*working-copy-vs-HEAD* 或 *commit-vs-parent*，共用同一個渲染管線。
- `file-open-dispatch`: File Explorer / Git Graph 點擊檔案 → 依檔案類型與 git 狀態派送到正確 panel（markdown / diff / preview）的路由邏輯。

### Modified Capabilities

(none — 現有 Git Graph 功能目前還未列 spec，Git Graph 的 fileRow 行為改變屬於這個 change 的新 capability `file-open-dispatch` 的一部分。)

## Impact

- **Affected specs**:
  - 新增 `specs/file-preview-panel/spec.md`
  - 新增 `specs/diff-panel/spec.md`
  - 新增 `specs/file-open-dispatch/spec.md`

- **Affected code** (預計):
  - 新增 `Sources/Panels/FilePreviewPanel.swift`、`Sources/Panels/FilePreviewPanelView.swift`
  - 新增 `Sources/Panels/DiffPanel.swift`、`Sources/Panels/DiffPanelView.swift`
  - 新增 `Sources/DiffProvider.swift`（跑 `git diff`、parse unified diff）
  - 修改 `Sources/Panels/Panel.swift` — 加入 `.filePreview` 跟 `.diff` 兩個 case
  - 修改 `Sources/Panels/PanelContentView.swift` — 接上新 panel type 的 rendering（4 個 switch）
  - 修改 `Sources/Workspace.swift` — 新增 `newFilePreviewSurface(...)`、`newDiffSurface(...)`、`openOrFocusFilePreview(...)`、`openOrFocusDiff(...)`，並更新約 10 處 `PanelType` exhaustive switch
  - 修改 `Sources/TabManager.swift` — 封裝 open helpers
  - 修改 `Sources/ContentView.swift` — 2 處 switch 補 case
  - 修改 `Sources/AppDelegate.swift` — 3 處 switch 補 case
  - 修改 `Sources/GhosttyTerminalView.swift` — 1 處 switch 補 case
  - 修改 `Sources/FileExplorerView.swift`（右 sidebar）— 加入 Cmd+Click / double-click handler，呼叫派送函式
  - 修改 `Sources/Panels/GitGraphPanelView.swift` — `fileRow` 點擊改呼叫 diff panel 開啟，移除 `dispatchGitShow`
  - 修改 `GhosttyTabs.xcodeproj/project.pbxproj` — 新增 4 個 .swift + 1 個 provider 的 PBXBuildFile / PBXFileReference / PBXGroup / PBXSourcesBuildPhase
  - 修改 `Resources/Localizable.xcstrings` — 新增 ~10 組 en/ja/zh-Hant 字串
  - 新增測試：`cmuxTests/DiffProviderTests.swift`（unified diff parser）、`cmuxTests/FileOpenDispatchTests.swift`（檔案類型 + dirty 判斷 → panel 決策邏輯）

- **Dependencies**：無新增套件。沿用 Foundation `Process`、既有 `GitGraphProvider.runGitAnywhere` 的本機路徑分支。
