# Claude Code Session Integration

cmux 透過 Claude Code 的 hook 機制記錄每個 terminal tab 裡 agent session 的
身份，重開 app 時據以 `claude --resume <sid>` 自動回到原 session。這份文件
說明整條資料管線、cmux 會自動做的事、使用者需要注意的事，以及壞掉時的
診斷流程。

適用於 **Release build 安裝版**（`/Applications/cmux.app`）。tagged Debug
build 路徑有差，但行為一致。

---

## 1. 資料管線總覽

```
Claude tool call
    │
    ▼
Claude 讀 ~/.claude/settings.json 的 hook 設定
    │
    ▼
執行 /Applications/cmux.app/Contents/Resources/bin/cmux claude-hook <event>
    │
    ▼
CLI 透過 CMUX_SOCKET / CMUX_WORKSPACE_ID / CMUX_SURFACE_ID 解析 panel
    │
    ▼
upsert 到 ~/.cmuxterm/claude-hook-sessions.json
    │
    ├─── autosave tick 讀入 snapshot 一起存到 session state
    │
    └─── 下次 app 啟動 restoreSessionSnapshot 讀 hook store →
         `claude --resume <sid>` 塞進 terminal stdin
```

三個 event 是資料寫入的主體：
- `SessionStart` — Claude 啟動時 seed 一筆 `(sessionId, workspaceId, surfaceId)`。
- `PreToolUse` — 每次 tool call 前更新 `updatedAt`（讓 record 永遠是最新的）。
- `SessionEnd` / `Stop` — 清掉 record，避免死 session 被當成 live。

`Notification` / `UserPromptSubmit` 不影響 resume，但會觸發 cmux 的狀態列
／通知顯示。

---

## 2. 檔案清單

| 位置 | 建立方 | 內容 | 備份策略 |
|---|---|---|---|
| `/Applications/cmux.app` | 使用者拖 DMG | app bundle | — |
| `/Applications/cmux.app/Contents/Resources/bin/cmux` | bundle 打包 | CLI 本體，所有 hook 命令都指向它的絕對路徑 | — |
| `~/.claude/settings.json` | Claude Code 管理，cmux 自動 merge hook 區塊 | statusLine + hooks | `~/.claude/settings.json.bak` 首次 auto-configure 寫入一次 |
| `~/.cmuxterm/` | CLI 第一次跑 hook 時 `mkdir -p` | session record 資料夾 | — |
| `~/.cmuxterm/claude-hook-sessions.json` | CLI 每次 hook 寫入 | `{sessionId: {workspaceId, surfaceId, cwd, updatedAt, ...}}` | atomic write |
| `~/.cmuxterm/claude-hook-sessions.json.lock` | `open(O_CREAT)` | flock 互斥 | — |
| `~/Library/Application Support/cmux/cmux.sock` | cmuxd | socket endpoint | — |

---

## 3. 自動配置：cmux 開 app 時會做的事

`Sources/ClaudeSettingsInspector.swift` 的 `migrateSessionTrackingHooksIfNeeded()`
在 sidebar `.onAppear` 時執行：

1. `classifyConnectionStatus()` — 檢查 `~/.claude/settings.json` 的
   `statusLine.command` 是不是指向 cmux。若不是（fresh install / 沒開過
   setup card），整段跳過，等使用者從 sidebar 的 setup card 按
   「Auto configure」。
2. 若已連線但 `hasCompleteSessionTrackingSetup()` 回 false（有任何一個
   session event 沒有用當前 bundle 絕對路徑 registered），呼叫
   `autoConfigureAtomic()`：
   - 備份原始 `settings.json` 到 `.bak`（write-once）。
   - `mergeStatusline` 替換 `statusLine.command` 為絕對路徑。
   - `mergeCommandHook` 對 7 個 event（PreCompact + 6 個 session event）
     idempotent 地 append cmux entry，**不動**使用者自己的 hook entries。
   - atomic write。

使用者已有的 hook（例如 `node ~/.claude/hooks/message-tracker.js`、
`file-tracker.js` 等）會被保留，只是多幾個 cmux 的 entry 並列。Claude 會
依序呼叫所有註冊的 hook，互不影響。

### 需要的 Claude 設定最終型

```jsonc
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/cmux.app/Contents/Resources/bin/cmux statusline"
  },
  "hooks": {
    "SessionStart":     [{ "matcher": "", "hooks": [{ "type": "command", "command": ".../cmux claude-hook session-start" }] }],
    "PreToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": ".../cmux claude-hook pre-tool-use" }] }],
    "Stop":             [{ "matcher": "", "hooks": [{ "type": "command", "command": ".../cmux claude-hook stop" }] }],
    "SessionEnd":       [{ "matcher": "", "hooks": [{ "type": "command", "command": ".../cmux claude-hook session-end" }] }],
    "Notification":     [{ "matcher": "", "hooks": [{ "type": "command", "command": ".../cmux claude-hook notification" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": ".../cmux claude-hook prompt-submit" }] }],
    "PreCompact":       [{ "matcher": "", "hooks": [{ "type": "command", "command": ".../cmux record-compact" }] }]
  }
}
```

`.../` 是 `/Applications/cmux.app/Contents/Resources/bin/`。Release 用
`cmux`；tagged Debug build（`reload.sh --tag X`）用 `cmux-dev` 而且路徑
會指向 tagged bundle 內的 CLI。

---

## 4. 為什麼要用絕對路徑？⚠️ PATH collision

hook command 過去用 bare name `cmux claude-hook ...`，依賴 `$PATH` 解析
到對的 cmux。但 Oracle Instant Client 會在 `~/Downloads/instantclient_.../`
安裝一個同名 `cmux` binary。Claude 呼叫 hook 時，shell 從 `$PATH` 前往後
找，先命中 Oracle 的 `cmux`：

- Oracle cmux 從 stdin 讀進 Claude hook 送的 JSON。
- 它不認識指令，但一如多數 Oracle CLI 行為，**印一個 `OK` 然後 exit 0**。
- Claude 視為 hook 成功。沒警告、沒錯誤。
- cmux.app 的 CLI 從未被呼叫，`~/.cmuxterm/` 永遠是空的，restore 無法 work。

以下情境都會踩到類似問題：Homebrew 裝了別的 cmux、公司內部工具叫
cmux、先前安裝過舊版 cmux CLI 散落在 `/usr/local/bin`。所以**整條都鎖
絕對路徑**（`bundledCLIAbsolutePath`），不再信 PATH。

### 使用者端不一定要動 PATH

這套架構下你 `$PATH` 裡即使有 Oracle cmux 也沒關係（hook 不經過
PATH）。但如果你打算在 shell 裡直接 `cmux <cmd>` debug，那會命中 Oracle
的。擇一：

- 不 debug／不跑 CLI：**保留現狀**，沒影響。
- 偶爾跑：`alias cmux=/Applications/cmux.app/Contents/Resources/bin/cmux`。
- 徹底解決：在 `~/.zshrc` 把 Oracle 路徑移到 PATH 最後，或改用
  `instantclient` 提供的 wrapper 名（若存在）。

---

## 5. 資料流：save 與 restore

### Save path（跑 Claude 時持續發生）

1. Claude 執行 tool call → 觸發 `PreToolUse` hook。
2. cmux CLI `runClaudeHook` 被呼叫，env 帶 `CMUX_SOCKET / CMUX_WORKSPACE_ID
   / CMUX_SURFACE_ID`。
3. `ClaudeHookSessionStore.upsert` 取 flock，load 現有 json，merge 新
   record，atomic write 回 `~/.cmuxterm/claude-hook-sessions.json`。
4. 同時 cmux app 的 `RestorableAgentSessionIndex.load()` 在 autosave tick
   讀這個檔，寫進 `SessionTerminalPanelSnapshot.agent`。

### Restore path（app 重啟）

1. `AppDelegate.applySessionWindowSnapshot` 載入上次的 session snapshot。
2. 同時呼叫 `RestorableAgentSessionIndex.load()` 讀最新 hook store。
3. 把 index 傳入 `TabManager.restoreSessionSnapshot(_:restorableAgentIndex:)`
   → `Workspace.restoreSessionSnapshot` → `restorePane` → `createPanel`。
4. `createPanel` 裡決定要 resume 誰：
   ```swift
   let fromHook = agentIndex.snapshot(workspaceId: id, panelId: snapshot.id)
   let restorableAgent = fromHook ?? snapshot.terminal?.agent
   ```
   **hook store 優先**——因為 hook 每次 tool call 都 refresh，比 autosave
   的 snapshot 還要新。snapshot 的 agent 是後備（hook 沒抓到的 panel）。
5. `resumeStartupInput()` 產生 `"claude --resume <sid>\n"`，當作
   `initialInput` 塞進新開的 terminal surface 的 stdin。
6. Terminal 起來第一件事就是執行 resume 指令，回到原 session。

---

## 6. Cmd+Q 退出行為

退出路徑現在**只存一次** session snapshot（在 `applicationWillTerminate`）
而且**不包 scrollback**：

- `applicationShouldTerminate`：不存，只跳對話框（若需要）。
- `applicationWillTerminate`：`saveSessionSnapshot(includeScrollback: false)`。

Scrollback 由 autosave timer 每 ~15 秒 `includeScrollback: true` 存一次
作保底。Cmd+Q → 確定 → 應該秒關；代價是最後幾秒的 scrollback 增量會丟。

---

## 7. 驗證 checklist

一般 Terminal（**不要用 cmux 內的 Claude session**）：

```bash
# (1) App 裝對位置
ls /Applications/cmux.app/Contents/Resources/bin/cmux

# (2) Hook migrate 完成
python3 <<'EOF'
import json
s = json.load(open('/Users/jack/.claude/settings.json'))
need = ['SessionStart','PreToolUse','Stop','SessionEnd','Notification','UserPromptSubmit']
missing = [e for e in need if not any(
    '/Applications/cmux.app' in h.get('command', '')
    for entry in s.get('hooks', {}).get(e, [])
    for h in entry.get('hooks', [])
)]
print('✅ 全部已裝' if not missing else f'❌ 缺: {missing}')
EOF

# (3) Session store（要先在 cmux 裡開 Claude 跑一個 tool）
ls ~/.cmuxterm/claude-hook-sessions.json && \
  cat ~/.cmuxterm/claude-hook-sessions.json | python3 -m json.tool | head -20
```

---

## 8. 故障排除

| 症狀 | 可能原因 | 診斷 |
|---|---|---|
| 重開後 tab 變空 shell，沒 resume | hook store 空 | `ls ~/.cmuxterm/`；若沒檔案，代表 hook 沒寫入 |
| hook store 真的空 | Claude settings 沒 cmux hook | `python3 … settings.json`（驗證 checklist #2） |
| Claude settings 有 hook 但 store 還是空 | PATH collision（bare name 被搶）或 cmux CLI 寫入失敗 | 看 hook command 是絕對路徑還是 bare `cmux`；前者才對 |
| 絕對路徑但仍寫不進 | 檔案系統權限、`~/.cmuxterm/` 無法建立 | 手動 `mkdir ~/.cmuxterm && chmod 755 ~/.cmuxterm`；再開 Claude 跑 tool 看有沒有檔案 |
| hook command 是 bare name | Migration 沒觸發 | 開 sidebar 一次（觸發 `.onAppear`）；或手動從 setup card 按 Auto-configure |
| setup card 看不到（但沒 connected） | `classifyConnectionStatus()` 回 `connected`（舊 statusLine 在） | 刪掉 `settings.json` 的 `statusLine`，重開 app |
| 單獨 panel 不 resume，其它 OK | 那個 panel 是新開的、hook 還沒跑 | 在那 panel 下一個指令讓 Claude call tool，然後再 kill + 重開 |
| Cmd+Q 還是慢 | scrollback save 的那行沒改到（舊 build） | 比對 `/Applications/cmux.app/Contents/MacOS/cmux` 的 mtime 對上 DMG build 時間 |

### 手動模擬 hook（debug 用）

```bash
env CMUX_SOCKET="$HOME/Library/Application Support/cmux/cmux.sock" \
    CMUX_WORKSPACE_ID=56A36941-F4D0-43F2-832A-504CA5755D8D \
    CMUX_SURFACE_ID=91F18EDF-9CED-4008-B104-0F7EB5BEEFBC \
    sh -c 'echo "{\"session_id\":\"manual-test\",\"cwd\":\"/tmp\"}" | \
           /Applications/cmux.app/Contents/Resources/bin/cmux claude-hook session-start'
```

成功的話 `~/.cmuxterm/claude-hook-sessions.json` 會多一筆 `manual-test`。

---

## 9. 相關 commit 紀錄

session restore 相關修正（push 到 `origin/develop`）：

| commit | 主題 |
|---|---|
| `bef46f3f` | `session restore: fall back to PreToolUse hook store when snapshot's agent is nil` — restore path 加 fallback |
| `55b2c060` | `claude settings: auto-install session-tracking hooks` — `ClaudeSettingsInspector` 擴充 |
| `9f95f85b` | `claude hooks: use bundled CLI absolute path to sidestep PATH collisions` — 避開 Oracle cmux |
| `789e35db` | `cli: create ~/.cmuxterm before opening Claude hook lock file` — CLI 建目錄 |
| `8234037e` | `quit dialog: remove duplicate sync save so clicking Quit isn't a 10 s freeze` |
| `3da3ac41` | `quit: drop scrollback from the willTerminate save to make Cmd+Q feel instant` |

相關原始碼：

- `Sources/RestorableAgentSession.swift` — `RestorableAgentKind`, `SessionRestorableAgentSnapshot`,
  `RestorableAgentSessionIndex`, `AgentResumeScriptStore`。
- `Sources/ClaudeSettingsInspector.swift` — hook 自動安裝、migration、PATH 偵測。
- `Sources/Workspace.swift` — `restoreSessionSnapshot` / `restorePane` / `createPanel` 的 agent resolution。
- `Sources/TabManager.swift` — 最外層 `restoreSessionSnapshot` 接收 agent index。
- `Sources/AppDelegate.swift` — 啟動時載入 index、`applicationWillTerminate` 的 save 行為。
- `CLI/cmux.swift`
  - `ClaudeHookSessionStore` / `withLockedState` — 實際寫入 hook store
    的地方。
  - `runClaudeHook` — event → upsert/lookup 路由。
