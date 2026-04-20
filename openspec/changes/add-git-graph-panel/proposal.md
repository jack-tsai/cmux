## Why

cmux 使用者在 workspace 裡進行多 branch / 多 worktree 的 AI agent 平行開發時，需要快速掌握目前 repo 的 branch 拓撲、HEAD 位置、uncommitted changes、stash 堆疊與 worktree 佔用狀況。目前只能切出終端跑 `git log --graph` 或另開 Fork / GitKraken 等外部工具，脫離 cmux 主畫面，打斷工作流。

主畫面需要一個常駐、唯讀、視覺化的 git graph panel，讓使用者在 cmux 內一眼看懂 repo 狀態並定位當前 working context。

## What Changes

- 新增 `PanelType.gitGraph` 作為主畫面 panel 第四種型別（現有為 `terminal` / `browser` / `markdown`），可開在 tab 或 split，與其他 panel 共用 workspace lifecycle
- 新增資料層 `GitGraphProvider`（仿現有 `GitStatusProvider`），支援 local 與 SSH 兩種 workspace，以 `git log --format=<custom> --all -n 500` 取得 commit graph 結構化資料
- 新增 Uncommitted Changes 虛擬 row 置頂，資料來源沿用現有 `GitStatusProvider`
- 新增左側 Refs sidebar 列出 `▾ Branches`、`▾ Tags`、`▾ Stashes`、`▾ Worktrees`，可收合
- 新增 branch 單選 filter：選一個 branch 後只顯示 `git log <branch>` 可達的 commits
- 新增 search 文字輸入，對 commit message / author / SHA 做 fuzzy 高亮
- 新增展開式 commit detail row：點 commit 行列內展開，顯示完整 SHA、parent SHA、author、committer、date、完整 message、檔案樹與每檔 `+N / -M` numstat（來源 `git show --numstat`）
- 新增 ref badge 標示 worktree 佔用：若某 branch 已被其他 worktree checkout，在 badge 加上 `⎘` 圖示並 tooltip 顯示 worktree 路徑
- 新增唯讀原則：**不支援任何 mutation**（checkout、stash pop、worktree add、rebase、cherry-pick 等一律不做）；mutation 由使用者在 terminal panel 自行執行
- 新增 panel 開啟 UX：與新增 terminal panel 共用現有入口（tab `+` 按鈕 / 快捷鍵 / 選單），在型別選擇器加入 Git Graph 選項
- 新增快捷鍵：於 `KeyboardShortcutSettings` 註冊可自訂的「Open Git Graph Panel」項目
- 新增中英日三語系文字：所有 UI 字串寫入 `Resources/Localizable.xcstrings`

## Non-Goals

- **不支援任何 git mutation**：checkout / branch create / stash pop / worktree add / rebase / merge / cherry-pick / reset — 一律由使用者在 terminal 執行
- **例外**：SSH 遠端缺 `git` 時可在使用者明確確認下安裝 git（屬環境修復，不是 repo mutation），僅支援已分類的 OS 與 passwordless sudo 情境
- **不取代 lazygit / tig 等終端機 git 工具**：僅做視覺化查看，不做完整 git client
- **不支援一個 panel 顯示多個 repo**：一個 panel 綁定一個 workspace 的 git repo；多 repo 需多開 panel
- **不支援 submodule 遞迴 graph**：submodule 的 graph 由該 submodule 所在 workspace 的 panel 顯示
- **不支援 diff 內容預覽**：檔案樹只顯示 `+N / -M` numstat，不顯示逐行 diff；使用者點檔案不跳出 diff viewer
- **不支援多 branch 同時 filter（multi-select）**：Phase 階段僅提供單選 branch filter，未來視需求再擴充
- **不做 real-time auto-refresh**：僅手動 refresh + workspace 切換時 refresh + panel 獲得 focus 時輕量 refresh；不監聽 `.git` 檔案變動

## Capabilities

### New Capabilities

- `git-graph-panel`: 主畫面唯讀 git graph panel 能力，包含 commit graph 渲染、refs sidebar（branches/tags/stashes/worktrees）、branch 單選 filter、search 高亮、commit detail 展開、uncommitted changes 置頂、worktree 佔用標示、local+SSH workspace 支援

### Modified Capabilities

（無）

## Impact

- Affected specs: 新增 `specs/git-graph-panel/spec.md`
- Affected code:
  - `Sources/Panels/Panel.swift`：`PanelType` enum 新增 `.gitGraph` case
  - `Sources/Panels/GitGraphPanel.swift`（新檔）：Panel protocol 實作，仿 `MarkdownPanel.swift`
  - `Sources/Panels/GitGraphPanelView.swift`（新檔）：SwiftUI 主視圖（三欄 layout：refs sidebar / commit table / expanded detail）
  - `Sources/GitGraph/GitGraphProvider.swift`（新檔）：執行 `git log` / `git status` / `git stash list` / `git worktree list` / `git show --numstat` 並解析
  - `Sources/GitGraph/GitGraphModels.swift`（新檔）：`CommitNode` / `BranchRef` / `TagRef` / `StashEntry` / `WorktreeEntry` / `GitGraphSnapshot` 等 value types
  - `Sources/Panels/PanelContentView.swift`：switch panel type 時掛 git graph view
  - `Sources/TabManager.swift`：新增 `createGitGraphPanel(workspace:)` 入口
  - `Sources/cmuxApp.swift`：tab `+` 選單新增 Git Graph 項目
  - `Sources/KeyboardShortcutSettings.swift`：註冊「Open Git Graph Panel」可自訂快捷鍵
  - `Resources/Localizable.xcstrings`：新增英/日/繁中文字鍵（UI label、tooltip、error messages）
  - `Resources/Info.plist`：若新增 UTType 則補（預計不需要）
- Affected systems:
  - Workspace / Panel lifecycle（新 panel type 要能序列化還原 session、接受 focus、參與 tab drag）
  - SSH workspace 路徑（`GitGraphProvider` SSH 支援需透過現有 `runSSH()`）
- Affected docs: `docs/` 新增 git graph panel 使用說明；`CLAUDE.md` 若有相關 pitfalls 補充
- 無破壞性改動（所有既有 panel 行為不變）
