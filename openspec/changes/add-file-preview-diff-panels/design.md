## Context

cmux 的 workspace 已有一套 **Panel** 抽象：每個 tab 的視覺區域對應一個 `PanelType`（`terminal`、`browser`、`markdown`、`gitGraph`）。Panel 具體由一個 `ObservableObject`（狀態、lifecycle）加一個 SwiftUI View 組成；由 `Workspace` 負責 surface 建立 / 切換 focus / 關閉，由 `PanelContentView` 根據 `PanelType` 決定要 render 哪個 view。

現有 `MarkdownPanel` 是最接近這個 change 要做的事的藍本 — 它已經示範「開檔案內容在一個獨立 split tab、與 terminal 並存、read-only」的流程（包含 file load、not-found 狀態、theme 套用、tab 標題設定）。Git Graph panel 也最近才導入，它在 commit 展開區有一個 fileRow 列表，目前點擊會 dispatch `git show <sha> -- <path>\n` 到 focused terminal — 這是一個 workaround，等於用 terminal scroll buffer 當 diff 顯示區，使用者 feedback 是「佔 scroll、跟 terminal work 混在一起」。

右側 File Explorer 則是從零 hook 起 — 目前 sidebar 完全沒有 click-to-open 的行為（Cmd+Click / double-click 都是 no-op），只靠 TerminalController socket 命令 `split markdown <file>` 觸發 markdown split。

這個 change 要做的是：
1. 把「開檔案 split tab」的能力延伸到任意檔案（`FilePreviewPanel`）與 diff（`DiffPanel`）。
2. 在 File Explorer 加 Cmd+Click 的派送入口。
3. 把 Git Graph 的 fileRow dispatch 換成開 `DiffPanel`。

約束：
- **效能優先**：cmux 是 terminal-focused app，其他 panel 的 re-render 絕對不能干擾打字 latency（這在 Git Graph 做完後已經踩過 ColorSync 的雷）。
- **i18n**：所有 user-facing 字串都必須走 `Localizable.xcstrings`。
- **Ad-hoc build**：fork 無 Apple Developer 憑證，因此所有新檔案必須能 CODE_SIGNING_ALLOWED=NO + 後置 codesign 過。
- **Panel exhaustive switch**：`PanelType` enum 在 app 內 ~8 個檔案有 exhaustive switch — 每加一個 case，全部要補。

## Goals / Non-Goals

**Goals:**

- 任意檔案 Cmd+Click 可在 split tab 開啟唯讀預覽。
- 有異動（modified / staged / untracked-but-tracked）的檔案，Cmd+Click 直接開 unified diff（working copy vs HEAD）。
- Git Graph commit fileRow 點擊改為開 `DiffPanel`（sha vs parent），取代 terminal dispatch。
- 兩個新 panel 都享用現有 theme 同步（`com.cmuxterm.themes.reload-config` notification）與 monospace 設定。
- 加入最小可行的測試：`DiffProvider` parser、檔案派送規則。

**Non-Goals:**

- Syntax highlighting（純文字 + monospace v1）。
- 可編輯 / 儲存。
- Side-by-side diff（只做 unified）。
- 全域 dirty watcher（File Explorer 每個檔案不顯示 dirty indicator）。
- SSH 遠端 workspace 的 preview/diff。
- 自動 refresh（file watcher）— open 時 snapshot，要更新得手動 reload tab。
- 分頁 / pagination 載入大檔。
- 區分 staged 與 unstaged（統一用 `git diff HEAD`）。

## Decisions

### 兩個獨立 PanelType，共用 DiffProvider

選 **`PanelType.filePreview` + `PanelType.diff` 兩個新 enum case** 而非一個通用 `file` case 帶 mode flag。

- 理由：Panel 的 surface lifecycle 跟 tab 標題跟命令 palette 都綁 `PanelType`；一個 tab 的身份是「預覽 vs diff」—這是使用者認知分類，而非面板內部 mode。
- 另一個 tab 如果是 diff，使用者期望的互動（複製 hunk、hunk 跳轉）跟 preview 是不同的；共用 view 只是意外的複用，會在之後加功能時反覆需要 `if mode == ...`。
- 交換成本：兩個 enum case 要在 ~8 個 exhaustive switch 多補一次 case — 是一次性成本，小於長期 if 分支成本。

`DiffProvider`（新檔）則共用：它只是「跑 `git diff` + parse unified diff」，不管上游是 File Explorer 還是 Git Graph。

### Unified diff parser 自己寫（不引入套件）

cmux 沒有其他 diff 需求，且 `git diff` 的 unified format 規則穩定、夠簡單（`@@ -a,b +c,d @@` hunk header、`+`/`-`/` ` 行前綴、`\ No newline at end of file`）。

- 選：自己寫約 100 行的 parser，輸出 `DiffHunk` / `DiffLine` value 結構。
- 否決：引入 `SwiftGit2` / 其他 diff lib — 新增 binary / build 依賴不划算。

### Dirty 偵測：lazy per-click

選 **Cmd+Click 當下跑一次 `git status --porcelain -- <path>`**（~10ms）。

- 理由：FileExplorer 的即時 dirty indicator 不在 goal 內；per-click 成本足夠低、語義清晰（「當下」的狀態）。
- 否決：訂閱 GitStatusProvider 的 dirty set — 增加跨 panel 狀態依賴與 race condition 表面積，違反本次 change 的 scope。

### File Explorer 觸發方式：Cmd+Click

選 **Cmd+Click**（user 明確要求，與現有 markdown Cmd+Click pattern 一致）。

- Double-click 不做（v1）。若未來要 double-click open，再加 OutlineView delegate `doubleAction`。
- 單擊保留給選取（outline 的預設行為）。

### Large file 處理：hard cap + footer 警告

選 **硬切 2 MB / 10000 行 + footer 訊息**。

- 理由：SwiftUI 的 `LazyVStack` 在 > 50000 行文字時卷軸會明顯卡；2 MB/10000 行是偏保守但一致的截斷。
- 否決：完整載入後靠 LazyVStack lazy render — 初次 layout cost 與 ScrollView 估高在巨大檔會 trigger pathological path；不值得為了邊際狀況做。
- 截斷後仍保留捲動、仍 read-only；尾端加行 `String(localized: "filePreview.truncated")` 提示檔案被截斷，並提供 `Open in Terminal`（dispatch `less <path>`）備援。

### Diff base：working copy vs HEAD（不區分 staged）

選 **`git diff HEAD -- <path>`**。

- 理由：使用者最常問「我動過哪些」就是這句。區分 staged/unstaged 會把 diff panel 變兩個 view 或帶 mode toggle — 違反「v1 越小越好」。
- 未來延伸：可在 DiffPanel toolbar 加一個 segmented control `[HEAD | Index | Unstaged]`，但 v1 不做。

### File Explorer 的派送函式：獨立純函式，容易測試

把「給定 path → 決定開哪個 panel type」抽成一個純函式 `FileOpenDispatcher.decide(path:workspace:) -> Decision`，而不是直接在 OutlineView delegate 塞分支邏輯。

- 理由：dispatch 規則會隨時間長（未來加 notebook / image preview），把它放在 view code 裡會反覆難測。
- 純函式簽名 + 測試（dirty fixture / extension fixture / not-in-repo fixture）是小投資、大回報。

### 錯誤狀態顯示：與 Markdown panel 一致

- 檔不存在 → 顯示 "File unavailable" 樣式卡片。
- 二進制 → 顯示 "Binary file" 提示 + Open in Terminal 按鈕。
- Diff 無變更 → 顯示 "No changes" 空狀態。
- Git 不可用 → 顯示 "git not found" 靜態訊息（已是 GitGraphProvider 定義過的 `GitGraphRepoState.gitUnavailable` 等效）。

### SSH 降級：fallback 到 no-op

當 `workspace.remoteConfiguration != nil`，Cmd+Click 的派送直接回傳 `.unsupported` decision；UI 層選擇 *不做任何事*（避免誤以為 broken）。未來延伸到 SSH 走 `GitGraphProvider.runGitAnywhere` 的 SSH 分支即可，今天不做。

## Risks / Trade-offs

- [Risk] PanelType exhaustive switch 漏補一個點 → Swift compile error，找得到但煩 — Mitigation：compile 會全抓、沒有 runtime 漏洞；CI build 就是守門員。
- [Risk] Large-file 截斷邊界在日文 / 中文檔案行長差異大可能卡觸覺上奇怪的位置 — Mitigation：先切 10000 行為主（行數比 byte 直覺），實測後視情況調。
- [Risk] 未區分 staged/unstaged 使 diff 輸出跟使用者心智模型略有落差 — Mitigation：在 DiffPanel toolbar 顯示「working copy vs HEAD」的 label，明確告知範圍。
- [Risk] 每次 Cmd+Click 跑 `git status --porcelain` 累積起來慢 — Mitigation：單檔 scope（`-- <path>`）成本固定 < 20 ms；若實測發現問題可在 FileExplorer Panel-scope cache 60 s（屬後續優化）。
- [Risk] 新增 5 個 Swift source 檔 + pbxproj 手動編輯 → merge conflict 易發 — Mitigation：使用過去 GitGraph 同樣的 `CAFE*` 風格 hex UUID，避免與既有衝突；集中在同一 PR 一次進來。
- [Trade-off] 自寫 unified diff parser 有 corner case 風險（`\ No newline at end of file`、rename 標頭、binary） — Mitigation：parser 有 DiffProviderTests 覆蓋這些 edge cases；binary 檔 git 會回 `Binary files ... differ`，parser 直接輸出特殊 `.binary` 型別不嘗試 line-level。

## Open Questions

- **`git diff HEAD -- <path>` 對 untracked 檔行為**：untracked 檔不會出現在 `git diff HEAD`，只會出現在 `git status --porcelain` 的 `??`。派送函式遇到 untracked 檔時，要開 diff 還是 preview？**決定：把 untracked 檔開 preview**（沒有 HEAD 對照 → 沒 diff 意義），在 spec / task 裡明確寫明。
