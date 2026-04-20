## 1. Phase 1 — Panel 骨架與基本 graph（Git Graph Panel as main-area panel type / 以新增 `PanelType.gitGraph` 整合進 Panel 系統）

- [x] 1.1 於 `Sources/Panels/Panel.swift` 的 `PanelType` enum 新增 `gitGraph` case；更新所有 `switch` 窮舉處：`Sources/Panels/PanelContentView.swift`、`Sources/Workspace.swift`（snapshot/restore/surfaceKind 三處 + `SurfaceKind.gitGraph` 常數）、`Sources/ContentView.swift`（command palette label + keywords）
- [x] 1.2 新建 `Sources/Panels/GitGraphPanel.swift`，以 `MarkdownPanel` 為範本實作 `Panel` protocol（Git Graph Panel as main-area panel type），綁定 workspace 目錄 + @Published 的 branch filter / search mode / search query / scroll anchor SHA + pixel offset 與 `reload()` 非同步資料載入（session persistence snapshot 型別留待後續 task 補）
- [x] 1.3 新建 `Sources/GitGraphProvider.swift` 定義 value types（單檔合併 models + provider，仿 GitStatusProvider 在 FileExplorerStore.swift 同檔風格）：`CommitNode`（sha/parents/subject/author/timestamp/refs/laneIndex/parentLanes）、`BranchRef`、`TagRef`、`StashEntry`、`WorktreeEntry`、`GitGraphSnapshot`、`GitGraphRepoState`、`GitRef`
- [x] 1.4 新建 `Sources/GitGraphProvider.swift`（資料層：新增 `GitGraphProvider` 仿 `GitStatusProvider` 模式），先實作 local `fetchCommits(directory:limit:skip:branchFilter:)`，使用 `git log --topo-order --format='%x1e%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s' -n <limit>` 與 RS/NUL 分隔 parser（`--topo-order` 為固定策略，不提供使用者切換）
- [x] 1.5 於 `GitGraphProvider` 實作 `fetchUncommittedCount(directory:)`（解析 `git status --porcelain` 行數）、`fetchHeadSha(directory:)`（`git rev-parse HEAD`）、`fetchHeadBranch(directory:)`（`git symbolic-ref --short HEAD`）、`detectRepoState(directory:)`（涵蓋 task 4.2 的偵測需求）
- [x] 1.6 在 `GitGraphProvider` 實作 lane 分配演算法：reservations map 追蹤 parent SHA → lane index，笔单 pass 自上而下指派 lane，first parent 繼承當前 lane（trunk 不斷裂）、其他 parent（merge）分配新 lane 或回收既有 reservation；結果寫回 `CommitNode.laneIndex` 與 `CommitNode.parentLanes`
- [x] 1.7 新建 `Sources/Panels/GitGraphPanelView.swift` 主視圖骨架（LazyVStack 渲染 commit rows、empty/noCommits/notRepo/gitUnavailable 四種 state UI、toolbar 含 refresh 按鈕 + workspace 路徑顯示）— 留存 TODO：自繪 `Canvas` lane 與分支合併線（會在 lane 演算法有多分支 commit 時實際發揮）
- [ ] 1.8 實作 commit row layout：Graph / Description（含 ref badges）/ Date / Author / Commit SHA 五欄，ref badges 用顏色區分 local / remote / tag（Commit graph rendering with lanes and ref badges） — **部分完成**（row 有 5 欄與 ref badges 顏色分類；lane 繪製目前是 placeholder dot，full canvas lane 待後續）
- [x] 1.9 實作 HEAD 指示器（HEAD indicator on current commit）：working tree 乾淨時 HEAD marker（黃色空心圓）放在 HEAD commit row；有 uncommitted changes 時 HEAD 放在 Uncommitted Changes row（已實作此 gating 邏輯）；detached HEAD 情境由 `isDetachedHead` 旗標驅動
- [x] 1.10 實作 Uncommitted Changes 置頂虛擬 row（Uncommitted Changes virtual row），N=0 時不渲染
- [x] 1.11 在 `Sources/Panels/PanelContentView.swift` 的 `switch panel.panelType` 加入 `.gitGraph` 分支，回傳 `GitGraphPanelView`
- [x] 1.12 入口與 lifecycle：`Workspace.newGitGraphSurface(inPane:focus:)` + `newGitGraphSurfaceInFocusedPane(focus:)`（仿 `newMarkdownSurface`，走 Bonsplit `createTab` + `applyTabSelection`、無 file-watch subscription）；`TabManager.newGitGraphSurface()` 外層 wrapper 供 palette 呼叫
- [x] 1.13 開啟入口：透過 command palette 項目 `palette.newGitGraphTab`（contribution + handler 均已註冊）— 使用者 `⌘⇧P` 搜 "git graph" 即可開啟。沿用 command palette 模式取代 Bonsplit tab `+` 選單（vendor fork 成本高，palette 發現性同樣充足）
- [ ] 1.14 在 `Sources/KeyboardShortcutSettings.swift` 註冊 `openGitGraphPanel` 可自訂快捷鍵（預設不綁鍵），並加入 Settings UI 編輯項 — 暫緩，需新增 ShortcutAction case + AppDelegate 拆彈，下次 session
- [ ] 1.15 新增 `Resources/Localizable.xcstrings` 的 `gitGraph.*` 鍵（英 / 日 / 繁中）涵蓋 Phase 1 所有 UI 文字

## 2. Phase 1 — 執行緒與效能（Off-main git execution）

- [x] 2.1 `GitGraphProvider` 所有 fetch function 保證在 background queue 執行；`GitGraphPanel.reload()` 以 `DispatchQueue.global(qos: .userInitiated)` 跑，完成後 `DispatchQueue.main.async` 推 snapshot（Off-main git execution）
- [x] 2.2 `GitGraphPanelView` 僅觀察 `@ObservedObject var panel: GitGraphPanel`，無跨 panel 的 @Published 引用；避免影響 terminal 打字延遲
- [x] 2.3 commit list 使用 `CommitNode.id = sha` 當 SwiftUI row id（`Identifiable` conform 且 `id: String { sha }`），確保 LazyVStack row 穩定 reuse

## 3. Phase 1 — 限制與重整（Commit fetch window and load-more / Refresh triggers / Commit 拉取策略：每次 N 筆（預設 500，Settings 可調 100–2000）+ 手動載入更多 + topo 排序 / Refresh 策略：三個觸發點，不做檔案監聽）

- [ ] 3.1 新增 Settings 項目 `gitGraph.commitsPerLoad`（預設 500、範圍 100–2000、逾界夾制並提示訊息），於 `KeyboardShortcutSettings` 相鄰的 Settings UI 放輸入欄
- [ ] 3.2 初次載入 `N` 筆 commits（讀 Settings）並在底部顯示 "Load More" 控制（Commit fetch window and load-more）；小於 `N` 筆時隱藏該按鈕
- [ ] 3.3 Load More 以 `git log --skip=<offset> -n <N>` 追加；合併既有 snapshot 並重算 lane；Settings 變更後已載入資料不立即截斷，下次 refresh 才套新值
- [ ] 3.4 實作三個 refresh 觸發點（Refresh triggers）：toolbar ⟳ 按鈕、workspace 切換、panel 獲得 focus 且上次 refresh > 30 秒，記錄 `lastRefreshAt: Date?`
- [ ] 3.5 實作 refresh vs Load More 併發處理：refresh 觸發時取消進行中的 Load More 並丟棄其部分結果，refresh 以完整 reload 取代

## 4. Phase 1 — Read-only 邊界與 repo 狀態（Read-only scope (no mutations) / Empty and non-repository states）

- [ ] 4.1 全 UI 審視無 mutation 入口（Read-only scope (no mutations)）：無 checkout / reset / rebase / stash pop / worktree add 按鈕或 context menu；以單元測試斷言 panel view 不產生對應 socket 或 shell 呼叫
- [x] 4.2 偵測 repo 狀態（Empty and non-repository states）：`GitGraphProvider.detectRepoState(directory:)` 以 `git rev-parse --show-toplevel` + `git rev-parse --verify HEAD` 判定 `repo(hasCommits:)` / `notARepo` / `gitUnavailable`；View 三種 empty state UI 完備（含 workspace 路徑顯示）
- [ ] 4.3 空 repo 若有 staged/untracked 檔案仍渲染 Uncommitted Changes row；Refs sidebar 仍顯示（空的 section 以 empty-state 標示）

## 5. Phase 2 — Commit detail 展開（Inline commit detail expansion / Commit detail 展開：inline row expansion，非 side panel / File tree 呈現：樹狀階層 + 檔案節點 `+N / -M` 數字）

- [ ] 5.1 於 `GitGraphProvider` 新增 `fetchCommitDetail(directory:sha:)`，輸出 `CommitDetail { sha, parents, authorName, authorEmail, committerName, committerEmail, date, fullMessage, files: [FileChange] }`，files 由 `git show --numstat --format= <sha>` 解析
- [ ] 5.2 新增 `FileChange` value type 與 `FileTreeNode` 輔助樹建構（依 `/` 切 path 合併目錄）
- [ ] 5.3 在 `GitGraphPanelView` 實作 inline row expansion（Inline commit detail expansion / Commit detail 展開：inline row expansion，非 side panel）：點 row 展開同一行下方 detail 區塊，顯示 SHA / parents / author / committer / date / full message / file tree
- [ ] 5.4 實作「最多一個展開 row」邏輯：點另一 row 收起前一個；點已展開 row 可收合
- [ ] 5.5 File tree 節點顯示 `+N / -M`（File tree 呈現：樹狀階層 + 檔案節點 `+N / -M` 數字 + 點檔跳 terminal）；目錄節點顯示子節點加總
- [ ] 5.6 實作 file tree 點檔行為：shell-escape file path 後組出 `git show <sha> -- <file>\n`，送到同 workspace 最近聚焦的 terminal panel；若無 terminal 則新建一個 terminal panel
- [ ] 5.7 點目錄節點只 toggle 展開/收合，不產生 terminal 指令
- [ ] 5.8 大 commit（檔案 > 500）顯示 spinner 並於 2s timeout 後降級顯示 "Too many files (N)" + 「在 Terminal 開啟」提示
- [ ] 5.9 補齊 Phase 2 相關的 `gitGraph.*` 在地化鍵（Localized user-facing strings）

## 6. Phase 3 — Refs sidebar（Refs sidebar listing branches, tags, stashes, and worktrees）

- [ ] 6.1 `GitGraphProvider` 新增 `fetchBranches(directory:)`、`fetchTags(directory:)`、`fetchStashes(directory:)`、`fetchWorktrees(directory:)`
- [ ] 6.2 `GitGraphPanelView` 加入左側可收合 Refs sidebar（Refs sidebar listing branches, tags, stashes, and worktrees），分四段 Branches / Tags / Stashes / Worktrees
- [ ] 6.3 實作「點 branch / tag → scroll 到該 commit」（commit list 以 `ScrollViewReader.scrollTo(sha)`）
- [ ] 6.4 空 section 顯示 empty-state label（已收合但可展開）

## 7. Phase 3 — Branch filter（Single-branch filter / Branch filter 使用單選 + `--all` 切換）

- [ ] 7.1 Panel toolbar 新增 branch 下拉選單（Single-branch filter），預設 "All"
- [ ] 7.2 選特定 branch 時，`GitGraphProvider.fetchGraph` 以 `branchFilter` 參數改用 `git log <branch>`；選 All 時回 `--all`
- [ ] 7.3 Filter 變更時清除 commit list 並重新載入，保留 scroll 至 top
- [ ] 7.4 實作「HEAD outside current filter」toolbar 橫幅：當 filter 開啟且 HEAD commit 不在 filter 可達集合時，顯示 `HEAD is on <branch-name>, not in current filter`（dirty 工作樹時附加 `(uncommitted changes)`）＋「Show All」按鈕；filter 下隱藏 Uncommitted Changes row

## 8. Phase 3 — Search 高亮與篩選（Commit search with highlight / Search：前端 fuzzy + 高亮為預設，可切換篩選模式）

- [ ] 8.1 Toolbar 加 search input、清除按鈕、以及 highlight / filter 模式 toggle（Commit search with highlight）
- [ ] 8.2 實作 case-insensitive substring 比對：比 commit message、author name、SHA prefix
- [ ] 8.3 Highlight mode（預設）：所有 row 保留顯示，命中 row 套高亮背景 + matched substring 橘色 emphasis
- [ ] 8.4 Filter mode：非 match row 不渲染；因隱藏造成 lane 斷裂改以虛線 placeholder 表示（Search：前端 fuzzy + 高亮為預設，可切換篩選模式）
- [ ] 8.5 Search query 變化時自動 scroll 到第一筆 match；toggle 切換時保留 query
- [ ] 8.6 Search 僅作用於已載入的 snapshot，不重跑 `git log`

## 9. Phase 3 — Stash 顯示（Stash entries displayed read-only / Stash 顯示為左 sidebar list + 列內行，不混進主 commit 流）

- [ ] 9.1 Refs sidebar Stashes 區列 `git stash list` 結果（Stash entries displayed read-only）
- [ ] 9.2 點 stash entry → 於 commit list 頂部（Uncommitted Changes 下方）新增一筆 highlighted stash row
- [ ] 9.3 Stash row 可展開，透過 `git stash show --numstat <stash-ref>` 顯示 file numstat
- [ ] 9.4 驗證 stash 不混入 `--all` 主 commit log（Stash 顯示為左 sidebar list + 列內行，不混進主 commit 流）

## 10. Phase 3 — Worktree 佔用標示（Worktree occupancy indication / Worktree 顯示：Refs sidebar list + branch badge icon 標示）

- [ ] 10.1 `fetchWorktrees` 解析 `git worktree list --porcelain`，輸出 `[WorktreeEntry]`（path / branch / bare / detached / locked）
- [ ] 10.2 計算當前 panel 所在 worktree 與其他 worktree 的 branch 佔用 map（Worktree occupancy indication）
- [ ] 10.3 ref badge 若該 branch 被其他 worktree 佔用，附加 `⎘` icon + tooltip 顯示 path
- [ ] 10.4 sidebar Worktrees 區標示當前 worktree（`★`），並針對 path 不存在的 worktree 顯示 stale 狀態

## 11. SSH 支援（Local and SSH workspace support / 本機 SSH 一致 API：`GitGraphProvider` 分 local / ssh 兩組 function，caller 根據 workspace 挑）

- [ ] 11.1 為 `GitGraphProvider` 每個 fetch function 新增 `*SSH(...)` 版本（Local and SSH workspace support / 本機 SSH 一致 API：`GitGraphProvider` 分 local / ssh 兩組 function，caller 根據 workspace 挑），透過現有 SSH runner 執行 `cd '<dir>' && git ...` 並以 NUL + RS 分段 stdout
- [ ] 11.2 `GitGraphPanel` view model 依 workspace 類型（local vs SSH）挑選對應 function（caller 根據 workspace 挑）
- [ ] 11.3 若 SSH 遠端無 `git`，顯示在地化錯誤 `git not found on <host>` 並彈出安裝對話框（遠端 git 缺失時的裝 git 流程）；使用者按 refresh 重新探測遠端 git 可用性
- [ ] 11.4 實作遠端 OS 探測：`uname -s` + `command -v apt-get dnf apk brew`，分類為 debian/ubuntu、rhel/fedora、alpine、macos；未分類走 unknown OS 路徑
- [ ] 11.5 實作安裝 flow：檢查 passwordless sudo（非 macOS brew 情境），執行對應套件管理器指令；stdout 以 streaming 顯示於對話框 log 區
- [ ] 11.6 安裝失敗或缺 sudo 時 fallback 顯示 stderr tail（末 10 行）＋ 手動指令提示；對話框標題明示 `<host>` + 修改遠端系統警語，確認需二次點擊
- [ ] 11.7 安裝成功自動 refresh；對話框不支援的 OS、取消、失敗皆維持錯誤狀態

## 12. 本機化與收尾（Localized user-facing strings / 在地化：全數進 xcstrings）

- [ ] 12.1 審視 `GitGraphPanelView` 及子視圖所有字串，確認以 `String(localized: "gitGraph.<key>", defaultValue: ...)` 宣告（Localized user-facing strings）
- [ ] 12.2 補齊 `Resources/Localizable.xcstrings` 英 / 日 / 繁中三組翻譯（在地化：全數進 xcstrings）
- [ ] 12.3 更新 `docs/` 新增 Git Graph panel 使用說明章節（含截圖佔位與快捷鍵說明）
- [ ] 12.4 若新增 CLAUDE.md pitfalls（例：不可在 GitGraph row body 讀 workspace store），補充於對應段落

## 13. 測試與驗證

- [ ] 13.1 `cmuxTests/` 新增 `GitGraphProviderTests` 單元測試：餵固定 stdout，斷言 parser 輸出 CommitNode / FileChange / WorktreeEntry 結構正確
- [ ] 13.2 新增 lane 分配演算法單元測試：線性 / 分支 / 合併 / 多父 merge 各一組 fixture
- [ ] 13.3 新增 `GitGraphPanel` 持久化單元測試：序列化 branch filter + scroll offset + workspace path，反序列化還原
- [ ] 13.4 手動驗證矩陣：Phase 1 (build + open + graph 顯示 + HEAD + uncommitted) / Phase 2 (展開 detail + numstat) / Phase 3 (sidebar + filter + search + stash + worktree)
- [ ] 13.5 以 `./scripts/reload.sh --tag git-graph` 建 Debug app 並於 cmux 本機 + SSH workspace 各跑一次 smoke test
