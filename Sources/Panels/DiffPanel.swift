import Foundation
import Combine

/// Read-only unified diff viewer. Owns a single `FileDiff` snapshot computed
/// when the panel is first opened and refreshed on explicit user action or on
/// duplicate-open re-focus (task 3.14).
@MainActor
final class DiffPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .diff

    private(set) var workspaceId: UUID
    let workspaceDirectory: String
    let mode: DiffMode

    @Published private(set) var displayTitle: String
    var displayIcon: String? { "arrow.left.arrow.right.circle" }

    @Published private(set) var fileDiff: FileDiff?
    @Published private(set) var isLoading: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Monotonic counter bumped on every refresh so in-flight fetches that
    /// land out-of-order are dropped on the floor.
    private var loadGeneration: Int = 0

    init(
        workspaceId: UUID,
        workspaceDirectory: String,
        mode: DiffMode
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.workspaceDirectory = workspaceDirectory
        self.mode = mode
        self.displayTitle = Self.titleForMode(mode)
        refresh()
    }

    // MARK: - Panel protocol

    func focus() {
        // Read-only: no editable first responder.
    }

    func unfocus() {}

    func close() {
        loadGeneration &+= 1
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Refresh (tasks 3.4 / 3.14)

    /// Recompute the diff. Always off-main so we don't block the UI while
    /// `/usr/bin/git` runs.
    func refresh() {
        loadGeneration &+= 1
        let gen = loadGeneration
        let directory = workspaceDirectory
        let currentMode = mode
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = DiffProvider.fetchDiff(
                mode: currentMode,
                workingDirectory: directory
            )
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == gen else { return }
                self.fileDiff = diff
                self.isLoading = false
            }
        }
    }

    // MARK: - Title helpers

    private static func titleForMode(_ mode: DiffMode) -> String {
        switch mode {
        case .workingCopyVsHead(let path):
            return (path as NSString).lastPathComponent
        case .commitVsParent(_, let path):
            return (path as NSString).lastPathComponent
        }
    }

    /// Short sha (first 7 chars) suitable for toolbar scope labels.
    static func shortSha(_ sha: String) -> String {
        String(sha.prefix(7))
    }
}
