## Context

Claude Code 2.1.90+ 提供 `statusLine.command` 機制：設定後，Claude Code 會在每個可能影響 status 的事件（新 assistant message、權限模式變更、vim mode 變更）後，將整個 session 的結構化資料透過 **stdin JSON** 推送給該 command，300 ms debounce，可選 `refreshInterval` 輪詢（≥ 1 秒）。這支 command 的 stdout 會被 Claude Code 當成 UI status row。

stdin JSON 包含完整 session 狀態：`cwd`、`session_id`、`transcript_path`、`model`（id + display_name）、`workspace`、`version`、`cost`、`context_window`（含 `total_input_tokens` / `total_output_tokens` / `context_window_size` / `used_percentage` / `current_usage`）、`exceeds_200k_tokens`、`rate_limits`（`five_hour` / `seven_day` 各有 `used_percentage` + `resets_at` unix epoch）、`output_style`、`vim`、`agent`、`worktree`。Free user 沒有 `rate_limits`；首次 API call 前 `current_usage` 為 `null`。**唯一不在 stdin JSON 裡的是 compact 計數**，需自行透過 `PreCompact` hook 累加。

cmux 目前已有：
- `GhosttyConfig` 供給所有面板的 palette（`backgroundColor` / `foregroundColor` / `palette[0..15]`）。
- `GitGraphTheme.make(from: GhosttyConfig)` 示範了如何從 ghostty 主題派生面板色盤、並在 `com.cmuxterm.themes.reload-config` notification 觸發時重算。
- cmuxd unix socket（`/tmp/cmux-debug-<tag>.sock`）供 CLI 傳訊息給主 app。
- 每個 terminal tab 有 `CMUX_SURFACE_ID` env var 傳進子 shell（Claude Code 子 process 會繼承）。

Sidebar 目前在 `Sources/ContentView.swift` 內用 `LazyVStack` + per-row value snapshot 渲染 workspace 列（CLAUDE.md 的 snapshot boundary 守則適用）。

## Goals / Non-Goals

**Goals:**
- 提供每個 workspace 的 Claude session stats 快速一覽，focused workspace 看完整 bars、其他 workspace 看一行 inline 數字。
- 所有顏色、字型、dim 階層從當前 ghostty 主題派生；切 theme 時 sidebar 自動跟著換色。
- 使用者可在 Debug menu 或 `~/.config/cmux/settings.json` 整條 feature 關掉，維持現狀外觀。
- 第一次安裝後不強制改動 `~/.claude/settings.json`，提供引導 UI 按下後才寫入（含備份）。
- compact 計數正確累計，session `/resume` 後依然延續。

**Non-Goals:**
- 跨 session cumulative token（要 disk-persist aggregator，延後）。
- Codex / Gemini / 其他 agent，只支援 Claude Code。
- quota 歷史圖表 / trend line（只呈現當下 snapshot）。
- SSH workspace 的遠端 Claude session（遠端 socket 通道另開 change）。
- Free user 的 quota 自行估算。

## Decisions

### 主要資料來源走 statusLine command，compact 走 PreCompact hook

選 **hybrid**：context / tokens / 5h / 7d 全部從 statusLine 的 stdin JSON 拉；compact count 另外用 `PreCompact` hook。

- 理由：statusLine stdin JSON 已經包含所有展示欄位，cmux 不需要自己 parse transcript JSONL 或爬 `~/.claude/` 內部檔（Claude 版本升級時減少漂移）。
- compact 事件 stdin JSON 裡沒有，只能靠 hook；`PreCompact` 每次 compact 前觸發，語義穩定。
- 否決 (B) 被動讀 `~/.claude/projects/<escaped-cwd>/<session-id>.jsonl`：transcript 格式可能更動，且要自己算 context/rate_limits 太重。
- 否決 (C) ANSI 解析 terminal output：fragile。

### `cmux statusline` subcommand 印空 stdout

選 **subcommand stdout 永遠印空字串**，讓 Claude Code 底部該行留白。

- 理由：cmux 把 sidebar 當作主要 status UI，不希望 Claude 底部再重複顯示。若使用者仍想看 Claude 原生 statusline，可在 cmux 設定關掉 `sidebar.showClaudeStats` 並把 `statusLine.command` 指回 cc-statusline。
- 備選：印一行極簡 echo，已拒絕，因為會讓 CLI 底部冗餘。

### Tab 與 socket 綁定都靠 env var（`CMUX_SURFACE_ID` + `CMUX_SOCKET`）

選 **兩個 env var 一起走**：
- `CMUX_SURFACE_ID`（已有 / 要補）識別 tab。
- `CMUX_SOCKET` 明確指向「擁有這個 tab 的 cmuxd」的 unix socket 路徑；tagged Debug build 設 `/tmp/cmux-debug-<tag>.sock`，Release build 設自己的 Release socket 路徑。

這讓 Release 和 Debug（各種 tag）app 完全可以共存：每個 tab 的 shell env 由建立它的 app 注入，`cmux statusline` subcommand 只要忠實讀兩個 env 就會正確對應。

- 理由：Claude Code 子 process 繼承 shell env，naturally；subcommand 完全不需要猜 socket 或讀 `/tmp/cmux-last-*` 之類的 runtime file。
- Fallback：env 缺任一個 → subcommand 直接 exit 0，什麼都不送（spec `claude-statusline-ingest` 明載）；cmuxd 端對 `surface_id == null` 的訊息也 drop。
- 否決「遍歷 `/tmp/cmux-*.sock` broadcast」：寫多份、交叉污染 workspace 風險、除錯地獄。
- 否決「依 `/tmp/cmux-last-debug-log-path` 推 socket」：那檔只代表「最後一次 reload 是誰」，跟 tab ownership 沒語意關聯。

### cmuxd socket protocol：單向 append，version-tagged

- 定義兩條 JSON 單行訊息（以現有 debug socket 為傳輸層）：
  ```
  {"cmd":"claude.statusline","v":1,"surface_id":"...","session_id":"...","at":1745300000.123,"payload":{...stdinJSON...}}
  {"cmd":"claude.compact","v":1,"surface_id":"...","session_id":"...","at":1745300000.456}
  ```
- cmuxd 端寫到 `ClaudeStatsStore`，不 ack（single-writer，fire-and-forget）。
- 理由：避免 sync call block statusline subcommand（Claude Code 會把該 tick 的 spawn time 計入 UI latency）。
- 否決 RPC with ack：statusline 每秒都會來，額外 round-trip 沒價值。

### ClaudeStatsStore：per-tab + staleness + compact counter

- key 是 `surface_id: UUID`。
- value 是 `struct ClaudeStatsSnapshot { sessionId, receivedAt, model, contextWindow, rateLimits, totalInputTokens, totalOutputTokens, isCurrentUsageNull, exceeds200kTokens }` + 獨立的 `compactCount: Int` by `sessionId`（compact 是 session scope，tab 可以 `/resume` 換 session）。
- staleness：若 `receivedAt` 超過 30 秒沒更新，store 回傳 `isStale = true`，UI 以暗化色顯示並在右下角加小字 `stale`。
- 這樣 store 本身不依賴 file watcher，也不假設 Claude Code 還活著，tab 關掉 / Claude crash 後 UI 自然變暗。
- 否決「讀 transcript mtime 判斷是否活著」：額外 fs IO、語義不清；receivedAt timeout 就夠。

### Sidebar 分三種 render mode：none / inline / full

每個 workspace row 基於以下決策樹挑一種：

```
has_active_claude_session(workspace) && sidebar.showClaudeStats
├─ workspace == focused  → full stats block（tokens / ctx / 5h / 7d bars）
├─ workspace != focused  → inline 單行（ctx X% · 5h X% · 7d X%）
└─ (否則)               → 什麼都不加
```

- 聚合規則（workspace 內多 tab）：
  - focused workspace 的 full block → 走 `workspace.focusedTab` 的 stats；無活著 Claude session 則顯示「本 workspace 有 tab 但還沒跑 Claude」的空狀態文字（一次性、不顯示 setup card）。
  - unfocused workspace 的 inline → 該 workspace 內所有活 Claude session 的 **max** quota + context（讓使用者看到最吃 quota 的那個）。
- 理由：unfocused 用 max 而非 focused tab 數字，因為 workspace 在 unfocused 狀態下根本沒有「focused tab」的概念；使用者最關心的是 quota 會不會爆。
- 否決「聚合成平均」：平均會模糊掉快爆的單點。

### Theme color mapping

| UI token | 來源 | 備註 |
| --- | --- | --- |
| sidebar bg | `GhosttyConfig.backgroundColor` | 同 terminal 底色 |
| selected row | `config.selectionBackground` blend 70 % over bg | 承襲 tint 行為 |
| bar default (`ctx`, quota < 60 %) | `palette[4]` (ansi blue) | 後備：bg.lighten/darken 判斷 |
| bar warn (60–85 %) | `palette[3]` (ansi yellow) | |
| bar danger (≥ 85 %) | `palette[1]` (ansi red) | |
| divider | fg blend 14 % | 對應 GitGraphTheme |
| fg-dim / fg-faint | fg × 72 % / 32 % blend over bg | 同 GitGraphTheme |
| stale 警示色 | fg × 40 % blend over bg | 與 faint 一致，加 `(stale)` 文字 |

- 透過 cache 在 `@State var palette: ClaudeStatsPalette` + 訂閱 `com.cmuxterm.themes.reload-config` 重算，避免每 row body 重算 ColorSync（踩過的雷，見 CLAUDE.md「Never derive theme palettes as computed properties」）。

### `sidebar.showClaudeStats` 設定鍵

- Debug menu 新增一個 checkbox；同時映射 `~/.config/cmux/settings.json` 的 `sidebar.showClaudeStats` (bool, default true)；這兩邊共用一個 `@AppStorage("sidebar.showClaudeStats")`。
- 關掉後 sidebar row 維持現狀（沒有 stats 區），但 `cmux statusline` 和 cmuxd store 還是照常接資料（避免使用者打開設定時要等好幾秒才看到資料）。
- 否決「關掉就不接 socket」：開關要瞬間生效；接收開銷本來就極低。

### Setup 引導：只偵測、不自動寫

- cmuxd 啟動時 check `~/.claude/settings.json` 內 `statusLine.command`，若不是 `cmux statusline` / `cmux-dev statusline`（支援 tagged dev build）就在 `ClaudeStatsStore.isConnected == false`。
- UI 在 focused workspace 的 stats 區顯示引導 card：「尚未連接 Claude Code · [自動寫入] [我自己改] [不再提示]」。
- 使用者按「自動寫入」才走 atomic replace + `.bak` 備份 + 驗證新 JSON 可讀回。
- 否決「首次啟動直接寫」：使用者的 `~/.claude/settings.json` 可能已有 `statusLine`（例如接到 cc-statusline 或自家 script），不該靜默覆寫。

### Compact 計數持久化（含 LRU 上限）

- compact count 寫到 `~/Library/Application Support/cmux/claude-compact-count.json`；格式為 `{"version":1,"entries":{"<session_id>":{"count":N,"lastSeen":<epoch>}}}`。
- cmuxd 啟動時讀檔；`claude.compact` 訊息進來時更新 in-memory map（含 touch `lastSeen`）+ 10 秒 debounce flush。
- **LRU 上限 500 筆**：flush 前若 entry 數 > 500，依 `lastSeen` 由舊到新剔到剛好 500 筆。上限靠實測足以覆蓋 6–12 個月常用 session，檔案體積 < 50 KB。
- 向後相容：舊版 flat `{session_id: count}` 檔案 load 時自動遷移，為每個 entry 補 `lastSeen = now`。
- 否決「只留 in-memory」：cmux 重啟後 `/resume` 同一 session 會看到 compact count=0 變誤導。
- 否決「依時間 90 天 prune」：重要但少用的 session 會被意外剝掉。

## Risks / Trade-offs

- [Risk] 使用者本來把 `statusLine.command` 接給 cc-statusline 或自家 script，我們引導他切換到 `cmux statusline` 會讓他失去 Claude 原生 statusline 顯示。→ Mitigation: setup card 的「自動寫入」會先備份為 `~/.claude/settings.json.bak`，並在卡片上明示「你的 Claude 底部 statusline 會變空白，可在 cmux 設定關掉本功能改回原本指令」。
- [Risk] statusLine command 被 spawn 的頻率很高（每個事件 + 1 s refreshInterval），process fork 成本累積。→ Mitigation: subcommand 只做 stdin → socket 一次丟包，實測 < 5 ms；若發現效能問題可改用 long-running 模式搭配 lockfile，但 v1 先用 fork-per-tick 的單純路線。
- [Risk] cmux DEV（tagged build）和 Release 安裝共存時，使用者的 `~/.claude/settings.json` 只能指向一個 `cmux statusline`，另一邊會收不到資料。→ Mitigation: `cmux statusline` 使用固定 socket 名 `/tmp/cmux-debug-<tag>.sock`（已有），但 `$CMUX_SURFACE_ID` 是由 run time app 設的 env，tag 不同的 app 會設不同值 → 實務上只有當下 foreground 那個 app 對應的 terminal 會有正確 `CMUX_SURFACE_ID`，其他 app 收到訊息會因為 surface_id 找不到而 drop。這是接受的行為。文件裡明講。
- [Risk] Claude Code 升級後 stdin JSON schema 漂移（新增/改名欄位）。→ Mitigation: ingest 使用寬鬆 `JSONDecoder` + 個別欄位 optional decoding，任何 decode 失敗不整個 drop，只把該欄位留 nil；加一個 `StatuslineIngestTests` 以固定 JSON fixture 防回歸。
- [Risk] Free user 看不到 `rate_limits` 會以為 feature 壞掉。→ Mitigation: 偵測 `rate_limits` missing 時 UI 顯示「無 quota 資料（Claude.ai free）」一次性 hint，不顯示 5h/7d bar。
- [Risk] workspace 內多 tab 各自跑不同 Claude session，max-quota 聚合可能讓使用者誤會「focused tab 自己還很低就安心」。→ Mitigation: inline 行左側加 `↑` 符號或極小的 `max` 標籤，hover tooltip 註明「該 workspace 內所有 Claude session 的最大值」。
- [Trade-off] 每個 statusline tick 觸發一次 socket write + 一次 `@Published` 更新；若 30 個 tab 各開 Claude，每秒最多 30 次 store 變動。→ Mitigation: store 內用 `debounce(0.05 s)` 合併同 tick 的多個更新；UI 端仍遵守 CLAUDE.md 的 snapshot boundary（sidebar row 接收 value snapshot，不持有 store 引用）。

## Migration Plan

此 change 全為新增能力，無現存行為變動：
- 不需 schema 遷移。
- 不動 `~/.claude/settings.json`；使用者必須主動按 setup card 的「自動寫入」或自己編輯才會啟用資料源。
- 既有使用者升級 cmux 後：sidebar 多一塊空的 stats 區（或 inline 單行），點 setup card → 從此開始顯示數字。
- Rollback：關掉 `sidebar.showClaudeStats` 即可完全隱藏；想完全卸除功能，手動把 `~/.claude/settings.json` 內的 `statusLine.command` 改回原值（備份檔在 `.bak`）。

## Open Questions

- ~~**是否要在 unfocused inline row 顯示 model name？**~~ **已決：v1 顯示短名（`opus` / `son` / `hai`）**。多 session 同 workspace 時，取貢獻最大 `ctx` 那個 tab 的 model。unknown model id 時省略 model 段。spec `claude-stats-sidebar` 的 Inline stats on unfocused workspace rows 已寫入此規則。
- **compact count 要 per-session 還是 per-tab 累積？** `/resume` 換了 `session_id` 但 surface_id 沒變 → 要把 count 清零還是繼續累積？**初步決定**：per-session，和 Claude Code 自己的 compact 行為語義一致；UI 在切到新 session 時 compact 從 0 開始，使用者若在意上一個 session 的歷史可在 debug menu 查 `ClaudeStatsStore.compactHistory`。
