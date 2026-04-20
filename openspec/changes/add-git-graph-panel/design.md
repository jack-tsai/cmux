## Visual Reference

使用者已視覺確認的 HTML mockup（實作 SwiftUI view 時的視覺基準）：
`docs/uidesign/git-graph-panel-design.html`

主要視覺決定：
- 深色配景、系統字體；commit SHA、ref badge 使用 monospace
- Refs sidebar 寬度 210px，四段 Branches / Tags / Stashes / Worktrees 皆可收合
- Ref badge 配色：local = `#2d6cdf`（藍）、remote = `#6a737d`（灰）、tag = `#8957e5`（紫）、stash = `#bf5af2`（亮紫）、HEAD = `#f0b429`（金）
- Lane 色板：6 色輪替（`#0a84ff`、`#bf5af2`、`#30d158`、`#ff9f0a`、`#ff375f`、`#5ac8fa`）
- Uncommitted Changes row：淡綠底 `rgba(63,185,80,0.06)`；HEAD marker 為雙圈 ◎（dirty tree 時顯示於此行）
- Stash 行：淡紫底 + 虛線圓 marker
- Commit detail 展開：左右兩欄（1.2fr meta / 1fr file tree）
- Search 高亮：match row 套 `rgba(255,144,0,0.18)` 背景 + 橘色 `<mark>` emphasis
- HEAD-outside-filter banner：橘黃色 warning 底 + 「Show All」action button

## Context

cmux 是以 Ghostty 為核心的 macOS 終端機，主打 AI agent 平行開發。主畫面由 Panel 組成（目前型別：`terminal` / `browser` / `markdown`），可分頁、分割、跨 workspace 管理。Workspace 可為本機目錄或透過 SSH 連線的遠端。

**現有 git 整合：**
- `Sources/FileExplorerStore.swift:816` 內有 `GitStatusProvider`，支援 local + SSH 兩條路徑，呼叫 `git status --porcelain` 與 `git rev-parse --show-toplevel` 並解析；是這次要重用的 helper 邊界。
- 側邊欄現有 branch / PR / 目錄顯示功能，由 socket command `report_git_branch` 推送。

**Panel 架構：**
- `Sources/Panels/Panel.swift`：`PanelType` enum + `Panel` protocol（`@MainActor` + `ObservableObject`）。
- `Sources/Panels/MarkdownPanel.swift`（184 行）：最接近的 read-only panel 範本。
- `Sources/Panels/PanelContentView.swift`：根據 `panelType` 切換 SwiftUI view。

**使用者期待的視覺：** Fork.app 風格的 commit table（見 discuss 階段截圖），包含 Graph / Description / Date / Author / Commit 五欄、branch lane 顏色、ref badges、點 row 展開 detail + file tree + numstat。

**限制：**
- cmux 極度看重輸入延遲（CLAUDE.md 有「Typing-latency-sensitive paths」清單）；新 panel 的渲染與狀態更新不能影響 terminal panel 的打字延遲。
- 大 repo（e.g., ghostty 本身 10w+ commits）不可一次全撈。
- 所有 UI 字串需進 `Resources/Localizable.xcstrings`（英/日/繁中）。
- 快捷鍵需進 `KeyboardShortcutSettings` 且可在 Settings UI 編輯。

## Goals / Non-Goals

**Goals:**

- 在主畫面提供唯讀 git graph panel，以 3-4 週內可交付的範圍覆蓋 branch 拓撲、HEAD 位置、uncommitted changes、stash、tag、worktree 佔用標示
- 支援 local 與 SSH workspace，沿用 `GitStatusProvider` 的 SSH 通道風格
- 可分階段交付（Phase 1 → Phase 2 → Refs sidebar + filter + search）讓中途可中斷仍有可用版本
- 不拖慢既有 terminal panel 的輸入延遲與 UI 主執行緒

**Non-Goals:**

- 不做任何 mutation（見 proposal Non-Goals）
- 不實作 diff viewer 或 merge conflict 解決畫面
- 不整合到左 sidebar tab metadata（PR 號、branch 名）— 那是既有 workspace-level 行為
- 不做跨 repo 聚合 panel
- 不做逐行 blame / log follow --follow
- 不做 real-time 檔案系統監聽（依賴手動/生命週期 refresh）

## Decisions

### 以新增 `PanelType.gitGraph` 整合進 Panel 系統

**選擇：** 新增 `PanelType.gitGraph` 並實作 `GitGraphPanel: Panel`，仿 `MarkdownPanel` 結構。

**理由：** 使用者明確要求「主畫面」而非 sidebar。Panel 系統已支援 tab + split + 拖放 + session 持久化，新 type 能自動獲得這些能力。`MarkdownPanel` 是最接近的 read-only panel，184 行純展示 + 狀態，模板成本最低。

**替代：**
- 做右 sidebar 第三個 mode（`.gitGraph`）— 被使用者否決，主畫面空間與視覺比重更合適。
- 做獨立 `NSWindow`（如 Debug 視窗系列）— 會與 workspace 解耦，切 workspace 時無法跟隨；且無法 split 到 terminal 旁邊。

### 採 Fork-style 表格 + 自繪 graph lane（而非純文字 `git log --graph`）

**選擇：** 用 SwiftUI `LazyVStack` 渲染 commit rows，每 row 以 `Canvas` 或 `Path` 繪製 lane 與 commit 點；`git log --format=<custom>` 拉結構化資料，自行計算 lane 分配。

**理由：** 主畫面版面大，純文字 graph 視覺廉價且無法做 row selection / 展開 detail；自繪 lane 可精確控制顏色、交會點、branch 標示。Commit DAG lane 分配演算法是 solved problem（每個 parent 分一個 lane，merge 時合併）。

**替代：**
- 純 `git log --graph --oneline` 文字嵌入 monospace `Text`（0.5 天）— 被使用者否決（見 discuss 截圖）。
- 嵌入 web view 跑 JS graph 函式庫（如 gitgraph.js）— 引入 web 依賴、與 cmux Swift-first 原則衝突、效能與啟動成本高。

### 資料層：新增 `GitGraphProvider` 仿 `GitStatusProvider` 模式

**選擇：** 新建 `Sources/GitGraph/GitGraphProvider.swift`，公開 static API：`fetchGraph(directory:limit:branchFilter:)` / `fetchStash(directory:)` / `fetchTags(directory:)` / `fetchWorktrees(directory:)` / `fetchCommitDetail(directory:sha:)`；每支同時提供 local 與 SSH 版本。

**理由：** 與既有 `GitStatusProvider` 同構，降低維護心智。純 static function + value type 輸出，無狀態，易測試（unit test 餵假 stdout 即可）。

**替代：**
- 包成 `ObservableObject` 直接塞進 view model — 無法在 SSH path 下乾淨解耦，且重用困難。
- 使用 libgit2 綁定 — 增加 C dependency、要處理 signing 與 submodule，成本不划算。

### Commit 拉取策略：每次 N 筆（預設 500，Settings 可調 100–2000）+ 手動載入更多 + topo 排序

**選擇：** `git log --all --topo-order --format=<custom> -n <N>`，UI 底部放「載入更多 N 筆」按鈕；`N` 從 Settings `gitGraph.commitsPerLoad` 讀取，預設 500，允許 100–2000（逾界夾制）；branch filter 開啟時替換 `--all` 為 `<branch>`；`--topo-order` 固定使用，不提供使用者切換。

**理由：**
- ghostty repo 10w+ commits，全撈會卡；500 足以看「最近幾週」脈絡，超過才手動展開。
- `--topo-order` 保證 parent 永遠在 child 下方，lane 繪製不會交錯；Fork / GitKraken 等主流 graph UI 皆採此順序。`--date-order` 在 amend / rebase 後時間錯亂時會造成視覺上 lane 前後顛倒，對「了解 branch 結構」此目的是 regression。

**替代：**
- 無限 scroll 自動載入 — 使用者難預期何時停；且大量 row 的 lane 重新配置會閃爍。
- 依 `--since` 時間切片 — 跨 branch 的 merge commit 時間不連續，切片結果會漏 commit。
- `--date-order` / `--author-date-order` — 在歷史被改寫的情境下 lane 圖形會錯亂。

### Branch filter 使用單選 + `--all` 切換

**選擇：** toolbar 放一個下拉選單：`All (default)` / `main` / `feature-x` / ...；選 branch 時 `git log <branch>` 只顯示該 branch reachable 的 commits。

**理由：** 使用者明確選單選。單選 UX 簡單，資料查詢一條指令搞定。

**替代：** 多選已被使用者排除。

### Stash 顯示為左 sidebar list + 列內行，不混進主 commit 流

**選擇：** 左 Refs sidebar `▾ Stashes` 列出 stash entries（`git stash list`）；點某 stash 在**主 table 頂部（Uncommitted Changes 下方）**顯示該 stash 為一筆 highlighted row，可展開看其 file 列表（`git stash show --numstat stash@{N}`）。不把 stash 混進 `git log` 主流（避免 ref 視覺混亂）。

**理由：** Stash 是「未 commit 的暫存草稿」，與 commit 性質不同；分離顯示避免誤解 stash 為一筆歷史 commit。

**替代：**
- `git log --all --glob='refs/stash*'` 混入主 graph — 視覺與語意都會誤導。
- 只做 sidebar list 不可展開 — 資訊量不足。

### Worktree 顯示：Refs sidebar list + branch badge icon 標示

**選擇：** 左 Refs sidebar `▾ Worktrees` 列出所有 worktree（`git worktree list --porcelain`）含 path + checkout 的 branch；主 table 的 branch ref badge 若該 branch 正被其他 worktree checkout，在 badge 附加 `⎘` icon 與 tooltip 顯示 worktree path。當前 panel 所在 worktree 以 `★` 標示。

**理由：** 使用者做 parallel agent 開發時，看到「這 branch 被誰佔了」是關鍵資訊；ref badge 就地標示比跳到 sidebar 查更直覺。

**替代：**
- 只做 sidebar list — 無法在主 graph 看出佔用關係。
- Dim/灰化被佔 branch 的 ref badge — 視覺上像「禁用」，語意不對。

### Commit detail 展開：inline row expansion，非 side panel

**選擇：** 點 commit row 在**該 row 下方內嵌展開**一塊區域，顯示 SHA / parents / author / committer / date / full message / file tree + numstat。再次點收合。最多允許一個展開 row。

**理由：** 主 panel 版面已是三欄（refs sidebar / main table / 可能的 detail），再切出第四塊 side panel 會過擠；inline 展開符合使用者截圖範式。

**替代：**
- 右側固定 detail panel — 浪費空間當沒選取時。
- 彈出 popover — detail 內容多、file tree 可能超過 popover 尺寸。

### File tree 呈現：樹狀階層 + 檔案節點 `+N / -M` 數字 + 點檔跳 terminal

**選擇：** `git show --numstat <sha>` 取得 `added\tdeleted\tpath`，按 `/` 拆分 path 建 tree；目錄節點顯示子檔總 +/-，檔案節點顯示該檔 +/-。點檔案節點會將 `git show <sha> -- <file>\n` 送往同一 workspace 中最近聚焦的 terminal panel（若無則開新 terminal panel）；點目錄節點只 toggle 展開/收合。不在 git graph panel 內實作 diff viewer。

**理由：**
- 不踩進 diff viewer 的坑（會變 VS Code 級工程）。
- 讓使用者在 cmux 內「看 diff」仍能一鍵達成，借力現有 terminal panel 即可（`git show` 是 less pager，可 scroll / search / quit）。
- 維持 read-only 精神：git graph panel 本身不產生 mutation，僅送「查看」指令給 terminal；terminal 裡使用者若自願跑其他 mutation 不受本 panel 約束。

**替代：**
- 扁平檔案 list — 大 commit 難讀。
- 點檔無反應 — UX 失望。
- 內嵌 diff preview — 工作量暴增、與 read-only MVP 衝突。

**注意：** Terminal dispatch 需取用 cmux 既有 socket / 內部 API（如 `surface.focus` + `sendKeys`），避免干擾 terminal 的 typing latency hot path；命令字串須 shell-escape `<file>` 路徑。

### Search：前端 fuzzy + 高亮為預設，可切換篩選模式

**選擇：** 使用者輸入字串後，對當前記憶體中的 commit list 做 case-insensitive 子字串比對（commit message + author name + SHA prefix）。UI 預設為 **highlight mode**：所有 row 仍可見，matching row 套用高亮背景並標記 orange 文字；自動 scroll 到第一筆 match。搜尋輸入旁提供 toggle 控件可切至 **filter mode**：非 match 的 row 從渲染列表中移除，graph lane 中因此產生的斷裂以虛線 placeholder 表示（避免視覺錯覺以為 branch 結構變了）。兩種模式皆不重跑 `git log --grep`，僅對記憶體 snapshot 過濾。Toggle 切換保留 query；清空 query 回到完整顯示。

**理由：** 記憶體 500 筆資料量搜尋 <1ms，即時反應。預設 highlight 保留 graph 連續性，符合 discuss 階段截圖的使用預期；保留 filter 作為進階選項讓使用者在 match 很少時能專注結果。

**替代：**
- 只 highlight 不提供 filter — 對 match 稀疏的情況使用者需手動 scroll
- 只 filter 不保留 lane placeholder — graph 結構看起來會被扭曲
- `git log --grep=<pattern>` — 需每次改 query 都 spawn 新 process，延遲高；且與 branch filter 組合會複雜

### Refresh 策略：三個觸發點，不做檔案監聽

**選擇：** 以下三個時機 refresh：（1）使用者點 toolbar ⟳ 按鈕；（2）panel 從背景被 focus 時（timestamp > 30s 視為 stale）；（3）workspace 切換時自動重載。不監聽 `.git/HEAD` / `.git/refs/` 檔案變動。

**理由：** 檔案監聽要處理 symlink、worktree 共用 .git、FSEvents 延遲等 edge case，成本不低；cmux 使用者在另一個 terminal 跑 `git commit` 後會回 cmux（focus 觸發 refresh），已經夠用。

**替代：**
- FSEvents 監聽 `.git` — 過度工程
- 固定間隔 poll — 浪費 CPU、git command 頻繁 fork

### 本機 SSH 一致 API：`GitGraphProvider` 分 local / ssh 兩組 function，caller 根據 workspace 挑

**選擇：** Provider 內對每個 query 同時提供 `fetchFoo(directory:)` 與 `fetchFooSSH(directory:destination:port:identityFile:sshOptions:)` 兩支；caller（`GitGraphPanel` view model）依 workspace 類型選。

**理由：** 與 `GitStatusProvider` 同風格。SSH 路徑需 `cd '<dir>' && <git command>` 串接並在 stdout 用 `---SEP---` 分段，避免 escape 問題。

**替代：** 統一 `Runner` protocol 抽象 — 看似乾淨但 `GitStatusProvider` 沒這樣做，不值得重構。

### 遠端 git 缺失時的裝 git 流程

**選擇：** 當 SSH 遠端缺 git，panel 顯示錯誤狀態並彈對話框。使用者確認安裝時：
1. 探測 OS：執行 `uname -s` 取得 kernel name，再用 `command -v apt-get dnf apk brew` 偵測可用套件管理器
2. 分類：`Linux + apt-get` → Debian/Ubuntu、`Linux + dnf` → RHEL/Fedora/CentOS、`Linux + apk` → Alpine、`Darwin + brew` → macOS（Homebrew）
3. 檢查 sudo：非 macOS brew 情境需 `sudo -n true` 確認 passwordless sudo 可用；否則失敗
4. 執行安裝指令（以 `&&` 串 sudo 用法）：
   - Debian/Ubuntu：`sudo -n apt-get update && sudo -n apt-get install -y git`
   - RHEL/Fedora：`sudo -n dnf install -y git`
   - Alpine：`sudo -n apk add --no-cache git`
   - macOS：`brew install git`（不加 sudo）
5. 進度以 streaming stdout 顯示於對話框中的 log 區
6. 成功：自動 refresh；失敗：顯示 stderr tail（末 10 行）＋ 手動指令提示

**理由：**
- 使用者明確選擇有提示 + 可安裝流程
- 不猜測未偵測到的 OS，避免亂跑指令
- 強制需 passwordless sudo 避免 ssh 中互動輸入密碼的 UX 地雷
- 失敗總是 fallback 到手動指令，永不 corrupt 遠端狀態

**風險與緩解：**
- **[誤裝線上機]** 使用者未看清就按確認 → Mitigation: 對話框標題明寫 `<host>` 名稱 + 紅色底「This will modify the remote system」警語；confirm 按鈕需二次點擊
- **[OS 偵測誤判]** minor Linux 發行版（NixOS, Gentoo, Arch）無對應 manager → Mitigation: 走 unknown OS 路徑提示手動裝，不嘗試 workaround
- **[套件 repo 未更新]** `apt-get install` 可能失敗於 stale cache → Mitigation: Debian/Ubuntu 固定加 `apt-get update`；其他發行版若失敗回報 stderr 讓使用者自己處理
- **[網路離線]** 遠端無法接套件伺服器 → Mitigation: 依賴 stderr 顯示明確錯誤（exit code + tail），不擴大重試邏輯

**替代：**
- 僅顯錯不嘗試安裝 — 最安全但 UX 保守（使用者先選此案後改）
- 全自動安裝無確認 — 危險，可能在線上機誤動
- 支援更多 OS（freebsd / openbsd / nixos / arch） — scope 膨脹，現階段不做

### Panel 開啟入口：tab `+` 選單 + 快捷鍵，沿用 terminal 入口慣例

**選擇：** 修改 `Sources/cmuxApp.swift` 中現有的 tab 新增選單，加入「Git Graph」項目；於 `KeyboardShortcutSettings` 註冊 `openGitGraphPanel` 可自訂快捷鍵（預設不綁鍵）。

**理由：** 與現有 new-terminal / new-browser 一致，零學習成本。

**替代：** 右鍵選單只顯示 Git Graph — 發現性差。

### 在地化：全數進 xcstrings

**選擇：** 所有 UI label（欄位標題、空狀態文案、按鈕、toolbar tooltip、error message）以 `String(localized: "gitGraph.<key>", defaultValue: "...")` 包覆並寫入 `Resources/Localizable.xcstrings`，至少提供英/日/繁中三組。

**理由：** CLAUDE.md 明文規定。

## Risks / Trade-offs

- **[大 commit 的 numstat 可能慢]** 一筆 merge commit 可能影響 1000+ 檔案 → **Mitigation:** detail 展開改為非同步載入，UI 先顯示 spinner；若 `git show --numstat` 超過 2s 顯示「Too many files (N)」並附「Open in terminal」提示
- **[自繪 lane 在大量 branch 時渲染抖動]** ghostty 這種 multi-contributor repo merge 密集 → **Mitigation:** 以 commit SHA 當 `.id()` 穩定化，LazyVStack 重用 row；lane 分配結果緩存於 snapshot，panel 只負責繪製
- **[SSH 情境下 git 指令序列化輸出可能破格]** 尤其 commit message 含 tab / newline → **Mitigation:** `git log --format=` 使用 NUL 分隔（`%x00`）且整個 entry 以 `\x1e` (RS) 分隔，parser 以 byte 為單位切割，不用 line-based
- **[新增 panel 可能拖慢 main thread]** CLAUDE.md 的 typing latency 紅線 → **Mitigation:** 所有 git command 在 background queue 跑（`DispatchQueue.global`）；snapshot 建好後 `DispatchQueue.main.async` 推給 view；panel view body 不持有任何 `@Published` 鏈到 commit list 以外的大 object
- **[Panel session 持久化]** 使用者重啟 app 時 panel 要能恢復 → **Mitigation:** `GitGraphPanel` 序列化 workspace path + branch filter + scroll offset，不序列化 commit snapshot（重啟時重拉）
- **[快捷鍵衝突]** `openGitGraphPanel` 若預設綁鍵可能撞到使用者既有設定 → **Mitigation:** 預設不綁鍵，只列入 Settings 讓使用者自選
- **[Worktree 資訊過時]** 使用者在外部 `git worktree remove` 後 panel 未 refresh → **Mitigation:** refresh 策略同主 graph；worktree path 在 sidebar 加 stale 判斷（路徑不存在時灰化 + tooltip「path missing」）

## Migration Plan

此為新功能 panel，不影響既有 panel 行為，無 migration 需求。

部署策略：
1. Phase 1 merge 後對外提供基礎 graph（graph + lane + ref badges + Uncommitted Changes + HEAD 標示）
2. Phase 2 merge 後補 commit detail 展開
3. Refs sidebar + filter + search + stash + worktree 作為最後階段一次 merge

Rollback：各 Phase 獨立 PR，問題時 revert 對應 PR；`PanelType.gitGraph` 若未 merge 的 PR 會影響序列化，Phase 1 即確定 type enum 以避免反覆。

## Open Questions

- ~~Phase 1 載入的 500 筆是否需要可由使用者在 Settings 調整？或先硬編碼 500 待收集反饋？~~ — **已解決**：放入 Settings，key 為 `gitGraph.commitsPerLoad`，預設 500，範圍 100–2000，逾界夾制。已載入資料不立即截斷，下次 refresh 才套新值。
- ~~多 worktree 共用同一 repo 時，切換 panel 所屬 workspace 是否要保留 scroll 位置？~~ — **已解決**：panel session persistence 以 anchor commit SHA + sub-row pixel offset 儲存 scroll；重啟或 workspace 切回時嘗試定位同 SHA，找不到則回頂端。跨 worktree 情境下兩 panel 彼此獨立 persistence state。
- ~~SSH workspace 下若 remote 沒有 git CLI，panel 要顯示哪種錯誤訊息？是否提示使用者裝 git？~~ — **已解決**：顯示 `git not found on <host>` 錯誤並彈出對話框，使用者可選「Install git on <host>」或「Cancel」。選安裝時以 `uname -s` + 偵測 `apt`/`dnf`/`apk`/`brew` 分類遠端 OS，呼叫對應套件管理器（需 passwordless sudo 或非需 sudo 的 macOS/brew 情境才執行）；無 sudo / 未支援 OS / 安裝失敗時回退到錯誤狀態並給手動指令。使用者按 refresh 會重新探測。
