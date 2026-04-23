# Tasks — Add Screenshot Panel to Right Sidebar

## 1. 核心資料層：ScreenshotStore + path resolver（decisions：「預設路徑 fallback chain」「File watcher 策略」）

- [ ] 1.1 [P] 新增 `Sources/ScreenshotPanelSettings.swift`：實作 `ScreenshotPanelPathResolver.resolve()` → 4 階 fallback chain（UserDefaults → `com.apple.screencapture` 系統鍵 → `~/Desktop` → `~/Pictures`）；每階都檢查 directory 存在性，否則 skip；對應 spec `screenshot-panel-settings` 的 `screenshotPanel.path resolved via 4-step fallback chain` 全部 scenarios。
- [ ] 1.2 [P] 在 `ScreenshotPanelSettings.swift` 同檔定義 `enum ScreenshotViewMode { case grid, list }` + 讀寫 `@AppStorage("screenshotPanel.viewMode")` 的 helper；unknown raw value 一律 resolve 為 `.grid`（對應 spec `screenshot-panel-settings` 的 `screenshotPanel.viewMode with default grid` scenarios）。
- [ ] 1.3 新增 `cmuxTests/ScreenshotPathResolverTests.swift`：注入 mock `UserDefaults` + mock `CFPreferences` reader 驗 4 階 fallback；含「使用者路徑失效」「系統鍵未設」「Desktop 不存在」各 scenario；對應 spec `screenshot-panel-settings` 全部 resolver scenarios。
- [ ] 1.4 新增 `Sources/ScreenshotStore.swift`：`@MainActor final class ScreenshotStore: ObservableObject`，`@Published entries: [ScreenshotEntry]`、`@Published isTruncated: Bool`、`@Published totalCountInFolder: Int`、`@Published loadError: ScreenshotStoreError?`；`init(path:)` 載入第一次；`reload()` 方法；`deinit` 清掉 watcher。對應 spec `screenshot-store` 的 Scan folder + Entries sorted。
- [ ] 1.5 `ScreenshotEntry` value type：`id: UUID`（由絕對 path SHA-1 / deterministic UUID5）、`url: URL`、`mtime: Date`、`byteSize: Int`；對應 spec `screenshot-store` 的 Published snapshots are value types。
- [ ] 1.6 掃描規則實作：`FileManager.default.contentsOfDirectory` → 過濾副檔名（case-insensitive）→ resolve mtime + size via `resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])` → sort by mtime desc, 平手以 filename asc tie-break；對應 spec `screenshot-store` 的 Scan + Sort 兩條 Requirement。
- [ ] 1.7 Truncation cap 1000 筆：完整掃完再 slice 前 1000 項（不是讀 1000 就停），讓 `entries[0]` 一定是真的 most recent；設 `isTruncated` 與 `totalCountInFolder`；對應 spec `screenshot-store` 的 Scanning cap at 1000 entries scenarios。
- [ ] 1.8 DispatchSource folder watcher：`open(path, O_EVTONLY)` + `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:)`，mask `[.write, .extend, .delete, .rename, .link]`；event handler 觸發 `DispatchWorkItem` 200–300 ms debounce 後 `reload()`；path change 時 cancel 舊 source 再重建；對應 spec `screenshot-store` 的 File system watcher triggers reload 全部 scenarios。
- [ ] 1.9 NFS / SMB 降級 polling：`statfs` 偵測 `f_fstypename` 屬於 `nfs/smbfs/webdav/osxfuse` 時不建 DispatchSource，改用 5 秒 Timer 比對 folder listing fingerprint `Set<(name, mtime, size)>`；對應 spec `screenshot-store` 的 Watcher fallback to polling scenarios。
- [ ] 1.10 [P] 新增 `cmuxTests/ScreenshotStoreTests.swift`：temp folder fixture + 手建 `.png / .jpg / .pdf`，驗掃描、排序、truncation；用 `sleep 0.5` + 手動 touch file 驗 watcher debounce（`XCTestExpectation`）。對應 spec `screenshot-store` 絕大多 scenarios。

## 2. UI 骨架：RightSidebarMode 擴充（decisions：「Mode chip 整合方式」）

- [ ] 2.1 修改 `Sources/RightSidebarPanelView.swift`：`RightSidebarMode` enum 加 `case screenshots`；`symbolName` / `label` 補上（`camera` / localized "Shots"）；`@AppStorage("screenshotPanel.showsRightSidebarTab")` 預設 `true` 控制是否渲染第三個 chip；若 toggle 為 `false` 且目前 mode 為 `.screenshots` → 切回 `.files`；對應 spec `screenshot-panel-view` 的 Third mode in RightSidebarMode 與 spec `screenshot-panel-settings` 的 screenshotPanel.showsRightSidebarTab toggle。
- [ ] 2.2 `contentForMode` switch 加 `.screenshots` → `ScreenshotPanelView(store: ..., ...)`。確保 parent 持有 `@StateObject ScreenshotStore`（不要每次 body 重建）。
- [ ] 2.3 新增 `cmuxTests/RightSidebarModeTests.swift`：toggle `showsRightSidebarTab = false` + mode 當下為 `.screenshots` 時會 flip 回 `.files`（behaviour test via state observation）；對應 spec `screenshot-panel-settings` 的 showsRightSidebarTab toggle scenarios。

## 3. ScreenshotPanelView + preview + empty state（decisions：「Preview + list layout」）

- [ ] 3.1 新增 `Sources/ScreenshotPanelView.swift`：頂部 toolbar（path label + Grid/List toggle + Refresh icon）、中段 4:3 preview area、底部 gallery container；SwiftUI `VStack(spacing:0)`；對應 spec `screenshot-panel-view` 的 Preview + gallery vertical layout。
- [ ] 3.2 Auto-select 最新檔：`onAppear` 與 `onChange(of: store.entries)` 同時處理 `selectedId` — 初始 nil 且 entries 非空 → 設為 `entries[0].id`；使用者手動選過（`selectedId` 非 nil 且對應檔仍在）不動；對應 spec `screenshot-panel-view` 的 Auto-select most recent entry scenarios。
- [ ] 3.3 Preview area 實作：`if let entry = selectedEntry` → `Image(nsImage: NSImage(contentsOf: entry.url) ?? fallbackIcon)` + `.resizable().scaledToFit().aspectRatio(4/3, contentMode: .fill)`；nil 時 render empty placeholder。對應 spec `screenshot-panel-view` 的 Preview + gallery 與 Empty state with folder picker。
- [ ] 3.4 Empty state：store entries empty 時顯示 title `No screenshots yet` + hint 顯示 current resolved path；`loadError` 為 `.folderMissing` / `.permissionDenied` 時多顯一個 `Choose folder…` 按鈕 → 開 `NSOpenPanel(canChooseFiles:false, canChooseDirectories:true, allowsMultipleSelection:false)`；成功寫回 `screenshotPanel.path` 並 trigger store reload；對應 spec `screenshot-panel-view` 的 Empty state with folder picker scenarios。
- [ ] 3.5 Truncated footer：`if store.isTruncated` 顯示 `Showing most recent 1000 of <N>`，font 11pt monospaced faint；對應 spec `screenshot-panel-view` 的 Truncated warning when folder exceeds 1000 entries scenarios。
- [ ] 3.6 Theme-aware 配色：`@State claudeStatsTheme` / 新 `ScreenshotPanelTheme.make(from: GhosttyConfig)`（重用 `GitGraphTheme.ansiFallback` pattern）；`onReceive(...themes.reload-config)` 重算；對應 spec `screenshot-panel-view` 的 Theme-aware rendering scenarios。

## 4. Grid view + List view（decisions：「Grid vs List view」）

- [ ] 4.1 [P] 新增 `Sources/ScreenshotGalleryGridView.swift`：`LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))])` + 每 cell `aspectRatio(4/3, contentMode: .fill)`；讀 `QLThumbnailGenerator` 產生 thumbnail，cache miss 顯示檔案 icon 當 placeholder；selection outline 2pt accent；對應 spec `screenshot-panel-view` 的 Grid view renders thumbnail cells scenarios。
- [ ] 4.2 [P] 新增 `Sources/ScreenshotGalleryListView.swift`：`LazyVStack` + 每 row `HStack` 32×24 thumbnail + filename monospaced + relative mtime；對應 spec `screenshot-panel-view` 的 List view renders thumbnail + filename + mtime rows scenarios。
- [ ] 4.3 新增 `Sources/ScreenshotRelativeTimeFormatter.swift`：`format(_ date: Date, now: Date)` → `"<Ns>"` < 60s / `"<Nm>"` < 60min / `"<Nh>"` < 24h / `"<Nd>"` 其它；對應 spec `screenshot-panel-view` 的 Relative time formatting scenarios。
- [ ] 4.4 [P] 新增 `cmuxTests/ScreenshotRelativeTimeFormatterTests.swift`：fixture `now + {30s, 90s, 5min, 1h, 2.5h, 3d}` 驗格式輸出；對應 spec `screenshot-panel-view` 的 Relative time formatting 全部 scenarios。
- [ ] 4.5 [P] 新增 `Sources/ScreenshotThumbnailCache.swift`：`NSCache<NSURL, NSImage>` LRU 200 條；key = URL，value = thumbnail；`mtime` 改變時 invalidate 對應 key；對應 design 決策「Thumbnail 生成」。
- [ ] 4.6 [P] 新增 `cmuxTests/ScreenshotThumbnailCacheTests.swift`：驗 LRU eviction、mtime change 會 invalidate、不同 URL 不互相 evict（對應 design 決策「Thumbnail 生成」）。
- [ ] 4.7 Grid / List 切換：toolbar 右上兩個 icon button（`square.grid.2x2` / `list.bullet`）bind 同一 `@AppStorage("screenshotPanel.viewMode")`；對應 spec `screenshot-panel-view` 的 Grid and List view modes with user-toggleable toolbar scenarios。

## 5. 互動：單擊/雙擊/拖拽/右鍵（decisions：「雙擊 paste 走 TerminalImageTransfer 既有管線」「Drag-out」「右鍵 context menu 動作」）

- [ ] 5.1 單擊 vs 雙擊分流：`onTapGesture(count: 2)` 先、`onTapGesture()` 後（SwiftUI 會自動延後單擊以避開雙擊）；單擊 → `selectedId = entry.id`、雙擊 → `selectedId = entry.id` + 觸發 paste；對應 spec `screenshot-panel-view` 的 Single-click selects, double-click pastes scenarios。
- [ ] 5.2 修改 `Sources/TerminalImageTransfer.swift`：新增 `@MainActor static func pasteFileURL(_ fileURL: URL, to workspace: Workspace, tabManager: TabManager) throws`；內部組 `NSPasteboard` + 寫 `public.file-url` + image UTI → 呼叫現有 `prepare(...)` → dispatch；對應 spec `screenshot-terminal-paste` 的 pasteFileURL helper on TerminalImageTransfer scenarios。
- [ ] 5.3 在 `Workspace.swift` 新增 `@Published var lastFocusedTerminalPanelId: UUID?`，在現有 `focusPanel` 路徑中當 panel 是 `TerminalPanel` 時更新；`closePanel` 關的是 lastFocusedTerminal 時 fallback 到 panels 中最近被 focus 的另一個 TerminalPanel；對應 spec `screenshot-terminal-paste` 的 Workspace tracks last-focused terminal panel scenarios。
- [ ] 5.4 `pasteFileURL` 的 target resolution：先 focused terminal → 再 lastFocusedTerminalPanelId → nil 則 throw `noFocusedTerminal`；對應 spec `screenshot-terminal-paste` 的 Focused terminal resolution with fallback scenarios。
- [ ] 5.5 [P] 新增 `cmuxTests/ScreenshotTerminalPasteTests.swift`：mock workspace + mock focused panel，驗 target resolution 3 條 scenario；pasteboard 組裝 → `prepare()` plan 輸出等於從系統 pasteboard 貼圖一致（value comparison）；對應 spec `screenshot-terminal-paste` 的 pasteFileURL + Focused terminal resolution + Context-menu Copy 的 scenarios。
- [ ] 5.6 Drag-out：`draggable` modifier 提供 `NSItemProvider`，同時 register `.fileURL`（`loadObject(ofClass: URL.self)`）與 `.image`（PNG data）；對應 spec `screenshot-panel-view` 的 Drag-out emits NSItemProvider + spec `screenshot-terminal-paste` 的 Drag-out uses same pipeline scenarios。
- [ ] 5.7 右鍵 context menu：SwiftUI `.contextMenu { ... }` 五項（Copy / Paste / Reveal / Rename / Trash）照 spec 順序；對應 spec `screenshot-panel-view` 的 Right-click context menu with five actions scenarios。
- [ ] 5.8 Copy 動作：`NSPasteboard.general.clearContents()` + 寫 `public.file-url` + 寫 image UTI；對應 spec `screenshot-terminal-paste` 的 Context-menu Copy writes both fileURL and image scenarios。
- [ ] 5.9 Reveal in Finder 動作：`NSWorkspace.shared.selectFile(entry.url.path, inFileViewerRootedAtPath: "")`。
- [ ] 5.10 Rename 動作：inline TextField overlay；Enter 提交 → `FileManager.default.moveItem(at: old, to: new)`（檢查 destination 不存在，已存在則 inline error toast）；Esc / blur 取消；對應 spec `screenshot-panel-view` 的 Rename scenarios。
- [ ] 5.11 Move to Trash 動作：`FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)`；失敗顯示 inline toast 不彈 alert；對應 spec `screenshot-panel-view` 的 Move to Trash scenarios。

## 6. Debug menu + settings UI + settings.json sync（decisions：「預設路徑 fallback chain」）

- [ ] 6.0 擴充 `Sources/KeyboardShortcutSettingsFileStore.swift` 內的 `CmuxSettingsFileStore`（既有通用 settings.json 檔 store）：① 在 `supportedSettingsJSONPaths` 加入 `screenshotPanel.path`、`screenshotPanel.viewMode`、`screenshotPanel.showsRightSidebarTab`；② 新增 `parseScreenshotPanelSection(_:sourcePath:snapshot:)` 解析三個 sub-key 並把值寫進 `snapshot.managedUserDefaults[<UserDefaultsKey>]`；③ 在頂層 `parseSettings` 的 section dispatcher 加入 `"screenshotPanel"` case；④ Debug menu 的寫入沿用既有 `CmuxSettingsFileStore` ManagedSettingsValue 寫回 API，自動得到「保留其它 top-level keys + atomic write + malformed JSON 不 crash」。**Reuse rationale**：spec 原要求新建 `ScreenshotPanelSettingsFileStore`，但 cmux 既有 `CmuxSettingsFileStore` 已是通用 store（1839 行、支援 90+ key），只需註冊 key 即得 spec 全部 scenarios；新建獨立 store 會重複實作 atomic write / watcher / backup / schema 驗證。對應 spec `screenshot-panel-settings` 的 `settings.json sync for screenshotPanel.* keys` 全部 scenarios。
- [ ] 6.0.1 新增 `cmuxTests/ScreenshotPanelSettingsSyncTests.swift`：fixture 以 temp `primaryPath` 注入一個 `CmuxSettingsFileStore`（`init(primaryPath:fallbackPath:...)`），驗 ① 啟動讀 JSON → UserDefaults ② 透過 store write 寫入會保留其它 top-level keys（fixture 先寫 `keyboardShortcuts`）③ malformed JSON 時 UserDefaults 不變且 `dlog` 有 warning ④ Reset（移除 `screenshotPanel.path`）後其它 `screenshotPanel.*` sub-keys 保留；對應 spec `screenshot-panel-settings` 的 settings.json sync 全部 scenarios。
- [ ] 6.1 修改 `Sources/cmuxApp.swift` 的 SidebarDebugView（或 new `ScreenshotPanelDebugView`）：加 `GroupBox("Screenshot Panel")` 含：
  - 顯示 current resolved path（read-only label）
  - `Choose Folder…` Button → `NSOpenPanel(canChooseDirectories: true, canChooseFiles: false, allowsMultipleSelection: false)` → 呼叫 `CmuxSettingsFileStore.shared` 的 managed-settings 寫入 API 把 `screenshotPanel.path` 同時寫 UserDefaults 與 `settings.json`
  - `Reset to Auto-detect` Button → 透過同一 API 移除 `screenshotPanel.path`
  - `Show Shots tab in sidebar` Toggle bind 到 `@AppStorage("screenshotPanel.showsRightSidebarTab")`；改值時 store 觀察者會自動 mirror 到 settings.json
  對應 spec `screenshot-panel-settings` 的 Debug menu folder picker + Reset to Auto-detect scenarios。

## 7. i18n + pbxproj + build（decisions：無）

- [ ] 7.1 [P] 在 `Resources/Localizable.xcstrings` 新增 en / ja / zh-Hant 翻譯 keys：`rightSidebar.mode.screenshots`、`screenshotPanel.empty.title`、`screenshotPanel.empty.hint`、`screenshotPanel.empty.chooseFolder`、`screenshotPanel.truncated` (帶 `%d` / `%d`)、`screenshotPanel.contextMenu.copy`、`screenshotPanel.contextMenu.paste`、`screenshotPanel.contextMenu.reveal`、`screenshotPanel.contextMenu.rename`、`screenshotPanel.contextMenu.trash`、`screenshotPanel.rename.error.exists`、`screenshotPanel.trash.error.generic`、`debugMenu.screenshotPanel.chooseFolder`、`debugMenu.screenshotPanel.resetAutoDetect`、`debugMenu.screenshotPanel.showsTab`。
- [ ] 7.2 更新 `GhosttyTabs.xcodeproj/project.pbxproj`：為 `ScreenshotStore.swift`、`ScreenshotPanelView.swift`、`ScreenshotGalleryGridView.swift`、`ScreenshotGalleryListView.swift`、`ScreenshotPanelSettings.swift`、`ScreenshotThumbnailCache.swift`、`ScreenshotRelativeTimeFormatter.swift` 與所有新測試檔加入 `PBXBuildFile` / `PBXFileReference` / `PBXGroup` children / `PBXSourcesBuildPhase`；使用 `CA5F0001..CA5F0999` 風格 hex UUID 避免衝突。
- [ ] 7.3 `CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -configuration Debug -derivedDataPath /tmp/cmux-shot build` 通過無 warning。
- [ ] 7.4 `CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux-unit -configuration Debug -derivedDataPath /tmp/cmux-shot-test build` 通過。
- [ ] 7.5 `./scripts/reload.sh --tag shot` 成功 build tagged Debug app，手動驗：① 切到 Shots tab 看到 `~/Pictures/螢幕載圖` 下的截圖 thumbnail；② 雙擊最新截圖 → focused terminal 出現 image-reference 文字；③ 拖拽到 terminal 同效；④ 右鍵 Reveal / Rename / Trash 運作；⑤ Grid ↔ List 切換有持久；⑥ Debug menu 改 path → store 重載。
