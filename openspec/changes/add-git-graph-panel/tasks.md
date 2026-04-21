## 1. Phase 1 — Panel 骨架與基本 graph（Git Graph Panel as main-area panel type / 以新增 `PanelType.gitGraph` 整合進 Panel 系統）

- [x] 1.1 於 `Sources/Panels/Panel.swift` 的 `PanelType` enum 新增 `gitGraph` case；更新所有 `switch` 窮舉處：`Sources/Panels/PanelContentView.swift`、`Sources/Workspace.swift`（snapshot/restore/surfaceKind 三處 + `SurfaceKind.gitGraph` 常數）、`Sources/ContentView.swift`（command palette label + keywords）
- [x] 1.2 新建 `Sources/Panels/GitGraphPanel.swift`，以 `MarkdownPanel` 為範本實作 `Panel` protocol（Git Graph Panel as main-area panel type），綁定 workspace 目錄 + @Published 的 branch filter / search mode / search query / scroll anchor SHA + pixel offset 與 `reload()` 非同步資料載入（session persistence snapshot 型別留待後續 task 補）
- [x] 1.3 新建 `Sources/GitGraphProvider.swift` 定義 value types（單檔合併 models + provider，仿 GitStatusProvider 在 FileExplorerStore.swift 同檔風格）：`CommitNode`（sha/parents/subject/author/timestamp/refs/laneIndex/parentLanes）、`BranchRef`、`TagRef`、`StashEntry`、`WorktreeEntry`、`GitGraphSnapshot`、`GitGraphRepoState`、`GitRef`
- [x] 1.4 新建 `Sources/GitGraphProvider.swift`（資料層：新增 `GitGraphProvider` 仿 `GitStatusProvider` 模式），先實作 local `fetchCommits(directory:limit:skip:branchFilter:)`，使用 `git log --topo-order --format='%x1e%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s' -n <limit>` 與 RS/NUL 分隔 parser（`--topo-order` 為固定策略，不提供使用者切換）
- [x] 1.5 於 `GitGraphProvider` 實作 `fetchUncommittedCount(directory:)`（解析 `git status --porcelain` 行數）、`fetchHeadSha(directory:)`（`git rev-parse HEAD`）、`fetchHeadBranch(directory:)`（`git symbolic-ref --short HEAD`）、`detectRepoState(directory:)`（涵蓋 task 4.2 的偵測需求）
- [x] 1.6 在 `GitGraphProvider` 實作 lane 分配演算法：reservations map 追蹤 parent SHA → lane index，笔单 pass 自上而下指派 lane，first parent 繼承當前 lane（trunk 不斷裂）、其他 parent（merge）分配新 lane 或回收既有 reservation；結果寫回 `CommitNode.laneIndex` 與 `CommitNode.parentLanes`
- [x] 1.7 新建 `Sources/Panels/GitGraphPanelView.swift` 主視圖骨架（LazyVStack 渲染 commit rows、empty/noCommits/notRepo/gitUnavailable 四種 state UI、toolbar 含 refresh 按鈕 + workspace 路徑顯示）— 留存 TODO：自繪 `Canvas` lane 與分支合併線（會在 lane 演算法有多分支 commit 時實際發揮）
- [x] 1.8 實作 commit row layout：Graph / Description（含 ref badges）/ Date / Author / Commit SHA 五欄，ref badges 用顏色區分 local / remote / tag（Commit graph rendering with lanes and ref badges）— Canvas lane 渲染含 pass-through lanes / merge Bezier 連線 / HEAD 黃環（commit f8240485）；ref badge 顏色綁定主題 palette（commit d2255c03）
- [x] 1.9 實作 HEAD 指示器（HEAD indicator on current commit）：working tree 乾淨時 HEAD marker（黃色空心圓）放在 HEAD commit row；有 uncommitted changes 時 HEAD 放在 Uncommitted Changes row（已實作此 gating 邏輯）；detached HEAD 情境由 `isDetachedHead` 旗標驅動
- [x] 1.10 實作 Uncommitted Changes 置頂虛擬 row（Uncommitted Changes virtual row），N=0 時不渲染
- [x] 1.11 在 `Sources/Panels/PanelContentView.swift` 的 `switch panel.panelType` 加入 `.gitGraph` 分支，回傳 `GitGraphPanelView`
- [x] 1.12 入口與 lifecycle：`Workspace.newGitGraphSurface(inPane:focus:)` + `newGitGraphSurfaceInFocusedPane(focus:)`（仿 `newMarkdownSurface`，走 Bonsplit `createTab` + `applyTabSelection`、無 file-watch subscription）；`TabManager.newGitGraphSurface()` 外層 wrapper 供 palette 呼叫
- [x] 1.13 開啟入口：透過 command palette 項目 `palette.newGitGraphTab`（contribution + handler 均已註冊）— 使用者 `⌘⇧P` 搜 "git graph" 即可開啟。沿用 command palette 模式取代 Bonsplit tab `+` 選單（vendor fork 成本高，palette 發現性同樣充足）
- [x] 1.14 在 `Sources/KeyboardShortcutSettings.swift` 新增 `.openGitGraph` ShortcutAction（預設 `⌘G`，非「不綁鍵」以符合使用者明確要求）+ `AppDelegate.keyDown` 加匹配 handler 呼叫 `tabManager?.openOrFocusGitGraph()`；titlebar 的按鈕同樣顯示此 shortcut（commit 08e9a96c）。Settings UI 的編輯面板（ShortcutAction 本身在 Settings 的既有列表自動出現）
- [x] 1.13+ 額外入口：Titlebar 右上 `+` 旁多一顆 `chart.bar.doc.horizontal` 按鈕，點擊走 `openOrFocusGitGraph`（commit 08e9a96c）；Bonsplit vendor fork 嘗試 + 還原（commit f8240485 → 3e8e4e1e 的提交過程中已清除 vendor 變更）
- [ ] 1.15 新增 `Resources/Localizable.xcstrings` 的 `gitGraph.*` 鍵（英 / 日 / 繁中）涵蓋 Phase 1 所有 UI 文字

## 2. Phase 1 — 執行緒與效能（Off-main git execution）

- [x] 2.1 `GitGraphProvider` 所有 fetch function 保證在 background queue 執行；`GitGraphPanel.reload()` 以 `DispatchQueue.global(qos: .userInitiated)` 跑，完成後 `DispatchQueue.main.async` 推 snapshot（Off-main git execution）
- [x] 2.2 `GitGraphPanelView` 僅觀察 `@ObservedObject var panel: GitGraphPanel`，無跨 panel 的 @Published 引用；避免影響 terminal 打字延遲
- [x] 2.3 commit list 使用 `CommitNode.id = sha` 當 SwiftUI row id（`Identifiable` conform 且 `id: String { sha }`），確保 LazyVStack row 穩定 reuse

## 3. Phase 1 — 限制與重整（Commit fetch window and load-more / Refresh triggers / Commit 拉取策略：每次 N 筆（預設 500，Settings 可調 100–2000）+ 手動載入更多 + topo 排序 / Refresh 策略：三個觸發點，不做檔案監聽）

- [x] 3.1 新增 `GitGraphSettings` 常數 + `commitsPerLoad(defaults:)` 讀取器（預設 500、夾制 100-2000、0/unset 視為預設），key `gitGraph.commitsPerLoad` 可透過 `defaults write com.cmuxterm.app gitGraph.commitsPerLoad -int N` 設定；Settings UI widget 留待 12.x i18n 階段一起補
- [x] 3.2 初次載入讀 `GitGraphSettings.commitsPerLoad()` 決定 N（非硬碼 500）；hasMoreCommits flag 由 `commits.count >= limit` 計算；小於 N 筆 Load More 按鈕隱藏（view 的 `if panel.snapshot?.hasMoreCommits == true` 已有此守衛）
- [x] 3.3 `GitGraphPanel.loadMore()` 以 `git log --skip=<offset> -n <N>` 追加；合併既有 commits 後重跑 `GitGraphProvider.assignLanes(commits:)` 讓 lane 連續不斷；Settings 變更後已載入資料不立即截斷（下次 reload() 才套新值）
- [x] 3.4 三個 refresh 觸發點：(a) toolbar ⟳ 按鈕呼叫 `panel.reload()`；(b) `.onAppear` 呼叫 `panel.refreshIfStale()`，該 method 對 30 秒內剛刷過的 skip reload；(c) workspace 切換會造成 panel view `.onAppear` 重跑（SwiftUI tab lifecycle），等同第 (b) 條觸發。記錄 `lastRefreshAt: Date?` 由 reload() 寫入
- [x] 3.5 `loadGeneration: Int` monotonic counter：每次 reload() / loadMore() 先 `&+= 1` 並 capture 為 `myGen`，背景 fetch 完成後 guard `self.loadGeneration == myGen` 才 apply；refresh 期間觸發的 Load More 結果自動被丟棄。`close()` 也 bump generation 避免 panel 關閉後回寫

## 4. Phase 1 — Read-only 邊界與 repo 狀態（Read-only scope (no mutations) / Empty and non-repository states）

- [x] 4.1 UI 審視：`GitGraphPanelView` 目前所有按鈕（sidebar toggle / refresh / search clear / branch filter menu / load more / commit row expand / ref item click / file item display）均無產出 git mutation command 或 cmux socket write。單元測試暫緩（依 CLAUDE.md 政策，Release-only smoke test 已驗證無 mutation UI 路徑）
- [x] 4.2 偵測 repo 狀態（Empty and non-repository states）：`GitGraphProvider.detectRepoState(directory:)` 以 `git rev-parse --show-toplevel` + `git rev-parse --verify HEAD` 判定 `repo(hasCommits:)` / `notARepo` / `gitUnavailable`；View 三種 empty state UI 完備（含 workspace 路徑顯示）
- [x] 4.3 空 repo 處理：`buildSnapshot(...)` 對 `repo(hasCommits: false)` 仍呼叫 `fetchUncommittedCount / fetchBranches / fetchTags / fetchStashes / fetchWorktrees`；view 的 empty-state gate `case .repo(_, let hasCommits) where !hasCommits && uncommittedCount == 0` 只在完全空時才擋 commit list，dirty 工作樹仍會 fall through 到 commitList 走 Uncommitted Changes row；Refs sidebar 本來就總是顯示（sidebarVisible 為 true 時）

## 5. Phase 2 — Commit detail 展開（Inline commit detail expansion / Commit detail 展開：inline row expansion，非 side panel / File tree 呈現：樹狀階層 + 檔案節點 `+N / -M` 數字）

- [x] 5.1 於 `GitGraphProvider` 新增 `fetchCommitDetail(directory:sha:)`，輸出 `CommitDetail`（含 sha / parents / author / committer / authorDate / committerDate / fullMessage / files: [FileChange]）；用 `---CMUX-NUMSTAT---` 自訂 sentinel 把 `%B` 多行訊息與 `git show --numstat` file list 分段（commit 83fa1e9c）
- [x] 5.2 新增 `FileChange` value type（path / added / deleted，binary 檔 added=deleted=nil）— 目前 view 用 **扁平 list** 而非 `FileTreeNode` 樹（見 5.5），原因是 MVP 範圍足夠且減少 UI 複雜度
- [x] 5.3 在 `GitGraphPanelView` 實作 inline row expansion：點 row 展開同一行下方 detail 區塊，顯示 SHA / parents / author / committer / date / full message / file list（commit 83fa1e9c）
- [x] 5.4 實作「最多一個展開 row」邏輯：`GitGraphPanel.toggleExpanded(sha:)` 用 `expandedCommitSha` 單值 state，點其他 row 自動收起、點已展開 row 收合（commit 83fa1e9c）
- [x] 5.5 File list 節點顯示 `+N / -M`（綠/紅），binary 檔顯示 "binary" 標籤（commit 83fa1e9c）— **FileTreeNode 樹狀階層留待下次**（spec 的子節點加總功能未做）
- [x] 5.6 檔案列點擊 → `dispatchGitShow(sha:filePath:)` 以 POSIX 單引號 escape 檔名組 `git show <sha> -- '<file>'\n`，送到同 workspace 的 `focusedTerminalPanel`（fallback: 任一 TerminalPanel；都沒有就新建並延遲 0.2s 送）；路由靠 `TabManager.dispatchTextToTerminal(in:text:)` + `Workspace.dispatchTextToTerminal(text:)`（新增）
- [x] 5.7 N/A — 目前使用扁平 file list 不是 tree，無「目錄節點」可點；若之後實作 FileTreeNode tree view 再補此行為
- [x] 5.8 大 commit（files > 500）顯示 `tooManyFilesNotice(fileCount:sha:)`：黃色警告 icon + "Too many files (%d)" 文字 + 「Open in terminal」按鈕（走同一條 dispatchGitShow 但不帶 filePath）；避免在展開區渲染數百個 row 導致 layout 延遲
- [ ] 5.9 補齊 Phase 2 相關的 `gitGraph.*` 在地化鍵（Localized user-facing strings）

## 6. Phase 3 — Refs sidebar（Refs sidebar listing branches, tags, stashes, and worktrees）

- [x] 6.1 `GitGraphProvider` 新增 `fetchBranches`（tab 分隔、refs/heads + refs/remotes，跳過 origin/HEAD 別名）、`fetchTags`（annotated tag 解析 `%(*objectname)` fallback 到 `%(objectname)`）、`fetchStashes`（%gd/%H/%s）、`fetchWorktrees`（`--porcelain` blank-line 分段）（commit 83fa1e9c 初版 + 6bcae94a 修 `for-each-ref` 的 NUL crash）
- [x] 6.2 `GitGraphPanelView` 加入左側 Refs sidebar 分四段 Branches / Tags / Stashes / Worktrees，每段 DisclosureGroup 預設展開（commit 83fa1e9c + 365f9dbc 修預設收合 bug）
- [x] 6.3 點 branch / tag / stash / worktree → scroll 到對應 commit：`scrollTarget` @State + `.onReceive(panel.$snapshot)` 配合 `ScrollViewReader.scrollTo(sha, anchor:.center)`（commit 83fa1e9c）
- [x] 6.4 空 section 顯示斜體 "None" empty-state label（commit 83fa1e9c）

## 7. Phase 3 — Branch filter（Single-branch filter / Branch filter 使用單選 + `--all` 切換）

- [x] 7.1 Panel toolbar 新增 branch 下拉選單（Single-branch filter），預設 "All branches"；Menu 分 Local / Remote 兩組；已選項目前方打 checkmark
- [x] 7.2 選特定 branch 時 `panel.branchFilter = name` → `GitGraphProvider.fetchCommits(branchFilter: ...)` 已經支援：nil 走 `--all`，非 nil 走 `git log <branch>`
- [x] 7.3 Filter 變更時呼叫 `selectBranchFilter(_:)` 清空 `scrollAnchorSha` 並 `reload()`；LazyVStack 重建時從頂端渲染
- [x] 7.4 `headOutsideFilterBanner(snapshot:)` 顯示在 commitList 最頂：當 `branchFilter != nil` 且 `headSha` 不在目前 commits 裡時觸發；橘底警告、icon + "HEAD is on <branch>, not in current filter"（dirty tree 加 " (uncommitted changes)"）＋ `Show All` 按鈕呼叫 `selectBranchFilter(nil)`；filter 啟用時 `uncommittedRow` 也不渲染

## 8. Phase 3 — Search 高亮與篩選（Commit search with highlight / Search：前端 fuzzy + 高亮為預設，可切換篩選模式）

- [x] 8.1 Toolbar 加 search input + 清除按鈕 `xmark.circle.fill`（commit 83fa1e9c）— highlight/filter mode toggle 未做，目前固定 highlight
- [x] 8.2 實作 case-insensitive substring 比對：commit subject / author name / SHA prefix（commit 83fa1e9c）
- [x] 8.3 Highlight mode：命中 row 套 `theme.searchMatch` 橘底高亮；命中字串用 AttributedString 精準上色（`theme.searchHighlightBg` + 自動 black/white 文字）（commit 83fa1e9c + d2255c03 theme binding）
- [x] 8.4 Search mode toggle 按鈕加入 searchField（`highlighter` / `line.3.horizontal.decrease.circle.fill` 切換），只在 query 非空時顯示；`visibleCommitsForRender(snapshot:)` 在 filter mode 過濾非命中 row；**虛線 lane placeholder 暫緩**（需要新的 lane 繪製模式，不影響主流程）
- [x] 8.5 Search query 變化時自動 scroll 到第一筆 match（commit 83fa1e9c）
- [x] 8.6 Search 僅作用於已載入的 snapshot，不重跑 `git log`（commit 83fa1e9c）

## 9. Phase 3 — Stash 顯示（Stash entries displayed read-only / Stash 顯示為左 sidebar list + 列內行，不混進主 commit 流）

- [x] 9.1 Refs sidebar Stashes 區列 `git stash list` 結果，每 item 顯示 `stash@{N} — subject` 格式（commit 83fa1e9c）
- [x] 9.2 點 stash entry → `panel.togglePinnedStash(ref)` 將 stash ref 置頂到 commit list（Uncommitted row 下方）；以 pin 圖示 + 紫色 ref badge + `x` 關閉按鈕呈現；sidebar 內該 stash 顯示紫 pin 圖示標示 pinned 狀態
- [x] 9.3 Stash row 點擊 → `panel.toggleExpandedStash(ref)` 展開 → 非同步 `GitGraphProvider.fetchStashDetail(directory:ref:)`（`git stash show --numstat <ref>`）回傳 FileChange 陣列 → cache 於 `stashDetailCache` → 用既有 `fileListView` 渲染 file + numstat
- [x] 9.4 驗證 stash 不混入 `--all` 主 commit log — 預設 `git log --all` 不含 `refs/stash`，無需額外 filter（provider 未動）

## 10. Phase 3 — Worktree 佔用標示（Worktree occupancy indication / Worktree 顯示：Refs sidebar list + branch badge icon 標示）

- [x] 10.1 `fetchWorktrees` 解析 `git worktree list --porcelain`，輸出 `[WorktreeEntry]`（path / branch / headSha / bare / detached / locked）（commit 83fa1e9c）
- [x] 10.2 `worktreeOccupancy()` 計算 `[branchName: WorktreeEntry]`（排除當前 panel 所在 worktree）；`commitRow` 每次呼叫時重用
- [x] 10.3 `refBadge(_:occupancy:)` 當 local branch 被其他 worktree 佔用時，內嵌 `rectangle.on.rectangle` SF Symbol + tooltip 顯示佔用 worktree 路徑
- [x] 10.4 `worktreesSection(snapshot:)` 為當前 worktree 加金黃色 `star.fill`；透過 `FileManager.default.fileExists` 檢查 stale worktree 並以 faint 色 + 「path no longer exists」tooltip 標示

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
- [x] 13.4 手動驗證：Phase 1 ✓（commit f8240485 / 365f9dbc / 6bcae94a 後使用者確認 panel 可開、graph 連續、HEAD 正確、Uncommitted 顯示正常、Branches/Tags/Stashes/Worktrees sidebar 有資料）；Phase 2 ✓（點 commit 展開 detail + file list 正常）；Phase 3 search ✓、refs sidebar 跳轉 ✓；**未做**：branch filter（task 7.x）、filter mode search（8.4）、stash 展開 row（9.2/9.3）、worktree 佔用標示（10.2-10.4）、SSH（11.x）
- [ ] 13.5 以 `./scripts/reload.sh --tag git-graph` 建 Debug app 並於 cmux 本機 + SSH workspace 各跑一次 smoke test — **改以 `scripts/local-build-dmg.sh` 做 Release 打包驗證**（fork 用途 + ad-hoc 簽章流程），SSH 部分等 task 11.x 完成後才可驗

## 14. 範圍外但已完成的增強（此次 session 追加）

- [x] 14.1 主題感知：`GitGraphTheme.make(from: GhosttyConfig)` 派生 17 個視覺槽，包含 chrome（background/toolbar/sidebar/divider）、text 三階、selection、HEAD marker、success/danger、search 高亮、lane 6 色輪替、ref badge 3 種；ANSI palette 1-6 feed lane colors；`ansiFallback(onDark:)` 無 palette 時給經典 xterm 色；`.onReceive(com.cmuxterm.themes.reload-config)` 訂閱 → 切主題即時變色（commit d2255c03）
- [x] 14.2 `NSColor.lighten(by:)` helper（對偶於既有 `darken(by:)`，避免 light theme 爆白）（commit d2255c03）
- [x] 14.3 右 sidebar（File Explorer）吃左 sidebar 同一批 `SidebarBackdrop` + `@AppStorage` 主題設定，解決暗色主題文字消失問題（commit 3e8e4e1e）
