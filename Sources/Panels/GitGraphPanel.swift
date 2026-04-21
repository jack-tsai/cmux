import Foundation
import Combine

/// Settings that tune how many commits the Git Graph panel loads per page.
/// Persisted via `@AppStorage` under key `gitGraph.commitsPerLoad`, read with
/// clamping so `defaults write com.cmuxterm.app gitGraph.commitsPerLoad -int N`
/// never produces an out-of-range batch.
enum GitGraphSettings {
    static let commitsPerLoadKey = "gitGraph.commitsPerLoad"
    static let defaultCommitsPerLoad = 500
    static let minCommitsPerLoad = 100
    static let maxCommitsPerLoad = 2000

    /// Returns the configured batch size, clamped to `[min, max]`. Any missing
    /// or zero value falls back to the default (Settings may persist 0 when
    /// the field is blank).
    static func commitsPerLoad(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: commitsPerLoadKey)
        let resolved = stored == 0 ? defaultCommitsPerLoad : stored
        return max(minCommitsPerLoad, min(maxCommitsPerLoad, resolved))
    }
}

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
    @Published private(set) var isLoadingMore: Bool = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var loadError: String?

    /// SHA of the currently expanded commit row. Nil when no row is expanded.
    @Published var expandedCommitSha: String?

    /// In-memory cache of commit-detail lookups so expanding the same row
    /// twice (or clicking back to a previous selection) is instant.
    @Published private(set) var commitDetailCache: [String: CommitDetail] = [:]
    @Published private(set) var loadingDetailSha: String?

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    // MARK: - Load generation (Task 3.5)

    /// Monotonic counter bumped on every reload + loadMore. Background fetches
    /// capture their launch generation and drop their result on the floor when
    /// the generation has advanced — satisfies the "refresh cancels in-flight
    /// Load More" requirement without touching GCD's weak cancellation model.
    private var loadGeneration: Int = 0

    /// Maximum age of `lastRefreshAt` before `refreshIfStale()` triggers a
    /// reload. The panel consults this on focus / appearance so returning to
    /// the tab after a while surfaces new commits without a manual refresh.
    static let stalenessThreshold: TimeInterval = 30

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
        // Bump generation so any in-flight work discards on completion.
        loadGeneration &+= 1
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Data loading (Tasks 2.1 / 3.2 / 3.4 / 3.5)

    /// Reloads the full snapshot from scratch. A `reload` always cancels any
    /// in-flight `loadMore` via the generation counter.
    func reload(limit: Int? = nil) {
        let batchSize = limit ?? GitGraphSettings.commitsPerLoad()
        loadGeneration &+= 1
        let myGen = loadGeneration
        isLoading = true
        isLoadingMore = false
        loadError = nil
        let directory = workspaceDirectory
        let filter = branchFilter

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = Self.buildSnapshot(
                directory: directory,
                limit: batchSize,
                branchFilter: filter
            )
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == myGen else { return }
                self.snapshot = snapshot
                self.isLoading = false
                self.lastRefreshAt = Date()
            }
        }
    }

    /// Kicks off a reload if no snapshot exists yet, or if the last successful
    /// refresh was more than `stalenessThreshold` seconds ago. Callers should
    /// invoke this on panel appearance / workspace focus.
    func refreshIfStale() {
        guard let last = lastRefreshAt else {
            reload()
            return
        }
        if Date().timeIntervalSince(last) > Self.stalenessThreshold {
            reload()
        }
    }

    /// Appends the next `N` commits starting after the last currently-loaded
    /// commit. Skips silently when a fetch is already in flight or when the
    /// snapshot signals there are no more commits to fetch.
    func loadMore() {
        guard !isLoading, !isLoadingMore else { return }
        guard let existing = snapshot, existing.hasMoreCommits else { return }
        let batchSize = GitGraphSettings.commitsPerLoad()
        let skip = existing.commits.count
        loadGeneration &+= 1
        let myGen = loadGeneration
        isLoadingMore = true
        let directory = workspaceDirectory
        let filter = branchFilter

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let moreCommits = GitGraphProvider.fetchCommits(
                directory: directory,
                limit: batchSize,
                skip: skip,
                branchFilter: filter
            )
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == myGen else { return }
                // Re-run lane assignment over the combined list so the new
                // commits' lanes line up with the last row the user was
                // already looking at. `parseCommits` + `assignLanes` are
                // additive-safe because topo-order is deterministic.
                let combined = self.snapshot?.commits ?? []
                let merged = GitGraphProvider.assignLanes(
                    commits: combined + moreCommits
                )
                var updated = existing
                updated = GitGraphSnapshot(
                    repoState: existing.repoState,
                    commits: merged,
                    headSha: existing.headSha,
                    headBranch: existing.headBranch,
                    isDetachedHead: existing.isDetachedHead,
                    uncommittedCount: existing.uncommittedCount,
                    branches: existing.branches,
                    tags: existing.tags,
                    stashes: existing.stashes,
                    worktrees: existing.worktrees,
                    hasMoreCommits: moreCommits.count >= batchSize
                )
                self.snapshot = updated
                self.isLoadingMore = false
            }
        }
    }

    // MARK: - Internal

    /// Builds the entire snapshot from disk. Extracted so reload() stays
    /// focused on cancellation/state handling.
    private static func buildSnapshot(
        directory: String,
        limit: Int,
        branchFilter: String?
    ) -> GitGraphSnapshot {
        let repoState = GitGraphProvider.detectRepoState(directory: directory)
        if case .repo(_, let hasCommits) = repoState {
            let commits = hasCommits
                ? GitGraphProvider.fetchCommits(
                    directory: directory,
                    limit: limit,
                    branchFilter: branchFilter
                )
                : []
            let head = GitGraphProvider.fetchHeadSha(directory: directory)
            let branch = GitGraphProvider.fetchHeadBranch(directory: directory)
            let uncommitted = GitGraphProvider.fetchUncommittedCount(directory: directory)
            let branches = GitGraphProvider.fetchBranches(directory: directory)
            let tags = GitGraphProvider.fetchTags(directory: directory)
            let stashes = GitGraphProvider.fetchStashes(directory: directory)
            let worktrees = GitGraphProvider.fetchWorktrees(directory: directory)
            return GitGraphSnapshot(
                repoState: repoState,
                commits: commits,
                headSha: head,
                headBranch: branch,
                isDetachedHead: branch == nil && head != nil,
                uncommittedCount: uncommitted,
                branches: branches,
                tags: tags,
                stashes: stashes,
                worktrees: worktrees,
                hasMoreCommits: commits.count >= limit
            )
        }
        return GitGraphSnapshot(
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

    /// Toggles the expanded state of a commit row; lazily fetches its detail
    /// the first time. Respects the "at most one expanded row" rule by
    /// closing the previous expansion when a different row is clicked.
    func toggleExpanded(_ sha: String) {
        if expandedCommitSha == sha {
            expandedCommitSha = nil
            return
        }
        expandedCommitSha = sha
        guard commitDetailCache[sha] == nil else { return }
        loadingDetailSha = sha
        let directory = workspaceDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detail = GitGraphProvider.fetchCommitDetail(directory: directory, sha: sha)
            DispatchQueue.main.async {
                guard let self else { return }
                if let detail {
                    self.commitDetailCache[sha] = detail
                }
                if self.loadingDetailSha == sha {
                    self.loadingDetailSha = nil
                }
            }
        }
    }
}
