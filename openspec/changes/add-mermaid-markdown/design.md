## Context

cmux 目前以 `gonzalezreal/swift-markdown-ui`（SPM）在 `Sources/Panels/MarkdownPanelView.swift` 渲染 `.md` 檔，`.codeBlock` 已在 `cmuxMarkdownTheme` 客製化過（包 `ScrollView` + 等寬字型 + dark/light 背景），但對 `mermaid` 語言的 code block 不做任何特殊處理。使用者因此無法在 cmux 內檢視 architecture 文件、Spectra 的 `design.md`、Swift 社群 README 等含 mermaid 圖表的檔案 — 這是和 GitHub/VSCode/Obsidian 平台之間最顯眼的一處落差。

約束（來自 `CLAUDE.md` 與專案現況）：

- cmux 是離線可用的桌面 app，外部依賴（Node、CDN）不可接受。
- 打字延遲敏感路徑（`WindowTerminalHostView.hitTest()`、`TabItemView`、`TerminalSurface.forceRefresh()`）不得被影響；mermaid 渲染必須在 Markdown panel 子樹內部完成，不得污染到終端機或 sidebar。
- 所有使用者可見字串必須以 `String(localized:)` 本地化（目前 en / ja）。
- 測試必須驗 observable runtime 行為，不可驗原始碼文字或 plist 內容；WebView 像素快照不穩定，不列入。
- `Snapshot boundary for list subtrees` 規則：Markdown panel 的子樹不得持有 `ObservableObject` 參考 — mermaid view 必須用值快照 + closure actions。
- 主執行緒工作應保持輕量；WebView 的載入與 JS 執行天然非同步，不會阻塞主緒，但 SwiftUI 端的 height 更新必須避免 body 內 state mutation（違反 CLAUDE.md 的「No state mutation inside view-body computations」規則）。

## Goals / Non-Goals

**Goals:**

- 支援 GitHub-Flavored Markdown 中的 `` ```mermaid `` code block；同一份文件多張圖各自獨立渲染。
- 完全離線：mermaid.js 以 bundle resource 內嵌，不連網、不外部執行檔。
- 主題同步：dark / light 跟隨 `@Environment(\.colorScheme)`，不重建 WebView、不閃爍、不丟捲動位置。
- 高度自適應：mermaid 渲染後 SVG 的 intrinsic height 回傳給 SwiftUI，以 `.frame(height:)` 顯示，不造成雙層 scroll。
- 語法錯誤就地顯示紅色錯誤訊息 + 原始 mermaid 碼，不影響同份文件其他元素。
- 既有非 mermaid 的 Markdown 渲染路徑行為零變動；非 mermaid 文件零效能回歸。
- 爆炸半徑最小 — 失敗時僅影響 `` ```mermaid `` 分支，其他 Markdown 不波及。

**Non-Goals:**

- 不把整份 Markdown 改以 WebView 渲染（放棄 `cmuxMarkdownTheme` 與原生文字選取的成本過高，未被需要）。
- 不依賴 `mmdc` 或任何外部 CLI / Node runtime。
- 不自行用 Swift 實作 mermaid 解析 / 繪圖。
- 不為 mermaid 提供獨立設定 UI（theme、字型、direction 等跟隨系統外觀）。
- 不在 Sidebar Markdown preview 支援 mermaid（純文字摘要場景不需要）。
- 不支援 KaTeX / PlantUML / 其他圖表 DSL；若未來需要，重新評估整頁 WebView 方案。
- 不對大量圖表（>10 張）做 SVG 快取優化；留待後續實測需要時另開 change。

## Decisions

### 在 swift-markdown-ui 的 `.codeBlock` 客製化中對 `mermaid` 語言分流

**選擇**：於 `MarkdownPanelView.cmuxMarkdownTheme` 的 `.codeBlock` closure 檢查 `configuration.language`；若為 `mermaid`，回傳 `MermaidBlockView(source: configuration.content.code)`，其他語言維持既有 `ScrollView` + 等寬字型渲染。

**理由**：

- 爆炸半徑最小：只影響單一分支，其他 Markdown 元素（heading、table、blockquote、list、inline code、link）零變動。
- 可逆：日後若升級到「整頁 WebView」或 SVG 快取方案，只要置換 `MermaidBlockView`，無技術債。
- 符合 swift-markdown-ui 的官方擴充點（theme block closure），不破壞升級路徑。

**被考慮、否決的選項**：

- **整頁 WebView（markdown-it + mermaid.js）**：完整度最高、但放棄 `cmuxMarkdownTheme`（140+ 行 dark/light 主題）、原生 `textSelection`、`MarkdownPointerObserver` 的 first-click focus 契約；回歸風險擴及所有 .md 檔，不等比例。
- **`mmdc` CLI 預渲染 SVG**：需 Node 依賴，違反離線定位。
- **純 Swift 實作 mermaid**：工程量 + 上游追版成本不合理。

### 每個 mermaid block 一個獨立 `WKWebView`

**選擇**：`MermaidBlockView: NSViewRepresentable` 內部持有一個 `WKWebView`；同一份文件 N 張圖 = N 個 WebView。

**理由**：

- 獨立失敗域：一張圖語法錯誤或 JS 當掉不影響其他圖。
- intrinsic height 計算簡單：每個 WebView 只量自己那張 SVG，不需要跨圖協調。
- 符合 SwiftUI 的 `ForEach` / list-rendering 習慣；每個 view 管自己的生命週期。

**被考慮、否決**：「整頁一個共用 WebView 渲染所有圖」— 多圖時 height 協調複雜、單圖失敗擴散、且需要自行組 HTML 文件結構重做一套 layout；收益僅在 >10 張圖時出現，屬 YAGNI。

**風險緩解**：單 WebView 閒置 ~20–40 MB；常見文件 ≤ 5 張圖可接受。若實測出現極端案例，後續開 change 追加「渲染後 snapshot 成 SVG 字串 → 換成 `NSImageView`，卸掉 WebView」的優化層。

### 以 JS→Swift Bridge 回報 intrinsic height

**選擇**：HTML 模板中 mermaid 完成渲染後，測量 `<body>` 的 `scrollHeight`（或 SVG 的 `getBoundingClientRect().height`），透過 `webkit.messageHandlers.cmuxMermaid.postMessage({ type: "rendered", height, error? })` 送回 Swift；`WKScriptMessageHandler` 收訊後在主執行緒 `async` 更新 `@State height`。

**理由**：

- 精準：直接量 DOM，比輪詢 `evaluateJavaScript("document.body.scrollHeight")` 更穩、不需要 timer。
- 單次事件：mermaid 完成一次就通報一次；colorScheme 變動再觸發一次。
- 避開 view-body state mutation：update 發生在 `messageHandler` callback，不在 `body` 計算中（符合 CLAUDE.md 規則）。

**被考慮、否決**：輪詢 `evaluateJavaScript` — 時序不穩、額外 CPU。

### mermaid.js 以 bundle resource 離線內嵌

**選擇**：在 `Resources/Mermaid/mermaid.min.js` 放固定版本（建議 `v11.x` 最新穩定版，UMD build），另一支 `Resources/Mermaid/template.html` 作為 WebView 的初始 HTML 殼（含 `<script src="mermaid.min.js">`、mermaid 初始化程式碼、bridge callback）。`MermaidBlockView` 用 `WKWebView.loadFileURL(_:allowingReadAccessTo:)` 從 `Bundle.main` 載入，`baseURL` 指向 Resources 目錄以便讀取同層 JS。

**理由**：

- 離線可用（核心需求）。
- 固定版本 = 可預期的渲染結果，不會因為 CDN 改版而造成回歸。
- `loadFileURL` 讓同源政策乾淨，不需要放寬 CSP。

**被考慮、否決**：CDN（需網路、不可預期、違反離線）。

**mermaid 版本選擇原則**：挑當下 `@latest` 的 UMD minified build，落版於 `Resources/Mermaid/VERSION.txt` 以供追蹤；未來升級獨立 PR，搭配 snapshot 文件（手動挑幾張典型圖人工目視驗證）。

### Dark / Light 以 `mermaid.initialize({ theme })` + `mermaid.run()` 切換，不重建 WebView

**選擇**：`MermaidBlockView` observe `@Environment(\.colorScheme)`，變動時 `evaluateJavaScript("window.cmuxMermaidSetTheme('dark' | 'default')")`；該 JS 函式於 template 中實作，內部做 `mermaid.initialize({ theme })` 後清空輸出 `<div id="diagram">` 並重新 `mermaid.run()`。

**理由**：

- 無閃爍：WebView 本身持續存在，只 re-render SVG。
- 不丟狀態：未來若要讓使用者縮放 / pan 圖，WebView scroll 位置保留。
- 符合 CLAUDE.md「No state mutation inside view-body computations」— 切換動作由 `onChange(of: colorScheme)` 觸發的 side-effect 執行。

**被考慮、否決**：colorScheme 變動時重建 WebView — 有閃爍、丟狀態、且耗 CPU。

### 值層抽出 `MermaidRenderer`（parser / HTML 組裝）以供單元測試

**選擇**：新增 `Sources/Panels/MermaidRenderer.swift`，提供純值函式：

- `MermaidRenderer.htmlDocument(source: String, theme: MermaidTheme) -> String`：把 mermaid source 與 theme 組成完整 HTML（讀取 `template.html` 後注入 `{{SOURCE}}`、`{{THEME}}`）。
- `MermaidRenderer.escape(source: String) -> String`：HTML-escape mermaid 原始碼以避免 injection。

`MermaidBlockView` 只負責把結果塞進 `WKWebView`；所有可測試邏輯（escape、模板注入、theme 字串映射）都在 `MermaidRenderer` 純值層。

**理由**：

- 符合 CLAUDE.md 「Tests must verify observable runtime behavior through executable paths」— 透過 `MermaidRenderer` 的 public API 測 escape / 注入 / theme 映射，是 runtime seam 而非 source-text 驗證。
- 避免在 UI 測試中反覆啟 WebView。

### 語法錯誤就地顯示紅底錯誤訊息

**選擇**：template 的 bridge 對 mermaid `parseError` 事件送 `{ type: "error", message }`；`MermaidBlockView` 收訊後切到錯誤狀態，改顯示 SwiftUI 的 `VStack`：`Label("Mermaid render failed", systemImage: "exclamationmark.triangle")` + `Text(message)` + 原始 mermaid source（等寬字型、紅色邊框）。錯誤字串以 `String(localized:)` 本地化。

**理由**：

- 就地顯示 = 使用者能立刻看出是哪張圖壞了；其他圖與其他 Markdown 元素不受影響。
- 不彈 Alert、不 dlog spam — 壞掉的文件不會打擾使用者。

### 內容變更（`panel.content` 改變）時以 token 觸發 re-render，不換 WebView

**選擇**：`MermaidBlockView` 以 `source: String` 為主要識別；`onChange(of: source)` 時 `evaluateJavaScript("window.cmuxMermaidRender(\(jsonEncoded))")` 重新渲染；WebView 本身不重建。

**理由**：

- 檔案在編輯中被修改（例如另一個 agent 改了 `design.md`）時平滑更新。
- 重建 WebView 會閃爍、丟資源。

### 測試策略 — 只測 runtime seam，不做 WebView 像素快照

**選擇**：新增 `cmuxTests/MermaidRendererTests.swift`，測試 `MermaidRenderer.htmlDocument` / `escape` 的行為（例如：`<script>` 注入的 source 會被 escape、theme 值會正確注入）。不新增 WebView 的 UI 測試（違反 `CLAUDE.md` 測試政策的不穩定像素比對）。

**理由**：符合 CLAUDE.md「Test quality policy」— 驗 executable path 而非原始碼文字或 plist。

## Risks / Trade-offs

- **多 WebView 記憶體成本**：每個 WKWebView 閒置 ~20–40 MB。**Mitigation**：常見文件 ≤ 5 張圖可接受；實測若出現極端文件（>10 張）再開 change 加 SVG 快取。
- **mermaid.js 版本鎖死 → 安全 / 功能回歸**：內嵌版本若有 XSS / 崩潰 bug 無法即時收到 CDN fix。**Mitigation**：`Resources/Mermaid/VERSION.txt` 追蹤版本；release 前 check mermaid GitHub release 看有沒有 security advisory；升級由獨立 PR 處理並搭配人工目視測試。
- **WKWebView 啟動延遲**：第一張圖首開 cold-start 可能 100–300 ms。**Mitigation**：WebView 顯示期間以 placeholder（低飽和背景 + loading indicator）遮蓋；不造成阻塞。
- **mermaid source 內含惡意 HTML / JS**：使用者可能開啟不信任的 .md（例如從不信任來源 clone 的 repo 中的 README）。**Mitigation**：`MermaidRenderer.escape` 對 source 做 HTML entity escape；mermaid.js 自身會把輸入視為 DSL 不執行；WebView 以 `loadFileURL` 同源，禁止外部 fetch（可於 template 加 CSP `default-src 'self'`）。
- **主題切換瞬間 SVG 消失再出現**：`mermaid.run()` 重繪過程會短暫清空 DOM。**Mitigation**：template 中切換前先把舊 SVG 以 `opacity 0.3` 淡化，新 SVG 出現後恢復，讓過程柔和。
- **測試無法覆蓋實際 mermaid 解析**：`MermaidRendererTests` 只驗 HTML 組裝層，實際 `mermaid.js` 行為未被自動化驗證。**Mitigation**：接受這個限制；升級 mermaid.js 時以人工目視驗證主要圖表類型（flowchart / sequence / class / state）。
- **與 `Snapshot boundary for list subtrees` 規則的互動**：Markdown panel 本身已遵守該規則；`MermaidBlockView` 不持有任何 `ObservableObject`，只接收值型 `source: String` 與 closure。**Mitigation**：code review 檢查，並加註釋說明此 view 的 value-snapshot-only 契約。

## Migration Plan

本 change 為純新增功能，無 migration 需求：

1. 新增 `Resources/Mermaid/mermaid.min.js` + `template.html`，納入 app target resources。
2. 新增 `MermaidRenderer.swift`、`MermaidBlockView.swift`。
3. 修改 `MarkdownPanelView.cmuxMarkdownTheme` 的 `.codeBlock` closure 加 `mermaid` 分流。
4. 新增 `MermaidRendererTests.swift`。
5. 用 `./scripts/reload.sh --tag mermaid` 在一份含典型 mermaid 圖的 .md 上手動驗收。

**Rollback**：單 PR revert 即可；沒有資料 / 設定遷移。

## Open Questions

- **同文件 mermaid 圖表數量上限**（已決）：**不設上限**。本 change 允許任意張數，記憶體成本隨張數線性成長（每 WebView 閒置 20–40 MB）。已在 `proposal.md` Non-Goals 記下此為已知待觀察項目；若日後實測出現痛點，解法是另開 change 加 SVG 快取層，而非在此加硬上限或 UI warning。
- **mermaid 版本鎖定策略**（已決）：apply 階段下載當時 `v11.x` 的最新穩定 UMD minified build 後，**pin 到確切的 `major.minor.patch` 版本**（例如 `11.6.0`），把該字串寫入 `Resources/Mermaid/VERSION.txt`，並在 commit message 與 `tasks.md` 1.1 的 PR 描述中記錄。`mermaid.min.js` 從此不再跟著 upstream 漂移；任何版本升級（含 patch）都必須是獨立 PR，伴隨人工目視驗收 flowchart / sequence / class / state 四種典型圖。這確保測試穩定性與渲染結果可重現。
- **mermaid runtime 載入失敗的 fallback**（已決）：沿用 `語法錯誤就地顯示紅底錯誤訊息` 的同一個錯誤視圖，但訊息走獨立的 `mermaid.error.runtimeMissing` localization key，與 `mermaid.error.syntax` 區分。觸發條件有三：(a) template.html 的 `window.onerror` / `window.addEventListener('error')` 捕捉到 `mermaid.min.js` 載入失敗；(b) `WKNavigationDelegate.webView(_:didFailProvisionalNavigation:withError:)` 被呼叫；(c) Swift 端於 navigation 完成後起一個 15 秒 timer，到期仍未收到任何 `rendered` 或 `error` bridge 訊息就視為 runtime 不可用。三種情況都走同一個錯誤 view，只是文案不同；timer 在第一次收到 bridge 訊息後取消。
- **大 SVG 的高度上限**（已決）：**不加 cap**。無論 SVG 多高，`MermaidBlockView` 都以 intrinsic height 顯示，由 Markdown panel 自身的外層 `ScrollView`（`MarkdownPanelView.swift:49` 的 `ScrollView { VStack { ... } }`）提供垂直捲動。禁止在 `MermaidBlockView` 內部加入 `maxHeight` 或內層 `ScrollView` — 避免雙層 scroll 體驗不一致，也和 GitHub / VSCode 的 mermaid 預覽行為對齊。日後若實測出現「一張圖把整頁擠到看不到後文」的痛點，再另開 change 評估「長圖自動 fit-to-width / 縮小預覽」類的 UX 方案，不退回到 cap + inner scroll。
