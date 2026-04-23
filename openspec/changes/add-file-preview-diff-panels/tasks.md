# Tasks — Add File Preview & Diff Panels

## 1. Panel 骨架（兩個獨立 PanelType，共用 DiffProvider）

- [x] 1.1 在 `Sources/Panels/Panel.swift` 的 `PanelType` enum 加入 `case filePreview` 與 `case diff`（兩個獨立 case — 對應 decision「兩個獨立 PanelType，共用 DiffProvider」）。
- [x] 1.2 建立四個空 Swift 檔：`Sources/Panels/FilePreviewPanel.swift`、`Sources/Panels/FilePreviewPanelView.swift`、`Sources/Panels/DiffPanel.swift`、`Sources/Panels/DiffPanelView.swift`，各檔先放 `import SwiftUI` + 空 struct / `@MainActor ObservableObject` 骨架讓 compile 通過。
- [x] 1.3 建立 `Sources/DiffProvider.swift`（unified diff 跑 `git diff` + parse — 對應 decision「Unified diff parser 自己寫（不引入套件）」），v1.3 只放 value types (`DiffLine`, `DiffHunk`, `FileDiff`) 與 public 函式簽名。
- [x] 1.4 更新 `GhosttyTabs.xcodeproj/project.pbxproj`：為上面 5 個新檔加入 `PBXBuildFile`、`PBXFileReference`、`PBXGroup children`、`PBXSourcesBuildPhase`；使用 `DF000001..DF000501` / `DF000101..DF000601` 風格 hex UUID 避免衝突。
- [x] 1.5 補齊 `PanelType` 的 exhaustive switch：`Sources/Panels/PanelContentView.swift`（4 處）、`Sources/Workspace.swift`（約 10 處）、`Sources/ContentView.swift`（2 處）、`Sources/AppDelegate.swift`（3 處）、`Sources/GhosttyTerminalView.swift`（1 處）。每個新 case 可暫時 fallthrough 到 markdown-like 行為，後續由 1.6–3.x 再實作。
- [x] 1.6 在 `Sources/Workspace.swift` 新增 `newFilePreviewSurface(inPane:filePath:focus:)`、`openOrFocusFilePreviewSurface(filePath:)`、`newDiffSurface(inPane:mode:focus:)`、`openOrFocusDiffSurface(mode:)`，mirror 既有 `newMarkdownSurface`。`DiffMode` enum: `.workingCopyVsHead(path: String)` / `.commitVsParent(sha: String, path: String)`。
- [x] 1.7 在 `Sources/TabManager.swift` 加入 `openOrFocusFilePreview(filePath:)`、`openOrFocusDiff(mode:)` 兩個 facade 方法。
- [x] 1.8 全專案 compile（`CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -configuration Debug -derivedDataPath /tmp/cmux-fpd build`）通過，無 warning。

## 2. FilePreview 實作（開啟／不存在／二進制／大檔／theme）

- [x] 2.1 `FilePreviewPanel` 實作 **Open file as read-only preview tab**：於 `init` 從 workspace thread 載入檔案內容到 `@Published content: [String]`（行陣列），**Panel state is snapshot at open time**（不掛 file watcher）。
- [x] 2.2 `FilePreviewPanelView` 用 `ScrollView` + `LazyVStack` 顯示 monospace 行與左側右對齊行號 gutter，ForEach over row index。行號 gutter 寬度依總行數 `String(count).count` 動態決定。
- [x] 2.3 **Binary file detection**：載入時檢查前 8 KB 是否含 NUL byte；若有則 `@Published mode: .binary`，view 顯示 "Binary file" 訊息與「Open in Terminal」按鈕（dispatch `less <path>\n` 到 focused terminal）。
- [x] 2.4 **Missing file graceful handling**：ENOENT / 讀取失敗時 `@Published mode: .missing`，view 顯示 "File unavailable" 訊息卡，**不要** throw 或 `fatalError`（對應 decision「錯誤狀態顯示：與 Markdown panel 一致」）。
- [x] 2.5 **Large file truncation**：當 byte size > 2 MB 或行數 > 10000 時，只載入前 10000 行與前 2 MB（取先到達者），`@Published isTruncated: Bool = true`；view footer 顯示截斷訊息與「Open in Terminal」按鈕（對應 decision「Large file 處理：hard cap + footer 警告」）。
- [x] 2.6 **No write path exposed**：view 不提供任何 `TextEditor` / 可輸入控件；只用 `Text`，並且不回傳 keyboard focus 給 text editing handler。確認按任意 typing key 不會 mutate 檔案或螢幕內容。
- [x] 2.7 **Theme synchronization**：cache `theme` 為 `@State`，訂閱 `com.cmuxterm.themes.reload-config` notification 後 `.load()` 更新；foreground / background / gutter 色都走 theme。
- [x] 2.8 Tab title 設為 `URL(fileURLWithPath:).lastPathComponent`（對應 scenario "Tab title reflects filename"）。
- [x] 2.9 **Panel state is snapshot at open and on re-focus (FilePreviewPanel)**：`Workspace.openOrFocusFilePreview(filePath:)` 在 dedup hit 既有 tab 時，先對該 panel 呼叫 `reload()`（重讀檔），再把 focus 切過去。reload() 同 init 的 load pipeline（含 binary 偵測、截斷）。

## 3. DiffProvider + DiffPanel 實作

- [x] 3.1 `DiffProvider` 實作 `fetchDiff(mode:workingDirectory:)`：
  - Mode `.workingCopyVsHead(path)` → 跑 `git diff HEAD -- <path>`（對應 decision「Diff base：working copy vs HEAD（不區分 staged）」）。
  - Mode `.commitVsParent(sha, path)` → 跑 `git show --format= <sha> -- <path>` 或等效 `git diff <sha>^ <sha> -- <path>`。
  - 只在本機跑（`Process` / `/usr/bin/git`）。SSH 不支援。
- [x] 3.2 自寫 unified diff parser：把原始輸出切成 `FileDiff` → `[DiffHunk]` → `[DiffLine]`，標記 `+` / `-` / context / hunk-header / noNewlineAtEof。偵測 `Binary files ... differ`，輸出 `FileDiff.kind == .binary`（對應 decision「Unified diff parser 自己寫（不引入套件）」）。
- [x] 3.3 `DiffProviderTests.swift` 涵蓋：純 added、純 removed、mixed、binary、no newline at eof、empty output、多 hunk。
- [x] 3.4 `DiffPanel` 實作 **Read-only unified diff tab**：`init(mode:)` 呼叫 provider、存成 `@Published fileDiff: FileDiff?`。**Snapshot at open time**（不 watch）。加 `refresh()` 方法手動重新跑 provider。
- [x] 3.5 `DiffPanelView` 實作 **Diff line type rendering**：
  - `+` 行：`theme.success` 前景，淡色底（`theme.success.opacity(0.08)`）。
  - `-` 行：`theme.danger` 前景，淡色底（`theme.danger.opacity(0.08)`）。
  - Hunk header：monospace + 淡藍灰、顯著區分。
  - Context 行：`theme.foreground`。
- [x] 3.6 **Diff scope label**：toolbar 左上顯示 mode 對應文字："Working copy vs HEAD" 或 "<shortSha> vs parent"（走 Localizable）。
- [x] 3.7 **No-change empty state**：當 `fileDiff == nil` 或 `hunks.isEmpty` 時顯示 "No changes" 空狀態卡，不顯示空 rows。
- [x] 3.8 **Binary diff handling**：`FileDiff.kind == .binary` 時顯示 "Binary file changed" 提示，不嘗試 render hunks。
- [x] 3.9 **Theme synchronization**：同 2.7，cache theme、訂閱 reload-config。
- [x] 3.10 **Read-only focus behavior**：確認 typing key 在 DiffPanel focus 時不會 mutate — 用 `Text` 顯示、不接 `TextEditor`。
- [x] 3.11 **SSH workspace fallback**：`Workspace.newDiffSurface` 在 `remoteConfiguration != nil` 時直接 return `nil`（不開 tab）；呼叫端 early-return 並不顯示錯誤訊息。此處即是「SSH 降級：fallback 到 no-op」decision 的實作落點。
- [x] 3.12 **Merge commit diff uses first parent only**：`commit-vs-parent` 模式遇到 `commit.parents.count >= 2` 時，只對第一個 parent (`commit.parents[0]` 或等效 `<sha>^1`) 做 diff；不使用 `-c` / `--cc`。Toolbar scope label 顯示 `<shortSha> vs parent <parentShortSha>`。
- [x] 3.13 **Rename handling uses new-path only**：DiffProvider 在 `workingCopyVsHEAD` 模式跑 `git diff HEAD -- <new-path>`，**不加 `-M`**；old path 不傳。加一個 DiffProviderTest fixture：檔案被 rename 後，parser 應該收到 delete+add 的合併輸出並正確分段。
- [x] 3.14 **Snapshot at open and on re-focus (DiffPanel)**：`Workspace.openOrFocusDiff(mode:)` 在 dedup hit 既有 tab 時，除了切 focus 以外還要呼叫那個 DiffPanel 的 `refresh()`，讓 git 指令重跑一次。手動 refresh 行為維持不變。

## 4. File Explorer Cmd+Click 派送（純函式 + view hook）

- [x] 4.1 建立 `Sources/FileOpenDispatcher.swift`（對應 decision「File Explorer 的派送函式：獨立純函式，容易測試」）：
  - public `decide(path: String, workspace: Workspace) -> Decision`
  - `enum Decision { case markdown(path: String); case diff(path: String); case preview(path: String); case unsupported }`
- [x] 4.2 **Central file-open decision function** 規則實作：
  - Workspace `remoteConfiguration != nil` → `.unsupported`。
  - Path 副檔名是 `.md` / `.markdown`（case insensitive） → `.markdown`。
  - 否則跑 `git status --porcelain -- <path>`（對應 decision「Dirty 偵測：lazy per-click」）：
    - 回應含 `M` / `A` / `R` 狀態 → `.diff`。
    - `??`（untracked） → `.preview`（對應 spec scenario "Untracked file"）。
    - 空回應 → `.preview`。
    - `git status` 不可用（not a repo / git missing） → `.preview`（非 markdown）或 `.markdown`（markdown）。
- [x] 4.3 `FileOpenDispatchTests.swift` 覆蓋：markdown 副檔名、clean 檔、modified 檔、untracked 檔、not-in-repo、SSH workspace 的 6 個 scenario（對應 spec "Central file-open decision function" 的 scenarios）。
- [x] 4.4 **File Explorer 觸發方式：Cmd+Click** — 在 `Sources/FileExplorerView.swift` 加 `NSOutlineView` 的 `mouseDown` interception 或 `NSClickGestureRecognizer` + `modifierFlags.contains(.command)` 偵測，呼叫 `FileOpenDispatcher.decide(...)` 再 dispatch 給 `TabManager.openOrFocusXxx`。
- [x] 4.5 **File Explorer Cmd+Click routes through dispatch**：接上 `.markdown` → `openOrFocusMarkdownSurface`、`.diff` → `openOrFocusDiff(mode: .workingCopyVsHead(path))`、`.preview` → `openOrFocusFilePreview(filePath:)`、`.unsupported` → no-op。
- [x] 4.6 **Non-interference with plain left-click**：確認未按 Cmd 的 click 仍走既有 selection / expand-collapse；dispatch 路徑只在 modifierFlags 含 `.command` 時啟動。
- [x] 4.7 **Cmd+Click on directory row**：directory 的 row 在 dispatcher 裡 early-return `.unsupported`（或 view 層先判斷 `isDirectory` 直接跳過），確保不開 panel。
- [x] 4.8 **Symlinks are resolved before dispatch**：`FileOpenDispatcher.decide` 第一步若 `FileManager.default.destinationOfSymbolicLink(atPath:)` 成功，就把路徑換成 canonical target（用 `URL.resolvingSymlinksInPath()`）再繼續 extension 判斷與 `git status` 查詢。Target 不存在 → return `.unsupported`。測試加 2 個 fixture：symlink→md、broken symlink。
- [x] 4.9 **Duplicate open focuses existing tab**：`Workspace.openOrFocusFilePreview` / `openOrFocusDiff` / `openOrFocusMarkdownSurface` 都要 dedup：比對 panel-specific identity（preview: absolute path；diff.workingCopyVsHEAD: ("wc", path)；diff.commitVsParent: ("cvp", sha, path)；markdown: absolute path）。找到既有 tab 就切 focus 並呼叫該 panel 的 `reload()` / `refresh()`；沒找到才新開。寫對應測試：`WorkspaceTabDedupTests`。

## 5. Git Graph fileRow 切換為 Diff Panel

- [x] 5.1 **Git Graph file row dispatches to diff panel**：修改 `Sources/Panels/GitGraphPanelView.swift` 的 `fileRow(_:sha:)`，把 `.onTapGesture { dispatchGitShow(...) }` 換成 `.onTapGesture { tabManager.openOrFocusDiff(mode: .commitVsParent(sha: sha, path: file.path)) }`。
- [ ] 5.2 刪除 `GitGraphPanelView` 中不再使用的 `dispatchGitShow(sha:filePath:)` 函式。（未刪除 — `tooManyFilesNotice` 的「Open in terminal」按鈕仍呼叫 `dispatchGitShow(sha:filePath:nil)` 作為整個 commit 的 fallback；若要完全刪除需一起移除該按鈕，屬行為變更，留給後續 change。）
- [x] 5.3 `fileRow` tooltip 的 i18n key 改成 `gitGraph.fileRow.tooltip.diff`（新值 "Click to view diff in a new tab"），舊 key 保留但不用。

## 6. i18n、build 與驗證

- [x] 6.1 在 `Resources/Localizable.xcstrings` 新增以下 key 的 en / ja / zh-Hant 翻譯：`filePreview.binary`, `filePreview.missing`, `filePreview.truncated`, `filePreview.openInTerminal`, `diff.scope.workingCopyVsHEAD`, `diff.scope.commitVsParent` (帶 `%@`), `diff.empty.noChanges`, `diff.binary.changed`, `diff.refresh`, `gitGraph.fileRow.tooltip.diff`。
- [ ] 6.2 `./scripts/reload.sh --tag fpd` 成功 build 出 Debug app，手動驗 Cmd+Click 流程（markdown / dirty / clean / untracked 四條路徑）。（待使用者手動執行 reload.sh 並實測。已透過 `CMUX_SKIP_ZIG_BUILD=1 xcodebuild ... build` 驗證 compile 通過。）
- [ ] 6.3 確認 Git Graph commit 展開後點 fileRow 會開 DiffPanel tab，terminal buffer **沒有** 再被寫入 `git show` 指令。（待手動驗證；程式上 `fileRow` 已改為呼叫 `tabManager.openOrFocusDiff(...)`，不再呼叫 `dispatchGitShow`。）
- [ ] 6.4 `xcodebuild -scheme cmux-unit test` 在 CI 的 `DiffProviderTests`、`FileOpenDispatchTests` 通過。（本地僅做 build 驗證；依 project policy 不在本地跑 tests，留待 CI 執行。）
- [ ] 6.5 對 DiffPanel 與 FilePreviewPanel 在 typing-heavy 場景做一次 `sample(1)`，確認未引入新的 main-thread 熱點（對應 CLAUDE.md 的 "typing-latency-sensitive paths" 守則）。（待手動 profile；panel init 已將 git subprocess 放到 background queue，符合 typing-latency 守則。）
