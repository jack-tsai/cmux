## Why

cmux 的 Markdown panel（`Sources/Panels/MarkdownPanelView.swift`）使用 `swift-markdown-ui` 渲染 `.md` 檔，但 swift-markdown-ui 完全不認識 `mermaid` code block，使用者開啟含有 mermaid 圖表的文件（README、架構文件、Spectra 的 `design.md` 等）時只會看到原始文字碼，失去了圖表本身的溝通價值。GitHub、VSCode、Obsidian 等常用工具都已原生支援 mermaid，cmux 目前缺席成為檔案預覽體驗的明顯落差。

## What Changes

- 在 `MarkdownPanelView` 的 `.codeBlock` 客製化中新增語言分流：當 `configuration.language == "mermaid"` 時改用新 `MermaidBlockView` 渲染；其他語言維持現有行為。
- 新增 `MermaidBlockView`：以 `WKWebView` 為核心，每一段 mermaid 區塊對應一個獨立的 WebView 實例。
- 將 `mermaid.js`（固定版本）以 bundle resource 方式內嵌到 app，渲染時從 `Bundle.main` 讀取，不連網。
- 實作 JS → Swift 的 `WKScriptMessageHandler` 橋接：mermaid 完成渲染後回傳 SVG 的 intrinsic height，SwiftUI 端以 `.frame(height:)` 適配，避免雙層捲動。
- Dark / Light 主題跟隨 `@Environment(\.colorScheme)` 切換：colorScheme 變動時重新呼叫 `mermaid.initialize({ theme })` + `mermaid.run()`，不重建 WebView。
- 語法錯誤時就地顯示錯誤訊息（紅底 + 原始碼），不影響同一份文件中的其他圖表或其他 Markdown 元素。
- 新增單元測試覆蓋 mermaid block 的抽取 / 分流 parser 層（runtime seam），不做 WebView 的像素快照測試。

## Non-Goals

- **不做**：把整份 Markdown 改由 WebView 渲染（會連動放棄既有的 `cmuxMarkdownTheme`、原生文字選取、first-click focus 契約，爆炸半徑過大，屬於未被需要的擴充性）。
- **不做**：透過外部 `mmdc` CLI 預渲染 SVG（需 Node 依賴，違反 cmux 作為離線桌面 app 的定位）。
- **不做**：自行以 Swift 實作 mermaid 解析與繪圖（工程量與 mermaid 上游更新成本皆不合理）。
- **不做**：為 mermaid 提供獨立的設定 UI（theme、字型、diagram direction 全部跟隨系統外觀；未來有需要再開新 change）。
- **不做**：在 Sidebar Markdown preview（`SidebarMarkdownRendererTests` 覆蓋的路徑）支援 mermaid — 那是純文字摘要場景，不需要圖形。
- **不做**：支援 KaTeX、PlantUML、mermaid 以外的圖表語言 — 若未來要支援，應重新評估「整頁 WebView」方案。
- **不做**：限制同一份文件最多可渲染幾張 mermaid 圖，也不對大量圖表（> N 張）做 SVG 快取優化。本 change 允許任意張數（N 張圖 = N 個 WKWebView，記憶體隨張數線性成長），不加 UI warning、不加 placeholder threshold；已知限制（留待後續觀察）：實際文件若出現極端多圖（粗估 >10 張）時會吃掉明顯記憶體，對應的解法是另開 change 加 SVG 快取層（渲染後把 SVG snapshot 出來、以 `NSImageView` 顯示、卸掉 WebView），而不是在本 change 加硬上限。

## Capabilities

### New Capabilities

- `markdown-mermaid`: cmux Markdown panel 對 `` ```mermaid `` code block 的離線圖形化渲染能力，包含主題同步、錯誤就地顯示、與既有 Markdown 渲染路徑的隔離契約。

### Modified Capabilities

(none — Markdown panel 尚無既有 spec；本 change 首次定義 mermaid 行為。)

## Impact

- **Affected specs**: 新增 `openspec/specs/markdown-mermaid/spec.md`
- **Affected code**:
  - `Sources/Panels/MarkdownPanelView.swift`（新增 `.codeBlock` 語言分流）
  - `Sources/Panels/MermaidBlockView.swift`（**新增**）
  - `Sources/Panels/MermaidRenderer.swift`（**新增**，純值層的 block 抽取 / HTML 組裝，方便單元測試）
  - `Resources/Mermaid/mermaid.min.js`（**新增**，離線 bundle，固定版本）
  - `Resources/Mermaid/template.html`（**新增**，載入 mermaid.js 的最小 HTML 殼）
  - `GhosttyTabs.xcodeproj/project.pbxproj`（把上述 Resources 與新檔案加入 target）
  - `cmuxTests/MermaidRendererTests.swift`（**新增**，parser / HTML 組裝 runtime seam 測試）
- **Affected dependencies**: 無新增 SPM 套件；`MermaidBlockView` 僅使用系統 `WebKit`。
- **Affected bundle size**: 增加約 ~3.2 MB（`mermaid.min.js` v11.14.0 的 UMD minified build；v11 把所有圖表類型內嵌進單一 UMD bundle 後比早期估計值大），相對於 GhosttyKit.xcframework 可以忽略。
- **Affected runtime**: 不含 mermaid 的 Markdown 檔渲染路徑零變動；含 mermaid 的檔每段圖啟動一個 WKWebView（閒置約 20–40 MB / 個），預期一般文件 ≤ 5 張圖故可接受；極端情況（>10 張圖）留待後續優化（SVG 快取）另開 change 處理。
