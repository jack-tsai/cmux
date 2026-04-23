import AppKit
import SwiftUI
import WebKit

// Value-snapshot-only contract
// ============================
// The Markdown panel ancestor of this view operates under the snapshot-boundary
// rule (see CLAUDE.md and https://github.com/manaflow-ai/cmux/issues/2586).
// The three view types defined in this file — MermaidBlockView,
// MermaidWebViewRepresentable, and MermaidInlineErrorView — MUST NOT hold
// references to any ObservableObject / @Observable store via @ObservedObject,
// @EnvironmentObject, @StateObject, @Bindable, or plain `let store: SomeStore`
// properties. Rendering state flows in as immutable value snapshots (source,
// theme, message) plus closure action bundles; colorScheme is pulled via
// SwiftUI's @Environment which is value-typed. The Coordinator class is an
// implementation detail for the WKWebView bridge and does not cross into view
// input territory.

struct MermaidBlockView: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var measuredHeight: CGFloat = 120
    @State private var errorState: ErrorState?

    enum ErrorKind {
        case syntax
        case runtimeMissing
    }

    struct ErrorState: Equatable {
        let kind: ErrorKind
        let message: String
    }

    var body: some View {
        Group {
            if let errorState {
                MermaidInlineErrorView(
                    source: source,
                    kind: errorState.kind,
                    message: errorState.message
                )
            } else {
                MermaidWebViewRepresentable(
                    source: source,
                    theme: colorScheme == .dark ? .dark : .light,
                    onRendered: { height in
                        measuredHeight = height
                    },
                    onError: { kind, message in
                        errorState = ErrorState(kind: kind, message: message)
                    }
                )
                .frame(height: measuredHeight)
            }
        }
        .onChange(of: source) { _ in
            errorState = nil
        }
    }
}

private struct MermaidWebViewRepresentable: NSViewRepresentable {
    let source: String
    let theme: MermaidTheme
    let onRendered: (CGFloat) -> Void
    let onError: (MermaidBlockView.ErrorKind, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRendered: onRendered, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "cmuxMermaid")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lastAppliedSource = source
        context.coordinator.lastAppliedTheme = theme

        let html = MermaidRenderer.htmlDocument(source: source, theme: theme)
        let baseURL = MermaidRenderer.mermaidResourcesDirectory() ?? Bundle.main.bundleURL
        webView.loadHTMLString(html, baseURL: baseURL)
        context.coordinator.resetWatchdogForNewNavigation()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onRendered = onRendered
        context.coordinator.onError = onError
        context.coordinator.applyUpdate(source: source, theme: theme)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxMermaid")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onRendered: (CGFloat) -> Void
        var onError: (MermaidBlockView.ErrorKind, String) -> Void
        var lastAppliedSource: String = ""
        var lastAppliedTheme: MermaidTheme = .light

        private var watchdog: DispatchWorkItem?
        private var hasReceivedAnyBridgeMessage = false
        private var hasNavigated = false

        static let watchdogTimeout: TimeInterval = 15

        init(
            onRendered: @escaping (CGFloat) -> Void,
            onError: @escaping (MermaidBlockView.ErrorKind, String) -> Void
        ) {
            self.onRendered = onRendered
            self.onError = onError
        }

        func invalidate() {
            watchdog?.cancel()
            watchdog = nil
            webView = nil
        }

        func resetWatchdogForNewNavigation() {
            hasReceivedAnyBridgeMessage = false
            startWatchdog()
        }

        func startWatchdog() {
            watchdog?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.hasReceivedAnyBridgeMessage else { return }
                let message = String(
                    localized: "mermaid.error.timeoutMessage",
                    defaultValue: "mermaid runtime did not respond within 15 seconds"
                )
                self.onError(.runtimeMissing, message)
            }
            watchdog = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Coordinator.watchdogTimeout, execute: item)
        }

        func applyUpdate(source: String, theme: MermaidTheme) {
            let sourceChanged = source != lastAppliedSource
            let themeChanged = theme != lastAppliedTheme
            lastAppliedSource = source
            lastAppliedTheme = theme
            guard hasNavigated else { return }
            guard sourceChanged || themeChanged else { return }
            evaluateRender(source: source, theme: theme)
        }

        private func evaluateRender(source: String, theme: MermaidTheme) {
            guard let webView else { return }
            let sourceLiteral = MermaidRenderer.escape(source: source)
            let themeLiteral = MermaidRenderer.escape(source: theme.rawValue)
            let js = "window.cmuxMermaidRender(\(sourceLiteral), \(themeLiteral));"
            webView.evaluateJavaScript(js, completionHandler: nil)
            hasReceivedAnyBridgeMessage = false
            startWatchdog()
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasNavigated = true
            // Ensure whatever source/theme the user currently sees matches the latest
            // applied values even if they changed between makeNSView and didFinish.
            evaluateRender(source: lastAppliedSource, theme: lastAppliedTheme)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleNavigationFailure(error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(error: error)
        }

        private func handleNavigationFailure(error: Error) {
            watchdog?.cancel()
            onError(.runtimeMissing, error.localizedDescription)
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "cmuxMermaid" else { return }
            guard let body = message.body as? [String: Any] else { return }
            let type = body["type"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasReceivedAnyBridgeMessage = true
                self.watchdog?.cancel()
                switch type {
                case "rendered":
                    let height: CGFloat
                    if let h = body["height"] as? Double {
                        height = CGFloat(h)
                    } else if let h = body["height"] as? Int {
                        height = CGFloat(h)
                    } else if let h = body["height"] as? CGFloat {
                        height = h
                    } else {
                        height = 120
                    }
                    self.onRendered(max(24, height))
                case "error":
                    let kind: MermaidBlockView.ErrorKind
                    if let kindStr = body["kind"] as? String, kindStr == "runtimeMissing" {
                        kind = .runtimeMissing
                    } else {
                        kind = .syntax
                    }
                    let message = body["message"] as? String ?? ""
                    self.onError(kind, message)
                default:
                    break
                }
            }
        }
    }
}

private struct MermaidInlineErrorView: View {
    let source: String
    let kind: MermaidBlockView.ErrorKind
    let message: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("\(prefixText) — \(detailText)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.red)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            Text(source)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(colorScheme == .dark ? .white.opacity(0.85) : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    colorScheme == .dark
                        ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
                        : Color(nsColor: NSColor(white: 0.95, alpha: 1.0))
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(colorScheme == .dark ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        )
    }

    private var prefixText: String {
        String(
            localized: "mermaid.error.title",
            defaultValue: "Mermaid render failed"
        )
    }

    private var detailText: String {
        switch kind {
        case .syntax:
            return String(
                localized: "mermaid.error.syntax",
                defaultValue: "Mermaid syntax error"
            )
        case .runtimeMissing:
            return String(
                localized: "mermaid.error.runtimeMissing",
                defaultValue: "Mermaid runtime unavailable"
            )
        }
    }
}
