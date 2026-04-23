# Add Claude Session Stats to Workspace Sidebar

## Why

使用者在 cmux 多 workspace 的工作流裡，每個 workspace 的 terminal tab 幾乎都跑著 Claude Code。目前要看「某個 workspace 的 Claude session 用了多少 context、5h/7d quota 還剩多久 reset」只能切到那個 workspace、再盯 Claude Code 底部的 statusline。跨 workspace 比較（哪個 session 快爆 quota、哪個 context 快滿要 compact）完全沒有面板可看。Claude Code 其實每秒都會把 `context_window` / `rate_limits` 等結構化欄位透過 stdin JSON 推送給 `statusLine.command` — 這個通道本來就存在，cmux 只需要「接管」並把資料繞回 sidebar UI 即可。

## What Changes

- **新增 `cmux statusline` subcommand**：被 Claude Code 當作 statusLine command 呼叫；讀 stdin JSON + `$CMUX_SURFACE_ID`，透過 unix socket 把 `(surface_id, session_id, stats)` 送給 cmuxd；stdout 印空字串（讓 Claude Code UI 該行保持空）。
- **新增 `cmux record-compact` subcommand**：給 `PreCompact` hook 呼叫，每次 compact 事件在 cmuxd 端把該 session 的 compact 計數器加一。
- **新增 `ClaudeStatsStore`（SwiftUI ObservableObject）**：以 `surface_id` 為 key，儲存每個 tab 最近一次的 stats 快照 + compact count + 上次更新時間。過時（> 30s 沒更新）自動標為 stale。
- **新增 `Workspace.claudeStatsSnapshot` 聚合**：workspace 裡每個 tab 的 stats 聚合成「focused tab 的 full stats + 其他 tab 的 max quota」兩個面向，供 sidebar row 顯示。
- **修改 sidebar row UI**：
  - Selected (focused) workspace：在既有 branch / cwd 下方加一塊 stats 區，依序顯示 `tokens` 合計與本 session、`ctx` 進度條 + compact count、`5h` 進度條 + reset 倒數、`7d` 進度條 + reset 倒數。
  - Unfocused workspace：若該 workspace 有活著的 Claude session，在 row 最底多一行 monospace inline `ctx X% · 5h X% · 7d X%`；沒有 session 則什麼都不顯示。
- **Theme-aware palette**：bar 顏色、文字色、divider 全部從現有 `GhosttyConfig` palette 推導（blue = ansi4、warn yellow = ansi3、danger red = ansi1），跟既有 `GitGraphTheme` 用同一個 notification `com.cmuxterm.themes.reload-config` 重新計算。切 ghostty theme → sidebar 自動跟著換色。
- **新增 `SidebarClaudeStatsSettings` toggle**：Debug menu + `~/.config/cmux/settings.json` 裡新增一個 `sidebar.showClaudeStats` 布林（預設 true），關掉後 sidebar row 完全不顯示 stats 區（維持現狀外觀）。
- **設定檔輔助**：首次安裝後 cmuxd 偵測到 `~/.claude/settings.json` 沒有把 `statusLine.command` 指向 `cmux statusline`，在 sidebar stats 區顯示一次性引導卡片（「尚未連接 Claude Code — 點此自動寫入設定」），按下後以 atomic replace 更新該 JSON 檔（帶備份），不強制也不自動寫。
- i18n：新增約 15 個 en / ja / zh-Hant 字串（stats 標籤、bar label、empty state、setup 引導）。

## Non-Goals

- **Session 外的 cumulative token / cost**：`tokens 4.7M` 這種跨 session 的「整個裝置使用者累積」數字先不算；僅顯示 `context_window.total_input_tokens + total_output_tokens`（即「本 session 累積」）。累計數字要自行 disk-persist 的部分延後。
- **非 Claude Code 的 agent**：只支援 Claude Code。Codex、Gemini CLI 之類不在這次 scope。
- **歷史圖表 / trend**：本次只做「當下 snapshot」，不畫 quota 歷史曲線。
- **Free user**：`rate_limits` 欄位在 free 帳號沒有，對 free user 只顯示 `ctx` 一列 + compact count；5h / 7d 直接不繪。
- **自動改使用者 `~/.claude/settings.json`**：除了使用者主動按下 setup 按鈕以外，cmux 絕不改這個檔。
- **SSH workspace**：SSH 遠端 workspace 的 Claude session 不在 scope（遠端 tab 的 hook / socket 通道要另外設計），這次僅 local workspace。
- **Free user quota 自行估算**：free user 沒有 `rate_limits` 也不去爬 Anthropic API 估用量。

## Capabilities

### New Capabilities

- `claude-statusline-ingest`: 接收 Claude Code statusline tick 的 stdin JSON，解出 session_id / surface_id / context / rate_limits，轉存到 cmuxd 內部 store。
- `claude-compact-tracking`: 透過 PreCompact hook 累加每個 session 的 compact 次數。
- `claude-stats-sidebar`: sidebar workspace row 顯示 Claude session stats（focused 為 full bars，unfocused 為 inline 文字），theme-aware，可 toggle on/off。
- `claude-statusline-setup`: 偵測使用者 `~/.claude/settings.json` 未連接 cmux statusline 時，提供一次性引導與 opt-in 自動寫入。

### Modified Capabilities

(none — 這次 change 全為新增能力)

## Impact

- **Affected specs**:
  - 新增 `specs/claude-statusline-ingest/spec.md`
  - 新增 `specs/claude-compact-tracking/spec.md`
  - 新增 `specs/claude-stats-sidebar/spec.md`
  - 新增 `specs/claude-statusline-setup/spec.md`

- **Affected code** (預計):
  - 新增 `Sources/cmux-cli/StatuslineCommand.swift`（或直接加在 `cmux.swift` 裡新 subcommand）— 實作 `cmux statusline` 和 `cmux record-compact`。
  - 新增 `Sources/ClaudeStatsStore.swift`（`@MainActor ObservableObject`，per-tab snapshot + staleness）。
  - 新增 `Sources/ClaudeStatsTheme.swift`（從 `GhosttyConfig` 推派色盤，mirror `GitGraphTheme` 結構）。
  - 新增 `Sources/Sidebar/ClaudeStatsBlockView.swift`（selected row 的 full stats 區）。
  - 新增 `Sources/Sidebar/ClaudeStatsInlineView.swift`（unfocused row 的 inline 一行）。
  - 新增 `Sources/Sidebar/ClaudeStatsSetupCardView.swift`（尚未連接 Claude Code 引導卡）。
  - 修改 `Sources/TerminalController.swift` 或新增 socket route — cmuxd 端接收 `claude.statusline` / `claude.compact` 訊息並寫 `ClaudeStatsStore`。
  - 修改 `Sources/TabManager.swift` — 暴露 `CMUX_SURFACE_ID` 給子 shell（若目前沒有就加上），以及 `claudeStatsStore` 聚合查詢。
  - 修改 `Sources/ContentView.swift`（sidebar workspace row 布局）— 按 selected / unfocused 分支渲染 stats。
  - 修改 `Sources/SocketControlSettings.swift` 或相似位置 — 新增 `sidebar.showClaudeStats` 設定鍵（Debug menu 與 `settings.json` 同步）。
  - 修改 `Resources/Localizable.xcstrings` — 新增 ~15 個 en / ja / zh-Hant 翻譯。
  - 修改 `GhosttyTabs.xcodeproj/project.pbxproj` — 登錄新的 Swift 檔。
  - 新增測試：`cmuxTests/StatuslineIngestTests.swift`（JSON parse + store update）、`cmuxTests/ClaudeStatsQuotaFormattingTests.swift`（倒數與百分比 formatter）、`cmuxTests/ClaudeStatsThemeTests.swift`（palette 推派）。

- **Dependencies**: 無新增套件。socket 通道沿用 cmuxd 現有 unix socket；JSON parse 用 Foundation `JSONDecoder`；file watcher 沿用 `DispatchSource`。
