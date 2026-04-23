## ADDED Requirements

### Requirement: Render mermaid code blocks as diagrams in the Markdown panel

The Markdown panel SHALL detect fenced code blocks whose language identifier is `mermaid` (case-sensitive) and render them as graphical diagrams instead of as plain monospaced text. Code blocks with any other language identifier, or with no language identifier, SHALL continue to use the existing monospaced code block rendering and MUST NOT be affected by this change.

#### Scenario: Mermaid block is rendered as a diagram

- **WHEN** a Markdown document containing a fenced code block with language `mermaid` and valid syntax is opened in the Markdown panel
- **THEN** the panel displays the rendered diagram (an SVG produced by the bundled mermaid runtime) in place of the raw source text

#### Scenario: Non-mermaid code blocks are unaffected

- **WHEN** a Markdown document contains fenced code blocks with languages such as `swift`, `bash`, `json`, or no language at all
- **THEN** those code blocks are rendered by the existing monospaced code block path and their appearance, selection behavior, and layout are identical to the behavior before this change

#### Scenario: Multiple mermaid blocks in one document render independently

- **WHEN** a Markdown document contains two or more `mermaid` fenced code blocks
- **THEN** each block is rendered as its own independent diagram and the failure of any one block MUST NOT prevent the others from rendering

### Requirement: Mermaid rendering SHALL operate fully offline

The Markdown panel SHALL render mermaid diagrams without making any network requests. The mermaid JavaScript runtime and its HTML host document MUST be loaded from resources embedded in the application bundle.

#### Scenario: Rendering succeeds with no network connectivity

- **WHEN** the user opens a Markdown document containing a `mermaid` code block while the host machine has no network connectivity
- **THEN** the diagram is rendered successfully using only bundled resources

#### Scenario: No outbound network requests are issued

- **WHEN** a `mermaid` code block is rendered
- **THEN** the embedded WebView issues zero outbound HTTP(S) requests to hosts other than the local bundle URL

### Requirement: Mermaid diagram size SHALL match its rendered content

The rendered mermaid diagram SHALL be displayed at a height that matches the intrinsic height of the produced SVG, so that no inner scrollbar appears inside the diagram view when the outer Markdown panel has enough vertical space to display it in full.

#### Scenario: Diagram view height equals rendered SVG height

- **WHEN** a mermaid diagram finishes rendering inside the Markdown panel
- **THEN** the SwiftUI container for that diagram reports a height equal to the SVG's measured content height (within a single CSS pixel of tolerance)

#### Scenario: Diagram re-renders larger content without clipping

- **WHEN** the source of a mermaid block changes to a larger diagram (more nodes, longer layout)
- **THEN** the diagram view's height updates to the new SVG's content height without clipping and without introducing a nested scrollbar

### Requirement: Mermaid rendering SHALL follow the active color scheme

The mermaid renderer SHALL use a dark palette when the Markdown panel's SwiftUI environment color scheme is `.dark`, and a light palette when it is `.light`. Changing the color scheme while a diagram is displayed MUST update the diagram to the new palette without recreating the underlying WebView instance, without flashing a blank or white frame, and without losing the diagram's content.

#### Scenario: Diagram uses dark palette in dark mode

- **WHEN** the Markdown panel is displayed with `colorScheme == .dark` and a `mermaid` block is rendered
- **THEN** the diagram is rendered using mermaid's dark theme (dark background, light foreground strokes and text)

#### Scenario: Palette updates live when color scheme changes

- **WHEN** a mermaid diagram is visible and the system color scheme switches from light to dark (or vice versa)
- **THEN** the diagram is re-themed to the new palette while the same WebView instance is reused and the user does not see a blank or white flash

### Requirement: Mermaid syntax errors SHALL be reported in-place

When a mermaid code block fails to parse or render, the Markdown panel SHALL display a localized inline error view that identifies the failure and shows the original source text, without raising modal dialogs and without affecting the rendering of any other element in the document. The same inline error view SHALL also be shown when the bundled mermaid runtime fails to load (for example, a JavaScript load error, a WebView navigation failure, or no `rendered` / `error` message received from the bridge within a fixed timeout of 15 seconds after navigation completes), using a distinct localized message that identifies it as a runtime-load failure rather than a syntax failure.

#### Scenario: Invalid mermaid source shows inline error

- **WHEN** a `mermaid` code block contains a syntax error that mermaid rejects
- **THEN** the block area displays a localized error heading, the error message returned by mermaid, and the original source text in a monospaced style

#### Scenario: One broken diagram does not break the document

- **WHEN** a document contains one invalid `mermaid` block and one valid `mermaid` block
- **THEN** the valid block renders normally as a diagram and the invalid block shows the inline error view

#### Scenario: Error text is localized

- **WHEN** the application runs with a non-English supported locale (for example, Japanese)
- **THEN** the error heading and any fixed accompanying copy are shown in that locale via `String(localized:)` keys declared in `Resources/Localizable.xcstrings`

#### Scenario: Missing or unloadable mermaid runtime reports a distinct message

- **WHEN** the bundled `mermaid.min.js` fails to load (absent from the bundle, rejected by CSP, WebView navigation error) or no `rendered` / `error` message arrives within 15 seconds of navigation completion
- **THEN** the block area displays the inline error view using the `mermaid.error.runtimeMissing` localized copy (distinct from the syntax-error copy) together with the original source text, and other mermaid blocks in the same document are unaffected

### Requirement: Mermaid rendering SHALL treat source text as untrusted input

The Markdown panel SHALL treat the contents of a `mermaid` code block as untrusted text. Source text MUST be HTML-escaped before being injected into the WebView's HTML document, and the WebView's content security policy MUST restrict resource loading to the application bundle origin.

#### Scenario: HTML-like content in source does not escape the diagram context

- **WHEN** a `mermaid` code block contains text that looks like HTML or script tags (for example `<script>alert(1)</script>` or `<img src=x onerror=...>`)
- **THEN** that text is passed to mermaid as literal DSL input and is not interpreted as HTML or JavaScript by the WebView

#### Scenario: WebView refuses external resource loads

- **WHEN** the rendered HTML template attempts (or is induced by mermaid source to attempt) to fetch a resource from a non-bundle origin
- **THEN** the WebView blocks the request per its content security policy

### Requirement: Non-mermaid Markdown rendering SHALL remain unchanged

The introduction of mermaid support MUST NOT alter the rendering, theming, text selection, or focus behavior of any Markdown element other than fenced code blocks whose language identifier is `mermaid`.

#### Scenario: Existing theme, selection, and focus behavior preserved

- **WHEN** a Markdown document that contains no `mermaid` code blocks is rendered after this change
- **THEN** its visual appearance (headings, paragraphs, tables, blockquotes, lists, inline code, links, non-mermaid code blocks), its native text-selection behavior, and the Markdown panel's first-click focus contract are identical to the behavior before this change
