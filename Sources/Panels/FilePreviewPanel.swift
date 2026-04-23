import Foundation
import Combine

/// Read-only preview of any non-markdown file opened from File Explorer.
/// Snapshot model: loads once at init + on explicit `reload()`. No file watcher.
@MainActor
final class FilePreviewPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .filePreview

    /// Absolute path to the file being previewed.
    let filePath: String

    private(set) var workspaceId: UUID

    @Published private(set) var displayTitle: String
    var displayIcon: String? { "doc.text" }

    enum LoadState: Equatable, Sendable {
        case text(lines: [String], isTruncated: Bool)
        case binary
        case missing
    }

    @Published private(set) var state: LoadState = .text(lines: [], isTruncated: false)

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    // MARK: - Truncation limits (task 2.5)

    static let maxLines = 10_000
    static let maxBytes = 2 * 1_024 * 1_024  // 2 MB
    static let binarySnifferBytes = 8 * 1_024 // 8 KB NUL sniff (task 2.3)

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent
        reload()
    }

    // MARK: - Panel protocol

    func focus() {
        // Read-only: no first responder to acquire.
    }

    func unfocus() {
        // No-op.
    }

    func close() {
        // No background work to cancel.
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Loading (tasks 2.1, 2.3, 2.4, 2.5, 2.9)

    /// Re-read the file from disk and republish state. Called on init, on
    /// duplicate-open re-focus (task 2.9), and on manual refresh.
    func reload() {
        let path = filePath
        guard let data = FileManager.default.contents(atPath: path) else {
            state = .missing
            return
        }

        // Binary detection: NUL byte within the first `binarySnifferBytes`.
        let sniffLen = min(data.count, Self.binarySnifferBytes)
        let sniffed = data.prefix(sniffLen)
        if sniffed.contains(0) {
            state = .binary
            return
        }

        // Truncation: cap to 2 MB OR 10 000 lines, whichever comes first.
        let byteCapped: Data
        var truncatedByBytes = false
        if data.count > Self.maxBytes {
            byteCapped = data.prefix(Self.maxBytes)
            truncatedByBytes = true
        } else {
            byteCapped = data
        }

        let decoded: String
        if let utf8 = String(data: byteCapped, encoding: .utf8) {
            decoded = utf8
        } else if let latin1 = String(data: byteCapped, encoding: .isoLatin1) {
            decoded = latin1
        } else {
            state = .binary
            return
        }

        // Split preserving empty trailing lines so line numbers line up with
        // what users expect from `cat -n`.
        var lines = decoded.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" }
        ).map(String.init)

        var truncatedByLines = false
        if lines.count > Self.maxLines {
            lines = Array(lines.prefix(Self.maxLines))
            truncatedByLines = true
        }

        state = .text(lines: lines, isTruncated: truncatedByBytes || truncatedByLines)
    }
}
