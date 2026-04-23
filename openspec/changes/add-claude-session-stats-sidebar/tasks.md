# Tasks — Add Claude Session Stats to Workspace Sidebar

## 1. CLI subcommands + socket 骨架（decisions：「主要資料來源走 statusLine command...」「`cmux statusline` subcommand 印空 stdout」「Tab 綁定靠 `$CMUX_SURFACE_ID`」「cmuxd socket protocol：單向 append, version-tagged」）

- [x] 1.1 於 `Sources/cmux-cli/` 新增 `StatuslineCommand.swift`，實作 `cmux statusline` subcommand：讀 stdin JSON、讀 `ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]`、包成 `{"cmd":"claude.statusline","v":1,"surface_id":...,"session_id":...,"at":<epoch>,"payload":{...}}` 單行寫入 cmuxd unix socket、stdout 印空字串、exit 0；對應 spec `claude-statusline-ingest` 的 `cmux statusline` subcommand as Claude Code statusLine command / Tab binding via CMUX_SURFACE_ID environment variable。
- [x] 1.2 在同檔 / 共用 helper 實作 `cmux record-compact` subcommand：讀 stdin JSON（Claude 的 hook envelope）、取 `session_id`、送 `{"cmd":"claude.compact","v":1,"session_id":...}` 到 cmuxd socket、exit 0；對應 spec `claude-compact-tracking` 的 `cmux record-compact` subcommand as PreCompact hook。
- [x] 1.3 兩個 subcommand 皆在 stdin JSON malformed / `CMUX_SURFACE_ID` 缺失 / socket 不存在時保持 exit 0 不 crash（對應 spec 的 Malformed / Missing / Unavailable scenario，以及 decision「Socket transport is single-writer and fire-and-forget」）。
- [x] 1.4 在 cmuxd 端（`Sources/TerminalController.swift` 或新檔 `Sources/ClaudeStatsSocketRoute.swift`）增加 socket route：parse `cmd == "claude.statusline"` 與 `cmd == "claude.compact"`；忽略 `v` > 已知最大版（對應 spec `claude-statusline-ingest` 的 Unknown `v` version in message）。
- [x] 1.5 調整 `Sources/TabManager.swift`（或 Workspace 建 terminal 時的 env 注入點）確認每個 terminal tab 的子 shell 有 `CMUX_SURFACE_ID=<uuid>` 與 `CMUX_SOCKET=<absolute-socket-path>`；Release build 指向 Release socket，tagged Debug build 指向 `/tmp/cmux-debug-<tag>.sock`（對應 spec `claude-statusline-ingest` 的 Socket and tab binding via environment variables 與 Release and Debug cmux apps coexist scenario）。

## 2. ClaudeStatsStore：per-tab snapshot + staleness + compact counter（decisions：「ClaudeStatsStore：per-tab + staleness + compact counter」「Compact 計數持久化」）

- [x] 2.1 新增 `Sources/ClaudeStatsStore.swift`：`@MainActor final class ClaudeStatsStore: ObservableObject`，含 `@Published snapshots: [UUID: ClaudeStatsSnapshot]`、`@Published compactCountsBySession: [String: Int]`；value struct 欄位依 spec `claude-statusline-ingest` 的 cmuxd ingest updates ClaudeStatsStore per tab 要求。
- [x] 2.2 `ClaudeStatsSnapshot.isStale: Bool` 依 `receivedAt` 是否超過 30 秒計算（對應 spec `claude-statusline-ingest` 的 Staleness flag on per-tab snapshots 與 decision「staleness」）。
- [x] 2.3 store 接到 socket route 的新 payload 時用寬鬆 `JSONDecoder`（decode 失敗欄位留 nil）：對應 spec `claude-statusline-ingest` 的 Schema tolerance for Claude Code version drift。
- [x] 2.4 `ClaudeStatsStore.incrementCompact(sessionId:)` 實作並暴露 `compactCount(for:)` accessor（對應 spec `claude-compact-tracking` 的 Per-session compact counter in cmuxd）。
- [x] 2.5 **Counter persistence across cmux app restarts**：載入 `~/Library/Application Support/cmux/claude-compact-count.json`（啟動時 read；missing → 空；舊 flat-dict 格式 migrate 為 `{entries, version}` 並補 `lastSeen = now`）；`incrementCompact` 同時更新 `lastSeen`；10 秒 debounce atomic write；I/O 失敗保留 in-memory 值；對應 spec `claude-compact-tracking` 的 Counter persistence across cmux app restarts 與 Compact count write fails 以及 decision「Compact 計數持久化（含 LRU 上限）」。
- [x] 2.5b **LRU prune at 500 entries**：每次 debounced flush 前若 entries > 500，依 `lastSeen` ascending 剔到剛好 500；對應 spec `claude-compact-tracking` 的 LRU prune at 500 entries。
- [ ] 2.6 `ClaudeStatsStore` 的 snapshot update 用 `debounce(0.05 s)` coalesce 同 tick 多個 update（對應 design risks 的 trade-off「每個 statusline tick 觸發 @Published」）。
- [x] 2.7 測試 `cmuxTests/StatuslineIngestTests.swift`：fixture JSON（含 rate_limits / 無 rate_limits / 含未知欄位 / malformed），驗 store 狀態正確；對應 spec `claude-statusline-ingest` 的 Valid statusline message / Schema tolerance。
- [x] 2.8 測試 `cmuxTests/ClaudeCompactCounterTests.swift`：多次 compact 累加、`/resume` 換 session 後 count 從 0 起、重啟後 persisted count 載回（對應 spec `claude-compact-tracking` 全部 scenarios，以及 decision「Counter is per-session, not per-tab」）。

## 3. Theme palette + formatter（decisions：「Theme color mapping」）

- [x] 3.1 新增 `Sources/ClaudeStatsTheme.swift`：mirror `GitGraphTheme` 結構，從 `GhosttyConfig` 派生 `background` / `foreground` / `selection` / `barDefault` / `barWarn` / `barDanger` / `divider` / `dim` / `faint`；全部在 `@State` 快取並訂閱 `com.cmuxterm.themes.reload-config`；對應 spec `claude-stats-sidebar` 的 Theme tracks ghostty config in real time 與 Color thresholds derived from ghostty palette。
- [x] 3.2 `thresholdColor(for percentage:)` helper：`< 60` → barDefault、`60–84` → barWarn、`≥ 85` → barDanger；對應 spec 的 Color thresholds derived from ghostty palette scenarios。
- [x] 3.3 新增 `Sources/ClaudeStatsFormatter.swift`：`formatTokens(_:)`（K / M 縮寫）、`formatResetRemaining(unixEpoch:)`（小於 24 h → `HhMm`，≥ 24 h → `DdHh`）、`formatPercent(_:)`（四捨五入）；對應 spec `claude-stats-sidebar` 的 Full stats block on focused workspace row 的 formatter 需求。
- [x] 3.4 測試 `cmuxTests/ClaudeStatsThemeTests.swift`：給 3 個 ghostty palette fixture（monokai / solarized-dark / github-light）驗輸出 color；對應 decision「Theme color mapping」。
- [x] 3.5 測試 `cmuxTests/ClaudeStatsFormatterTests.swift`：token 縮寫（123 / 1.2K / 1.8M）、倒數（40 min / 1 d 19 h）、百分比四捨五入（28.4 → 28, 28.6 → 29）。

## 4. Sidebar UI（decisions：「Sidebar 分三種 render mode：none / inline / full」「`sidebar.showClaudeStats` 設定鍵」）

- [x] 4.1 新增 `Sources/Sidebar/ClaudeStatsBlockView.swift`：full stats 區 subview，接值 snapshot（不持 store 參照）+ closure action bundle；渲染 tokens 行、ctx bar + compact count、5h bar + reset、7d bar + reset；對應 spec `claude-stats-sidebar` 的 Full stats block on focused workspace row 與 Snapshot-boundary compliance for sidebar rows。
- [x] 4.2 新增 `Sources/Sidebar/ClaudeStatsInlineView.swift`：unfocused inline 行，接聚合 value snapshot；對應 spec 的 Inline stats on unfocused workspace rows（含兩 tab max 聚合）與 Snapshot-boundary compliance for sidebar rows。
- [x] 4.3 在 `Sources/Workspace.swift` 或新增 helper `Workspace.claudeStatsSnapshot(for mode:)` 做聚合：focused → focused tab 的單一 snapshot；unfocused → 所有 tab 取 max（對應 decision「Sidebar 分三種 render mode」）。
- [x] 4.4 修改 `Sources/ContentView.swift` sidebar 的 workspace row 布局：在既有 meta 行下方依 `sidebar.showClaudeStats` + snapshot 存在與否 + focused flag 選擇 none / inline / full 三種 render（對應 spec `claude-stats-sidebar` 的 Full stats block... / Inline stats on unfocused workspace rows / Focused workspace with no Claude session / Unfocused workspace with no session / Feature toggle hides the entire stats UI）。
- [x] 4.5 **Stale snapshot rendering**：stats block 與 inline row 都要依 `isStale` 整塊 dim + 右下角加 `(stale)` 字尾；對應 spec 的 Stale snapshot rendering。
- [x] 4.6 **Free-tier user state**：偵測 `rateLimits == nil` 時隱藏 5h / 7d 行並顯示 `No quota data (Claude.ai free)` 一行 hint；對應 spec `claude-stats-sidebar` 的 Free-tier user state。
- [x] 4.7 測試 `cmuxTests/ClaudeStatsAggregatorTests.swift`：workspace 聚合 focused / unfocused 的輸出；對應 decision「Sidebar 分三種 render mode：none / inline / full」。

## 5. 設定鍵 + Debug menu（decision：「`sidebar.showClaudeStats` 設定鍵」）

- [x] 5.1 在 `Sources/SocketControlSettings.swift`（或合適的 settings 檔）新增 `sidebar.showClaudeStats` key（預設 `true`）；同步 `@AppStorage` 與 `~/.config/cmux/settings.json`；對應 spec `claude-stats-sidebar` 的 Feature toggle hides the entire stats UI。
- [x] 5.2 Debug menu（`Sources/cmuxApp.swift` 的 Debug Windows 或直接 checkbox）新增 `Sidebar › Show Claude Stats` 勾選項，bind 到同一個 `@AppStorage`。
- [ ] 5.3 測試 `cmuxTests/SidebarClaudeStatsToggleTests.swift`：toggle false 時 `ContentView` 的 sidebar row render path 不包含 stats subview（driven via injected `showClaudeStats` boolean）。

## 6. Setup card（decisions：「Setup 引導：只偵測、不自動寫」）

- [x] 6.1 新增 `Sources/ClaudeSettingsInspector.swift`：`classifyConnectionStatus()` 回傳 `.connected / .disconnected / .fileMissing`，依 spec `claude-statusline-setup` 的 Detect whether cmux statusline is wired into Claude Code 判斷（支援 `cmux statusline`、`cmux-dev statusline`、絕對路徑指向 cmux CLI 的三種 connected pattern）。
- [x] 6.2 新增 `Sources/Sidebar/ClaudeStatsSetupCardView.swift`：三顆按鈕 `Auto-configure` / `I'll edit it myself` / `Don't show again`；對應 spec 的 Sidebar setup card on the focused workspace row（含 dismiss 永久化到 `sidebar.claudeSetupCardDismissed`）。
- [x] 6.3 `ClaudeSettingsInspector.autoConfigureAtomic()`：backup 到 `~/.claude/settings.json.bak`、讀回 JSON、merge `statusLine = {type:"command", command:"cmux statusline"}`（tagged dev build 改用 `cmux-dev statusline`）、atomic replace；對應 spec `claude-statusline-setup` 的 Atomic auto-configure writes with backup 與 Setup card behavior on dev (tagged) cmux builds。
- [x] 6.4 `autoConfigureAtomic()` 同時 append `hooks.PreCompact` 一個 `cmux record-compact` entry（已存在則不重複）；對應 spec 的 PreCompact hook is written alongside auto-configure。
- [x] 6.5 atomic write 失敗時 UI 顯示 inline 錯誤訊息且不 dismiss 卡片；對應 spec `claude-statusline-setup` 的 Atomic write fails scenario。
- [x] 6.6 Setup card 在 `connected` 狀態完全不顯示；dismissed 後不再出現（對應 spec 對應 scenarios 與 Non-goals「自動改使用者 `~/.claude/settings.json`」）。
- [x] 6.7 測試 `cmuxTests/ClaudeSettingsInspectorTests.swift`：三種 classify case、auto-configure 對空檔 / 有 `autoAcceptEdits` / 有不同 `statusLine` 的 merge 結果、backup 檔存在、PreCompact hook 不重複；對應 spec `claude-statusline-setup` 大部分 scenarios。

## 7. i18n、pbxproj、build 與驗證

- [x] 7.1 在 `Resources/Localizable.xcstrings` 新增以下 key 的 en / ja / zh-Hant 翻譯：`sidebar.claudeStats.tokens`、`sidebar.claudeStats.session`、`sidebar.claudeStats.ctx`、`sidebar.claudeStats.ctx.compactSuffix`、`sidebar.claudeStats.fiveHour`、`sidebar.claudeStats.sevenDay`、`sidebar.claudeStats.reset.hhmm` (帶 `%@`)、`sidebar.claudeStats.reset.ddhh` (帶 `%@`)、`sidebar.claudeStats.stale`、`sidebar.claudeStats.freeTier.noQuota`、`sidebar.claudeStats.setup.title`、`sidebar.claudeStats.setup.autoConfigure`、`sidebar.claudeStats.setup.manual`、`sidebar.claudeStats.setup.dismiss`、`sidebar.claudeStats.setup.writeFailed`（對應 spec `claude-stats-sidebar` + `claude-statusline-setup` 所有 user-facing 字串）。
- [x] 7.2 更新 `GhosttyTabs.xcodeproj/project.pbxproj`：為 `ClaudeStatsStore.swift`、`ClaudeStatsTheme.swift`、`ClaudeStatsFormatter.swift`、`ClaudeSettingsInspector.swift`、`ClaudeStatsBlockView.swift`、`ClaudeStatsInlineView.swift`、`ClaudeStatsSetupCardView.swift`、`StatuslineCommand.swift`、`ClaudeStatsSocketRoute.swift`（若分檔）和所有新測試檔加入 PBXBuildFile / PBXFileReference / PBXGroup / PBXSourcesBuildPhase；使用 `CA5E0001..` 風格 hex UUID 避免衝突。
- [x] 7.3 `CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -configuration Debug -derivedDataPath /tmp/cmux-ccs build` 全專案 compile 通過，無 warning。
- [x] 7.4 `CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux-unit -configuration Debug -derivedDataPath /tmp/cmux-ccs-test build` 測試 target compile 通過（tests 交 CI 跑，依專案 policy 不在本地 run）。
- [x] 7.5 `./scripts/reload.sh --tag ccs` 成功 build Debug app，手動按 setup card「Auto-configure」確認：`~/.claude/settings.json.bak` 被建、新 `settings.json` 含 `statusLine.command` 與 `hooks.PreCompact`；Cmd-click sidebar row 看到 stats 依 theme 換色（切幾個 ghostty theme 驗證）。
- [ ] 7.6 對 sidebar 在 30 個 tab + 全開 Claude 狀態做一次 `sample(1)`，確認未引入新的 main-thread 熱點（對應 CLAUDE.md 的 typing-latency-sensitive paths 與 snapshot boundary 守則）。
