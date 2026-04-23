## Context

cmux 右側 sidebar（`Sources/RightSidebarPanelView.swift`）已經有一套 `RightSidebarMode` enum + chip bar 切換模式的架構，目前只有 `.files` (FileExplorer) 和 `.sessions` (SessionIndex)。每個 mode 底下掛各自的 view + 自己的 store。

`Sources/TerminalImageTransfer.swift` 已實作完整的「pasteboard 有圖 → 貼到目前 focused terminal」pipeline，而且自動分 local workspace / SSH workspace 兩條路：
- local → 轉成可插入的 `$file "/path/to/img.png"` 文字 reference（給 ghostty terminal）
- SSH → 先 `scp` 到 remote 暫存路徑，再 insert 遠端路徑文字 reference

`Sources/FileExplorerStore.swift` 示範了一個 folder file watcher 寫法：DispatchSource `makeFileSystemObjectSource` 監聽 folder fd，write/extend/delete/rename/link 事件都會觸發 reload callback，實測可靠。

macOS 使用者的截圖位置可由 `defaults read com.apple.screencapture location` 取得；若沒設定則系統預設 `~/Desktop`。本機使用者（Jack）實際是 `~/Pictures/螢幕載圖`，各 locale / 個人偏好會不同。

SwiftUI 右側 sidebar 的寬度約 260–300 px，內嵌 preview + 列表需要 vertical 切分；水平切分空間不夠。

## Goals / Non-Goals

**Goals:**
- 從「切到 Finder 找圖」的 4–5 步 context switch 減到 1 步：切 mode tab → 雙擊圖 → 貼到 terminal。
- 既有 `TerminalImageTransfer` 的 local / SSH 分支自動 reuse，不重寫 pasteboard → terminal 邏輯。
- 路徑可由使用者設定；fresh install 有合理的系統預設。
- Folder 內容更動立即反映（新截圖出現在頂端自動選中），不需手動 refresh。
- Theme-aware 的 UI — 跟 git graph / claude stats 一樣 follow ghostty theme。

**Non-Goals:**
- Panel 內嵌 `screencapture -i` 按鈕（TCC 權限 + scope）。
- 圖片編輯 / annotation / crop。
- OCR。
- 自動複製新截圖到 pasteboard。
- 自動清理舊截圖。
- 多 folder / 遠端 folder。
- 非圖片檔（mp4 / pdf / psd …）。

## Decisions

### Mode chip 整合方式：新增 `.screenshots` case，不動既有架構

選 **在 `RightSidebarMode` enum 加一個 case**。`contentForMode` 分派到新 `ScreenshotPanelView`。

- 理由：已有 stable pattern，加第三個 case 成本小且視覺上一致。
- 否決「獨立 window」：跟 cmux 「sidebar 集中放工具」的心智模型不符；使用者預期右 sidebar 是 auxiliary pane，不是另一個 window。
- 否決「Files tab 裡加『Screenshots』子分類」：使用者要的是一個**專用**快速入口，不是混進 file tree。

### 預設路徑 fallback chain：系統設定優先

選 **4 階 fallback**（由上往下找第一個成功）：

1. `~/.config/cmux/settings.json` 的 `screenshotPanel.path`（使用者在 Settings 設過）
2. macOS `defaults read com.apple.screencapture location`（`CFPreferencesCopyAppValue("location", "com.apple.screencapture")`）
3. `~/Desktop`（macOS 系統預設截圖位置）
4. `~/Pictures`（最後的防呆；basically 一定存在）

這讓不同 locale / macOS 設定的使用者 fresh install 都能直接用（多數人 macOS 沒改過，落到 step 2 或 step 3），同時 Jack 可以一次設成 `~/Pictures/螢幕載圖` 寫死。

- 否決「fresh install 寫死 `~/Pictures/螢幕載圖`」：上游貢獻不能綁個人 locale。
- 否決「第一次跑強制彈 folder picker」：太吵，onboarding 差。

### File watcher 策略：DispatchSource folder watcher + debounce

跟 `FileExplorerStore` 同 pattern：`open(path, O_EVTONLY)` + `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:)`，事件 mask 包含 `.write .extend .delete .rename`。觸發後以 200 ms debounce 合併、重掃 folder、發佈新 snapshot。

- 理由：抓 write/extend 能即時看到新截圖出現；抓 delete/rename 能乾淨更新列表。
- 200 ms debounce 是因為 `screencapture` 寫檔可能觸發多個 event（create + write + extend + link rename）。合併避免短時間內多次掃 folder。
- 否決 polling：耗電、延遲。
- 否決 `FSEventsStream`：比 DispatchSource 重、FSEvents API 在 macOS 沙箱環境偶爾 miss events。

### Preview + list 的 layout：垂直堆疊，preview 固定 aspect ratio 4:3

選 **上半 preview（4:3 aspect）+ 下半 grid/list**，不做水平分欄。

- 理由：sidebar 寬 260–300 px，水平分兩欄會讓 list 或 preview 都太窄。垂直堆疊讓 preview 在固定比例下 shrink/grow 得自然。
- 4:3 是妥協值：16:9 在窄 sidebar 會變得非常扁；1:1 太高；4:3 適合大部份螢幕截圖的 aspect ratio。
- 沒選中時 preview 區顯示 empty state 文字，不會塌陷。

### Grid vs List view：使用者可切，預設 Grid

選 **Grid 是預設**，Debug menu / toolbar toggle 切 List。Grid `LazyVGrid(minimum: 56 pt)`，cell `aspect-ratio 4/3`，4 欄左右（視 sidebar 實際寬度）。List 每行 32×24 縮圖 + filename + 相對時間。

- 理由：截圖檔名幾乎都長一樣的「截圖 YYYY-MM-DD HH.MM.SS.png」，靠檔名很難快速分辨；Grid 的縮圖辨識度壓倒性勝出。
- List 保留給「我就記得檔名」和「要 rename」這兩個 workflow。
- 狀態（view mode）用 `@AppStorage("screenshotPanel.viewMode")`，跨 session 持久。

### 雙擊 paste 走 `TerminalImageTransfer` 既有管線

新增一個 public helper：
```swift
@MainActor
static func pasteFileURL(
    _ fileURL: URL,
    to workspace: Workspace,
    tabManager: TabManager
) throws
```

內部：
1. 合成 `NSPasteboard` 暫存實例，寫入 `public.file-url`、`public.png`（或對應副檔名的 UTI）。
2. 呼叫既有 `TerminalImageTransfer.prepare(...)` → `materializedFileURLs(...)`。
3. 分派給 focused terminal 的 surface 做 insert / upload。

這樣 SSH workspace 完全免改：現有 SSH scp + remote path replace 邏輯自動 reuse。

- 否決「直接寫 path 文字到 terminal」：破壞 `TerminalImageTransfer` 已經處理好的 SSH upload、ghostty-specific escape、terminal-specific `$file` reference。
- 否決「只走 `$file` reference」：local 的 ghostty `$file "..."` 已經靠 `TerminalImageTransfer` 處理，別平行實作。

### Drag-out：`NSItemProvider` 提供雙型別

實作 `Draggable` behavior 透過 `NSItemProvider` 註冊 `.fileURL` 與 `.image` 兩個 type：
- `.fileURL`：terminal drop handler 看 file URL，再走 `TerminalImageTransfer` 的 `materializedFileURLs` 分支。
- `.image`：備援，當 terminal handler 忽略 file URL 時仍能靠 raw image bytes fallback。

這跟使用者從 Finder 拖 `.png` 進 terminal 是等價行為，重用現有 drop handler。

### 右鍵 context menu 動作

5 項，按頻率排序：
1. **Copy to pasteboard** — `NSPasteboard.general` 寫入 file URL + image data（等同 Finder 右鍵 Copy）。
2. **Paste to terminal (⏎)** — 同雙擊。快捷鍵 `Enter` 也觸發此動作。
3. **Reveal in Finder** — `NSWorkspace.shared.selectFile(_:inFileViewerRootedAtPath:)`。
4. **Rename…** — inline edit；失敗時 inline error toast。
5. **Move to Trash** — 用 `FileManager.default.trashItem(at:resultingItemURL:)`，能在 Finder 按⌘Z 復原。**不**做 "Delete immediately"；最小破壞性。

### Staleness / 刷新
- 新檔進來時 DispatchSource 300 ms 內觸發 reload。
- 手動 refresh（toolbar ⟳）無條件重掃 + rebuild thumbnail cache。
- 不顯示「N 秒前 last checked」這種時間戳 — file watcher 可信度高，多餘資訊。

### Thumbnail 生成

`NSImage(contentsOf:)` + `QuickLookThumbnailing.QLThumbnailGenerator` 混用：
- Grid cell（4:3 max 120 px 寬）：`QLThumbnailGenerator.generateBestRepresentation(for:)` 非同步產生；有 cache。
- Preview（4:3 max ~280 px 寬）：直接讀原圖，SwiftUI `Image(nsImage:)` 顯示；圖大的情況靠 SwiftUI 自己 downscale。
- HEIC / WebP 靠系統 codec 解碼，不額外引入套件。

Cache：`ImageCache` 以 URL + mtime 為 key，LRU 上限 200 thumbnails。超過上限或檔案被刪時 evict。

- 否決全部用原圖：單張截圖 5–10 MB，20+ 張可能吃掉 100+ MB memory。
- 否決 disk-persist cache：macOS 有 QLThumbnail 系統 cache 可依賴；再 persist 一次 overkill。

## Risks / Trade-offs

- [Risk] DispatchSource folder watcher 在 NFS / iCloud sync 的 folder 可能 miss events。→ Mitigation: 依 `screenshotPanel.path` 所在 volume type 降級為 5s polling（`statfs` 判斷 fs type 是 `nfs`/`smb`/`webdav` 時啟動 polling fallback）；一般 APFS local disk 走 DispatchSource。
- [Risk] QLThumbnail 生成非同步、首次打開可能閃 placeholder。→ Mitigation: 用 `QLThumbnailGenerator` 生成期間顯示檔案 icon（`NSWorkspace.shared.icon(for:)`）；generation 完成再 swap 成實際縮圖。避免 placeholder 閃爍的唯一方法是 sync 讀 — 太貴，不採。
- [Risk] 使用者把 path 設到一個超大 folder（`~/Downloads` 有 5000 張圖）→ 記憶體爆 / UI lag。→ Mitigation: 掃描上限 1000 個 entry，超過時 toolbar 顯示 warning badge + footer `truncated — showing first 1000 of N`。
- [Risk] `trashItem` 在某些 sandbox / permission 狀況會失敗。→ Mitigation: catch error 顯示 inline error toast；不 retry、不 dialog。
- [Risk] Rename 動作若目標檔名已存在會失敗。→ Mitigation: 用 `FileManager.default.moveItem(at:to:)`，fileExists 先檢查；用 UI inline error 顯示「檔案已存在」。
- [Risk] 多個 cmux 實例（Debug + Release）同時 watch 同一 folder。→ Mitigation: 兩個實例各自持有獨立 `DispatchSource`；watcher resource usage 極低，實測 OK。
- [Trade-off] 雙擊貼圖 = focused terminal — 若使用者沒 focused 任何 terminal（例如正在打 sidebar search），paste 會找不到 target。→ Mitigation: fallback 為「最後一次被 focused 的 terminal」，若仍無則顯示 inline error。
- [Trade-off] v1 不做多 folder — 使用者若想看 `~/Desktop` + `~/Pictures/螢幕載圖` 兩個地方要手動切 path。可接受的 v1 妥協。

## Migration Plan

全新功能，無 migration。
- 安裝 cmux 升級版 → 右 sidebar 出現第三個 chip `Shots`，點進去看到自動偵測的路徑下的截圖。
- 使用者第一次進 `.screenshots` mode 時：
  1. 有路徑且能讀 → 直接顯示。
  2. 路徑不存在 / 權限錯誤 → empty state 配「Choose folder…」按鈕 → 開 `NSOpenPanel`。
- Rollback：在 Debug menu 關閉 `screenshotPanel.showsRightSidebarTab` toggle → chip bar 只剩 Files / Sessions（回到原狀）。

## Open Questions

- **SSH workspace 該不該禁用 paste？** 本機截圖 scp 到遠端再 paste reference，大截圖（10+ MB）上傳會明顯卡幾秒。**初步決定**：不禁用，讓 `TerminalImageTransfer` 的既有 SSH 路徑自然處理；UI 顯示小 spinner 在雙擊的瞬間告知「uploading」。使用者自己決定要不要對大檔這麼做。
- **Rename 動作的完成 trigger**：`Enter` submit vs `blur` submit。**初步決定**：`Enter` 確認、`Esc` 取消、blur 視為取消（避免誤碰）。
