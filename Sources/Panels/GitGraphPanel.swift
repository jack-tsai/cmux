import Foundation
import Combine

/// Main-area panel that renders a read-only git commit graph for the workspace
/// it is bound to.
///
/// Mirrors the read-only, value-driven design of `MarkdownPanel`: the panel
/// owns state (current snapshot, filter, search query, scroll anchor) but does
/// not mutate the repository. All `git` subprocess work runs off-main via
/// `GitGraphProvider` and the resulting snapshot is published on the main actor.
@MainActor
final class GitGraphPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .gitGraph

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Absolute directory that anchors the graph (workspace root or git worktree).
    let workspaceDirectory: String

    @Published private(set) var displayTitle: String
    var displayIcon: String? { "chart.bar.doc.horizontal" }

    // MARK: - Panel state (Task 1.2)

    /// Last successful snapshot rendered by the view. `nil` until first load.
    @Published private(set) var snapshot: GitGraphSnapshot?

    /// `nil` == "All branches"; otherwise the single selected branch name.
    @Published var branchFilter: String?

    /// Search mode: highlight (keep all rows) vs. filter (hide non-matches).
    enum SearchMode: String, Codable { case highlight, filter }
    @Published var searchMode: SearchMode = .highlight
    @Published var searchQuery: String = ""

    /// Scroll restoration target: SHA of the row that should be at the top of
    /// the viewport after a refresh. Fallback to top if SHA no longer loaded.
    @Published var scrollAnchorSha: String?
    @Published var scrollAnchorOffset: CGFloat = 0

    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var loadError: String?

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    // MARK: - Init

    init(workspaceId: UUID, workspaceDirectory: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.workspaceDirectory = workspaceDirectory
        self.displayTitle = "Git Graph"
    }

    // MARK: - Panel protocol

    func focus() {
        // Read-only panel; no first responder to manage.
    }

    func unfocus() {
        // No-op.
    }

    func close() {
        // No background observers yet (file watcher not added per design —
        // refresh is user / focus / workspace-switch triggered). Nothing to
        // tear down.
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Data loading (Task 2.1)

    /// Reloads the full snapshot from scratch. Safe to call repeatedly;
    /// concurrent calls are serialized by re-entering on the main actor.
    func reload(limit: Int = 500) {
        isLoading = true
        loadError = nil
        let directory = workspaceDirectory
        let filter = branchFilter

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let repoState = GitGraphProvider.detectRepoState(directory: directory)
            var snapshot = GitGraphSnapshot.empty
            if case .repo(_, let hasCommits) = repoState {
                let commits = hasCommits
                    ? GitGraphProvider.fetchCommits(
                        directory: directory,
                        limit: limit,
                        branchFilter: filter
                    )
                    : []
                let head = GitGraphProvider.fetchHeadSha(directory: directory)
                let branch = GitGraphProvider.fetchHeadBranch(directory: directory)
                let uncommitted = GitGraphProvider.fetchUncommittedCount(directory: directory)
                snapshot = GitGraphSnapshot(
                    repoState: repoState,
                    commits: commits,
                    headSha: head,
                    headBranch: branch,
                    isDetachedHead: branch == nil && head != nil,
                    uncommittedCount: uncommitted,
                    branches: [],
                    tags: [],
                    stashes: [],
                    worktrees: [],
                    hasMoreCommits: commits.count >= limit
                )
            } else {
                snapshot = GitGraphSnapshot(
                    repoState: repoState,
                    commits: [],
                    headSha: nil,
                    headBranch: nil,
                    isDetachedHead: false,
                    uncommittedCount: 0,
                    branches: [],
                    tags: [],
                    stashes: [],
                    worktrees: [],
                    hasMoreCommits: false
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snapshot
                self.isLoading = false
                self.lastRefreshAt = Date()
            }
        }
    }
}
