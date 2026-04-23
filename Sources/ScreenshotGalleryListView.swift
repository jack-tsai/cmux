import AppKit
import SwiftUI

/// `LazyVStack` list view: 32×24 thumbnail + filename + relative time.
struct ScreenshotGalleryListView: View {
    let entries: [ScreenshotEntry]
    let selectedId: UUID?
    let theme: ScreenshotPanelTheme
    let now: Date
    let actions: ScreenshotGalleryActions

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.id) { entry in
                    ScreenshotListRow(
                        snapshot: .init(
                            id: entry.id,
                            url: entry.url,
                            mtime: entry.mtime,
                            filename: entry.url.lastPathComponent,
                            relativeTime: ScreenshotRelativeTimeFormatter.format(entry.mtime, now: now),
                            isSelected: entry.id == selectedId
                        ),
                        theme: theme,
                        actions: actions
                    )
                }
            }
        }
    }
}

// MARK: - Row

private struct ScreenshotListRow: View {
    struct Snapshot: Equatable {
        let id: UUID
        let url: URL
        let mtime: Date
        let filename: String
        let relativeTime: String
        let isSelected: Bool
    }

    let snapshot: Snapshot
    let theme: ScreenshotPanelTheme
    let actions: ScreenshotGalleryActions

    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.cellBackground)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .frame(width: 72, height: 54)

            Text(snapshot.filename)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.dim)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(snapshot.relativeTime)
                .font(.system(size: 11))
                .foregroundColor(theme.faint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            snapshot.isSelected
                ? theme.selection.opacity(0.20)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.onActivate(snapshot.id) }
        .onTapGesture { actions.onSelect(snapshot.id) }
        .contextMenu { ScreenshotEntryContextMenu(url: snapshot.url, id: snapshot.id, actions: actions) }
        .draggable(ScreenshotDragPayload(url: snapshot.url)) {
            Text(snapshot.filename)
                .font(.system(size: 11, design: .monospaced))
        }
        .task(id: ScreenshotThumbnailCache.cacheKey(url: snapshot.url, mtime: snapshot.mtime)) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ScreenshotThumbnailCache.shared.requestThumbnail(
                for: snapshot.url,
                mtime: snapshot.mtime,
                pixelSize: 192
            ) { image in
                self.image = image
                continuation.resume()
            }
        }
    }
}
