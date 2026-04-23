import AppKit
import SwiftUI

/// Debug window for the screenshot panel. Entry point in `cmuxApp.swift` →
/// Debug → Debug Windows → Screenshot Panel Debug. Keeps per-option tweaks
/// out of Settings so v1 can ship without touching the main Settings UI.
final class ScreenshotPanelDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ScreenshotPanelDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Screenshot Panel Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.screenshotPanelDebug")
        window.center()
        window.contentView = NSHostingView(rootView: ScreenshotPanelDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ScreenshotPanelDebugView: View {
    @AppStorage(ScreenshotPanelSettingsKey.path) private var path: String = ""
    @AppStorage(ScreenshotPanelSettingsKey.showsRightSidebarTab)
    private var showsTab: Bool = true
    @AppStorage(ScreenshotPanelSettingsKey.viewMode)
    private var viewModeRaw: String = ScreenshotViewMode.defaultValue.rawValue

    private var resolvedPath: String {
        path.isEmpty ? ScreenshotPanelPathResolver.resolve() : path
    }

    var body: some View {
        GroupBox("Screenshot Panel") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(String(
                        localized: "debugMenu.screenshotPanel.resolvedPath",
                        defaultValue: "Current path:"
                    ))
                    .foregroundColor(.secondary)
                    Text(resolvedPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button(String(
                        localized: "debugMenu.screenshotPanel.chooseFolder",
                        defaultValue: "Choose Folder…"
                    )) {
                        pickFolder()
                    }
                    Button(String(
                        localized: "debugMenu.screenshotPanel.resetAutoDetect",
                        defaultValue: "Reset to Auto-detect"
                    )) {
                        path = ""
                    }
                }

                Picker(String(
                    localized: "debugMenu.screenshotPanel.viewMode",
                    defaultValue: "Default view mode"
                ), selection: $viewModeRaw) {
                    Text("Grid").tag(ScreenshotViewMode.grid.rawValue)
                    Text("List").tag(ScreenshotViewMode.list.rawValue)
                }
                .pickerStyle(.segmented)

                Toggle(String(
                    localized: "debugMenu.screenshotPanel.showsTab",
                    defaultValue: "Show Shots tab in right sidebar"
                ), isOn: $showsTab)
            }
            .padding(10)
        }
        .padding(16)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}
