# Add Screenshot Panel to Right Sidebar

## Why

使用者在 cmux 裡跟 Claude Code 對話時，常常要把剛截的圖貼給 Claude 看（參考 UI、錯誤畫面、設計 mock）。目前流程是：

1. 切出 cmux → 打開 Finder 或 `open ~/Pictures/螢幕載圖`
2. 找到剛截的那張（通常檔名是 `截圖 YYYY-MM-DD HH.MM.SS.png`）
3. 拖進 cmux 的 terminal，或 Cmd+C → 回 cmux 的 claude session → Cmd+V

每次要 4–5 個動作、兩次 context switch。尤其一小時截 10 張以上的 design session 裡，overhead 很明顯。

cmux 的右側 sidebar 已經有 Files / Sessions 兩個 mode（見 `Sources/RightSidebarPanelView.swift`），pattern 乾淨地支援再接一個 mode。既有的 `TerminalImageTransfer.swift`（paste/drop pipeline、local + SSH 分支全部處理好）也可以重用，不用重寫 pasteboard → terminal 邏輯。

## What Changes

- **新增 `.screenshots` 第三個 mode**：`RightSidebarMode` enum 加 case `.screenshots`，chip bar 顯示 `Files / Sessions / Shots`。
- **新增 `ScreenshotPanelView`**（`Sources/ScreenshotPanelView.swift`）：上半 preview 區（固定 4:3、單張最近截圖自動選中），下半可切 Grid / List view 的 thumbnail 瀏覽器。
- **新增 `ScreenshotStore`（`@MainActor ObservableObject`）**：watch 一個 folder、列出符合副檔名的檔、依 mtime 降冪排序；DispatchSource file watcher 觸發 reload。
- **新增設定鍵 `screenshotPanel.path`**：`~/.config/cmux/settings.json` + Debug menu 裡 `NSOpenPanel` folder picker。Fresh install fallback 依序：
  1. macOS `defaults read com.apple.screencapture location`（系統截圖位置）
  2. `~/Desktop`（macOS 預設截圖處）
- **新增設定鍵 `screenshotPanel.viewMode`**：`grid`（預設）或 `list`。
- **雙擊 = Paste to focused terminal**：呼叫 `TerminalImageTransfer` 現有路徑，附帶 file URL + `public.png` pasteboard type；local workspace 走 insert-text-reference，SSH workspace 自動走 remote-upload。
- **Drag-out** 支援：`NSItemProvider` 包 `.png` / `public.file-url`，拖到 terminal 會走同一條 drop handler。
- **右鍵 context menu**：`Copy to pasteboard` / `Paste to terminal` / `Reveal in Finder` / `Rename…` / `Move to Trash`。
- **Single-click = preview only**（跟雙擊明確分隔，不會意外貼圖）。
- **掃描規則**：副檔名 `.png / .jpg / .jpeg / .heic / .gif / .webp`（case-insensitive），依 mtime 降冪。
- i18n：約 10 個新字串（mode chip label、toolbar tooltip、context menu、empty state）。

## Non-Goals

- **系統截圖 capture button**：v1 不在 panel 裡嵌 `screencapture -i`。TCC 介面權限要處理、scope 會擴，留給後續 change。
- **Annotation / edit / crop**：不做圖片編輯 — 屬獨立 app 級功能。
- **OCR paste as text**：不做。Claude Code 4.x 直接吃圖，沒必要中間 detour。
- **Auto-copy new screenshots to pasteboard**：不加入「新截圖到就自動複製到 pasteboard」這種自動行為 — 會污染 pasteboard、跟其他 app 互動不可預測。
- **Retention / auto-cleanup**：不做「> N 天自動刪」這種破壞性動作，避免誤刪。
- **Multiple folders**：v1 只支援單一 folder。要看多個 folder 延後。
- **Remote path**：SSH workspace 的遠端 folder 不 watch；panel 只讀本機。
- **Non-image 檔案**：mp4 / pdf / psd 等暫不支援；副檔名 white-list 嚴格。
- **多選（multi-select）**：v1 gallery 只支援單一 selection。不做 `⌘-click` 加選 / `shift-click` 連續選。Paste / Copy / Drag / Rename / Trash 全部只作用在目前 `selectedId` 那一張。多檔同時 paste 需要 `TerminalImageTransfer` 擴充多 URL 分支，scope 留給後續 change。

## Capabilities

### New Capabilities

- `screenshot-store`: 掃描設定路徑下的圖片檔、維持按 mtime 降冪的 list、DispatchSource watcher 觸發 reload、暴露值型 snapshot 給 UI。
- `screenshot-panel-view`: 右側 sidebar 第三個 mode 的 UI — preview area + grid/list 兩種檢視、auto-select 最新檔、鍵盤 & 滑鼠互動。
- `screenshot-terminal-paste`: 雙擊 / 拖拽 / context-menu "Paste" 一致地把選中的檔案送到 focused terminal（走現有 `TerminalImageTransfer`）。
- `screenshot-panel-settings`: 設定 `screenshotPanel.path` 與 `screenshotPanel.viewMode`，支援 UI folder picker + `settings.json` 持久化，fresh-install fallback 走 macOS 系統截圖位置。

### Modified Capabilities

(none — 全部新增能力；`RightSidebarMode` 是檔案內部的 enum，沒有對應的現有 spec)

## Impact

- **Affected specs**:
  - 新增 `specs/screenshot-store/spec.md`
  - 新增 `specs/screenshot-panel-view/spec.md`
  - 新增 `specs/screenshot-terminal-paste/spec.md`
  - 新增 `specs/screenshot-panel-settings/spec.md`

- **Affected code** (預計):
  - 新增 `Sources/ScreenshotStore.swift` — `@MainActor ObservableObject`，掃描 + 排序 + file watcher。
  - 新增 `Sources/ScreenshotPanelView.swift` — SwiftUI 主視圖（含 Grid / List subview）。
  - 新增 `Sources/ScreenshotPanelSettings.swift` — `@AppStorage` key + path resolver（含 macOS `defaults read com.apple.screencapture location` probe）。
  - 新增 `Sources/ScreenshotContextMenuHandler.swift`（或 inline in ScreenshotPanelView）— 右鍵選單 + Rename / Trash / Reveal 動作。
  - 修改 `Sources/RightSidebarPanelView.swift` — `RightSidebarMode` 加 `.screenshots`；mode chip bar 第三個 chip；`contentForMode` 分派到新 view。
  - 修改 `Sources/TerminalImageTransfer.swift` — 新增一個 public helper `pasteFileURLToFocusedTerminal(_:in:)`（把 file URL 包成 pasteboard 再走現有 `prepare` 路徑）；若既有 API 直接可重用則免改。
  - 修改 `Sources/cmuxApp.swift` — Debug menu 加 `Screenshot Panel Path…` folder picker + view-mode toggle。
  - 修改 `Resources/Localizable.xcstrings` — 新增約 10 個 en / ja / zh-Hant keys。
  - 修改 `GhosttyTabs.xcodeproj/project.pbxproj` — 登錄新的 Swift 檔。
  - 新增測試：`cmuxTests/ScreenshotStoreTests.swift`（掃描規則 + 排序 + 空/不存在/權限錯誤）、`cmuxTests/ScreenshotPathResolverTests.swift`（fallback chain）、`cmuxTests/ScreenshotTerminalPasteTests.swift`（pasteboard 組裝 + plan resolver）。

- **Dependencies**: 無新增套件。`DispatchSource` / `NSOpenPanel` / `NSPasteboard` / `NSItemProvider` 全部是 system framework；`TerminalImageTransfer` 已存在。
