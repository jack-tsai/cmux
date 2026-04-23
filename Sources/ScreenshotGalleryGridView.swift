import AppKit
import SwiftUI

/// Action bundle passed down to gallery cells — avoids child views capturing
/// the `ScreenshotStore` directly (CLAUDE.md "Snapshot boundary for list
/// subtrees"). All closures are main-thread.
struct ScreenshotGalleryActions {
    let onSelect: (UUID) -> Void
    let onActivate: (UUID) -> Void
}

// MARK: - Grid view

/// Adaptive `LazyVGrid` of 4:3 thumbnail cells. Single-click selects,
/// double-click triggers `onActivate` (paste to terminal — wired in Section 5).
struct ScreenshotGalleryGridView: View {
    let entries: [ScreenshotEntry]
    let selectedId: UUID?
    let theme: ScreenshotPanelTheme
    let actions: ScreenshotGalleryActions

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 6)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(entries, id: \.id) { entry in
                    ScreenshotGridCell(
                        snapshot: .init(
                            id: entry.id,
                            url: entry.url,
                            mtime: entry.mtime,
                            isSelected: entry.id == selectedId
                        ),
                        theme: theme,
                        actions: actions
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Cell

private struct ScreenshotGridCell: View {
    struct Snapshot: Equatable {
        let id: UUID
        let url: URL
        let mtime: Date
        let isSelected: Bool
    }

    let snapshot: Snapshot
    let theme: ScreenshotPanelTheme
    let actions: ScreenshotGalleryActions

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.cellBackground)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .foregroundColor(theme.faint)
                    .font(.system(size: 12))
            }

            if snapshot.isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(theme.selection, lineWidth: 2)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.onActivate(snapshot.id) }
        .onTapGesture { actions.onSelect(snapshot.id) }
        .task(id: ScreenshotThumbnailCache.cacheKey(url: snapshot.url, mtime: snapshot.mtime)) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ScreenshotThumbnailCache.shared.requestThumbnail(
                for: snapshot.url,
                mtime: snapshot.mtime,
                pixelSize: 120
            ) { image in
                self.image = image
                continuation.resume()
            }
        }
    }
}
