import AppKit
import SwiftUI

/// Main view for the right-sidebar `.screenshots` mode.
/// Layout (spec: Preview + gallery vertical layout):
///   - Toolbar (path label + Grid/List toggle + Refresh)
///   - Preview area, fixed 4:3 aspect
///   - Gallery (Grid or List, bound to `screenshotPanel.viewMode`)
///   - Truncated-footer when `store.isTruncated`
struct ScreenshotPanelView: View {
    @ObservedObject var store: ScreenshotStore

    /// Paste callback — wired to `TerminalImageTransfer` in Section 5.
    /// Takes the selected entry's URL.
    var onActivate: (URL) -> Void = { _ in }

    @AppStorage(ScreenshotPanelSettingsKey.viewMode)
    private var viewModeRaw: String = ScreenshotViewMode.defaultValue.rawValue

    @State private var selectedId: UUID?
    @State private var theme: ScreenshotPanelTheme = ScreenshotPanelTheme.make(
        from: GhosttyConfig.load()
    )
    @State private var previewImage: NSImage?
    @State private var now: Date = Date()

    /// Tick the `now` value every 30 s so the list view's relative-time labels
    /// refresh without individual row timers.
    private let relativeTimeTicker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var viewMode: ScreenshotViewMode {
        ScreenshotViewMode.resolve(rawValue: viewModeRaw)
    }

    private var selectedEntry: ScreenshotEntry? {
        guard let selectedId else { return nil }
        return store.entries.first(where: { $0.id == selectedId })
    }

    private var actions: ScreenshotGalleryActions {
        ScreenshotGalleryActions(
            onSelect: { id in
                selectedId = id
            },
            onActivate: { id in
                selectedId = id
                if let entry = store.entries.first(where: { $0.id == id }) {
                    onActivate(entry.url)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let error = store.loadError {
                emptyStateView(for: error)
            } else if store.entries.isEmpty {
                emptyStateView(for: nil)
            } else {
                previewArea
                Divider()
                galleryArea
                if store.isTruncated {
                    truncatedFooter
                }
            }
        }
        .background(theme.background)
        .onAppear {
            applyAutoSelection()
            refreshPreview()
        }
        .onChange(of: store.entries) { _ in
            applyAutoSelection()
            refreshPreview()
        }
        .onChange(of: selectedId) { _ in
            refreshPreview()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("com.cmuxterm.themes.reload-config")
        )) { _ in
            theme = ScreenshotPanelTheme.make(from: GhosttyConfig.load(useCache: false))
        }
        .onReceive(relativeTimeTicker) { tick in
            now = tick
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text((store.folderPath as NSString).lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.faint)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.folderPath)

            Spacer(minLength: 4)

            Button { store.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.dim)
            .help(String(
                localized: "screenshotPanel.toolbar.refresh",
                defaultValue: "Refresh"
            ))

            viewModeToggle
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 26)
    }

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            viewModeButton(mode: .grid, symbol: "square.grid.2x2")
            viewModeButton(mode: .list, symbol: "list.bullet")
        }
    }

    private func viewModeButton(mode: ScreenshotViewMode, symbol: String) -> some View {
        Button {
            viewModeRaw = mode.rawValue
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(viewMode == mode ? theme.foreground : theme.faint)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            Rectangle().fill(theme.cellBackground)
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if selectedEntry == nil {
                Text(String(
                    localized: "screenshotPanel.preview.empty",
                    defaultValue: "Select a screenshot to preview"
                ))
                .font(.system(size: 11))
                .foregroundColor(theme.faint)
            } else {
                ProgressView().scaleEffect(0.5)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }

    /// Thresholds that honor spec:
    ///   - > 512 KB → QLThumbnail at 1024 pt longest edge (safe for 100 MB files)
    ///   - ≤ 512 KB → direct `NSImage(contentsOf:)` for sharpness on small screenshots
    private func refreshPreview() {
        guard let entry = selectedEntry else {
            previewImage = nil
            return
        }
        let directReadThreshold = 512 * 1024
        if entry.byteSize <= directReadThreshold {
            previewImage = NSImage(contentsOf: entry.url)
            return
        }
        previewImage = nil
        ScreenshotThumbnailCache.shared.requestThumbnail(
            for: entry.url,
            mtime: entry.mtime,
            pixelSize: 1024
        ) { [entryId = entry.id] image in
            // Ignore if selection changed while we were generating.
            guard selectedId == entryId else { return }
            previewImage = image
        }
    }

    // MARK: - Gallery

    @ViewBuilder
    private var galleryArea: some View {
        switch viewMode {
        case .grid:
            ScreenshotGalleryGridView(
                entries: store.entries,
                selectedId: selectedId,
                theme: theme,
                actions: actions
            )
        case .list:
            ScreenshotGalleryListView(
                entries: store.entries,
                selectedId: selectedId,
                theme: theme,
                now: now,
                actions: actions
            )
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private func emptyStateView(for error: ScreenshotStoreError?) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "camera")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(theme.faint)
            Text(String(
                localized: "screenshotPanel.empty.title",
                defaultValue: "No screenshots yet"
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(theme.dim)
            Text(store.folderPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.faint)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
            if error == .folderMissing || error == .permissionDenied {
                Button {
                    presentFolderPicker()
                } label: {
                    Text(String(
                        localized: "screenshotPanel.empty.chooseFolder",
                        defaultValue: "Choose folder…"
                    ))
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: ScreenshotPanelSettingsKey.path)
        store.setPath(url.path)
    }

    // MARK: - Truncated footer

    private var truncatedFooter: some View {
        Text(String(
            format: String(
                localized: "screenshotPanel.truncated",
                defaultValue: "Showing most recent %d of %d"
            ),
            store.entries.count,
            store.totalCountInFolder
        ))
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(theme.faint)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }

    // MARK: - Auto-select

    private func applyAutoSelection() {
        guard let first = store.entries.first else {
            selectedId = nil
            return
        }
        if selectedId == nil {
            selectedId = first.id
            return
        }
        // If the previously-selected entry has been removed, fall back to the
        // newest file. Otherwise preserve the user's selection even when a
        // newer screenshot arrives and becomes entries[0] (spec requirement).
        if store.entries.contains(where: { $0.id == selectedId }) == false {
            selectedId = first.id
        }
    }
}
