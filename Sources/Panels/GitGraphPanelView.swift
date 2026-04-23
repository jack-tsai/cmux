import SwiftUI

/// Shared `RelativeDateTimeFormatter` — building one costs ~a few hundred µs
/// (reads locale, spins up a CFDateFormatter). Previously scoped as a
/// `private static let` inside `GitGraphPanelView`, hoisted to file scope so
/// `CommitRowView` can reuse the same instance without needing a reference
/// back to the parent view. A single process-wide instance is safe because
/// we only read it; formatters are documented thread-safe on modern
/// Foundation when `unitsStyle` is set once.
private let gitGraphRelativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

/// Read-only git graph panel view.
/// Layout (left → right):
///   [Refs sidebar] | [Commit list + optional expanded detail]
///
/// The view deliberately does **not** observe `GitGraphPanel` directly.
/// The panel is kept as a plain `let` so its `ObservableObject`
/// `objectWillChange` publisher (which still fires for `displayTitle`
/// and `focusFlashToken`) cannot wake this body. Instead the view
/// subscribes to four sub-stores — `dataStore`, `searchStore`,
/// `expansionStore`, `stashStore` — each with its own publisher.
/// This way a stash-detail fetch or a commit-detail cache populate no
/// longer invalidates the search toolbar, the refs sidebar, or the
/// commit list body. Pair the row-level snapshot boundary (see
/// `CommitRowView` / `StashRowView`) with this coarser body-level one
/// and every `@Published` write lands in exactly the scope that cares.
struct GitGraphPanelView: View {
    let panel: GitGraphPanel
    @ObservedObject private var dataStore: GitGraphDataStore
    @ObservedObject private var searchStore: GitGraphSearchStore
    @ObservedObject private var expansionStore: GitGraphExpansionStore
    @ObservedObject private var stashStore: GitGraphStashStore
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    init(
        panel: GitGraphPanel,
        isFocused: Bool,
        isVisibleInUI: Bool,
        portalPriority: Int,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.panel = panel
        self._dataStore = ObservedObject(wrappedValue: panel.dataStore)
        self._searchStore = ObservedObject(wrappedValue: panel.searchStore)
        self._expansionStore = ObservedObject(wrappedValue: panel.expansionStore)
        self._stashStore = ObservedObject(wrappedValue: panel.stashStore)
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        self.portalPriority = portalPriority
        self.onRequestPanelFocus = onRequestPanelFocus
    }

    @State private var sidebarVisible: Bool = true
    @State private var branchesExpanded: Bool = true
    @State private var tagsExpanded: Bool = true
    @State private var stashesExpanded: Bool = true
    @State private var worktreesExpanded: Bool = true

    /// Cached theme derived from the workspace ghostty config. Stored as
    /// `@State` so SwiftUI evaluates `GitGraphTheme.make(...)` once per theme
    /// change — previously this was a `computed property`, and
    /// `GitGraphTheme.make` uses `NSColor.blended(withFraction:of:)` which
    /// round-trips through ColorSync to normalize into sRGB. That's a
    /// 50–100 µs call per access, and the view reads `theme` dozens of times
    /// per commit row. With hundreds of rows visible in the LazyVStack, the
    /// view graph update cycle spent >50% of main-thread time inside
    /// ColorSync, making terminal typing + scrolling in *other* tabs feel
    /// sluggish. Memoising here drops that to near-zero cost per redraw.
    @State private var theme: GitGraphTheme = GitGraphTheme.make(
        from: GhosttyConfig.load()
    )

    /// Monotonic counter bumped alongside `theme` whenever the ghostty config
    /// broadcasts a reload. `CommitRowView` / `StashRowView` include this
    /// scalar in their `Equatable` comparison as a cheap proxy for "the theme
    /// changed" — comparing the full `GitGraphTheme` struct per row would
    /// walk every Color in the palette on each `==` call.
    @State private var themeRevision: Int = 0

    /// Debounced mirror of `searchStore.searchQuery`. The text field binds directly
    /// to `searchStore.searchQuery` (keystroke-responsive UX), but rendering and
    /// Equatable row inputs read `debouncedQuery`, which coalesces rapid
    /// keystrokes into at most one re-filter every ~150 ms. Without this,
    /// every keystroke re-ran `visibleCommitsForRender` across the full
    /// 500-commit snapshot and rebuilt `subjectHighlight` for every matching
    /// row — with a long search the main thread never caught its breath.
    @State private var debouncedQuery: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    /// Cached `worktreeOccupancy` result. Derived from the snapshot's
    /// `worktrees` list and only refreshed in `onReceive(dataStore.$snapshot)`.
    /// Replaces the previous per-body-pass rebuild at the top of
    /// `commitList`, which was visible in sample(1) traces when the panel
    /// re-rendered on unrelated `@Published` changes.
    @State private var cachedOccupancy: [String: WorktreeEntry] = [:]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.divider).frame(height: 1)
            HStack(spacing: 0) {
                if sidebarVisible {
                    refsSidebar
                    Rectangle().fill(theme.divider).frame(width: 1)
                }
                content
            }
        }
        .background(theme.background)
        .onAppear {
            // Task 3.4 refresh trigger (b): panel transitioning to focused
            // state. `refreshIfStale` is a no-op when the last successful
            // refresh is within 30s, so returning to the tab in rapid
            // succession costs nothing; otherwise we reload so the list
            // picks up commits that landed while the panel was hidden.
            panel.refreshIfStale()
            // Seed the debounced query + occupancy cache so the first render
            // uses the right values without waiting for a publisher event.
            debouncedQuery = searchStore.searchQuery.lowercased()
            cachedOccupancy = Self.computeOccupancy(
                workspaceDir: panel.workspaceDirectory,
                worktrees: dataStore.snapshot?.worktrees ?? []
            )
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            searchDebounceTask = nil
        }
        .onChange(of: searchStore.searchQuery) { _, newValue in
            // Empty → clear — feels instant so skip the 150 ms wait.
            // Non-empty → debounce so fast typing does not re-filter the
            // snapshot on every keystroke. `subjectHighlight` + `isMatch`
            // in the row Equatable comparison both derive from the
            // debounced value, so rows unaffected by a keystroke keep a
            // stable input and skip body evaluation.
            searchDebounceTask?.cancel()
            if newValue.isEmpty {
                debouncedQuery = ""
                return
            }
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
                debouncedQuery = newValue.lowercased()
            }
        }
        .onReceive(dataStore.$snapshot) { snapshot in
            let next = Self.computeOccupancy(
                workspaceDir: panel.workspaceDirectory,
                worktrees: snapshot?.worktrees ?? []
            )
            if next != cachedOccupancy {
                cachedOccupancy = next
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name("com.cmuxterm.themes.reload-config")
            )
        ) { _ in
            // The themes-reload broadcast fires after GhosttyApp invalidates
            // the config cache, so a plain `.load()` returns the fresh theme.
            // Recompute once here — the view then picks it up via @State.
            // Bump `themeRevision` so Equatable row views see a changed
            // scalar and re-evaluate (their `==` ignores `theme` itself for
            // cost reasons).
            theme = GitGraphTheme.make(from: GhosttyConfig.load(useCache: false))
            themeRevision &+= 1
        }
    }

    /// Builds the "branch → worktree entry" map consumed by commit-row ref
    /// badges. Skips the workspace's own worktree; only *other* worktrees
    /// mark a branch as occupied. Static so it can be invoked from
    /// `onAppear` / `onReceive` without capturing `self`.
    private static func computeOccupancy(
        workspaceDir: String,
        worktrees: [WorktreeEntry]
    ) -> [String: WorktreeEntry] {
        var map: [String: WorktreeEntry] = [:]
        for wt in worktrees where wt.path != workspaceDir {
            if let branch = wt.branch {
                map[branch] = wt
            }
        }
        return map
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: { sidebarVisible.toggle() }) {
                Image(systemName: "sidebar.left")
                    .foregroundColor(theme.foreground)
            }
            .buttonStyle(.borderless)
            .help(Text(String(
                localized: "gitGraph.toolbar.toggleSidebar",
                defaultValue: "Toggle Refs Sidebar"
            )))

            Text(panel.workspaceDirectory.asDisplayPath)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)

            branchFilterMenu

            Spacer(minLength: 8)

            searchField
                .frame(maxWidth: 260)

            if dataStore.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: { panel.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(theme.foreground)
            }
            .buttonStyle(.borderless)
            .help(Text(String(
                localized: "gitGraph.toolbar.refresh",
                defaultValue: "Refresh"
            )))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.toolbar)
    }

    // MARK: - Branch filter (Tasks 7.1 / 7.2 / 7.3)

    /// Dropdown that narrows the commit list to a single branch's reachable
    /// history. "All branches" (nil `branchFilter`) falls back to
    /// `git log --all` in the provider. Changing the selection clears the
    /// pending scroll anchor and triggers a full reload so the list begins
    /// at the branch tip rather than the previous scroll position.
    private var branchFilterMenu: some View {
        let current = searchStore.branchFilter
        let allLabel = String(
            localized: "gitGraph.toolbar.branchFilter.all",
            defaultValue: "All branches"
        )
        let branches = dataStore.snapshot?.branches ?? []
        let localBranches = branches.filter { !$0.isRemote }
        let remoteBranches = branches.filter { $0.isRemote }

        return Menu {
            Button {
                selectBranchFilter(nil)
            } label: {
                Label(allLabel, systemImage: current == nil ? "checkmark" : "")
            }

            if !localBranches.isEmpty {
                Section(String(
                    localized: "gitGraph.toolbar.branchFilter.localSection",
                    defaultValue: "Local"
                )) {
                    ForEach(localBranches, id: \.name) { branch in
                        Button {
                            selectBranchFilter(branch.name)
                        } label: {
                            Label(
                                branch.name,
                                systemImage: current == branch.name ? "checkmark" : ""
                            )
                        }
                    }
                }
            }

            if !remoteBranches.isEmpty {
                Section(String(
                    localized: "gitGraph.toolbar.branchFilter.remoteSection",
                    defaultValue: "Remote"
                )) {
                    ForEach(remoteBranches, id: \.name) { branch in
                        Button {
                            selectBranchFilter(branch.name)
                        } label: {
                            Label(
                                branch.name,
                                systemImage: current == branch.name ? "checkmark" : ""
                            )
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text(current ?? allLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(theme.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.divider, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(String(
            localized: "gitGraph.toolbar.branchFilter.tooltip",
            defaultValue: "Filter commits to a single branch"
        )))
    }

    private func selectBranchFilter(_ name: String?) {
        guard searchStore.branchFilter != name else { return }
        searchStore.branchFilter = name
        // The previous anchor belongs to the superset of commits; forgetting
        // it lets the refreshed list render from the branch tip at the top.
        searchStore.scrollAnchorSha = nil
        panel.reload()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(theme.secondary)
            TextField(
                String(
                    localized: "gitGraph.search.placeholder",
                    defaultValue: "Search commits, authors, SHAs"
                ),
                text: $searchStore.searchQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(theme.foreground)
            if !searchStore.searchQuery.isEmpty {
                Button(action: { searchStore.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondary)
                }
                .buttonStyle(.borderless)
                searchModeToggle
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(theme.divider, lineWidth: 0.5)
        )
    }

    /// Compact two-way toggle that flips between highlight (default) and
    /// filter mode. Only visible while a search query is active — with no
    /// query to match the toggle is meaningless.
    private var searchModeToggle: some View {
        let isFilter = searchStore.searchMode == .filter
        return Button(action: {
            searchStore.searchMode = isFilter ? .highlight : .filter
        }) {
            Image(systemName: isFilter ? "line.3.horizontal.decrease.circle.fill" : "highlighter")
                .font(.system(size: 11))
                .foregroundColor(isFilter ? theme.headMarker : theme.secondary)
        }
        .buttonStyle(.borderless)
        .help(Text(isFilter
            ? String(
                localized: "gitGraph.search.mode.filter.tooltip",
                defaultValue: "Filter mode — only matching rows (click to switch to highlight)"
            )
            : String(
                localized: "gitGraph.search.mode.highlight.tooltip",
                defaultValue: "Highlight mode — all rows visible (click to switch to filter)"
            )
        ))
    }

    // MARK: - Refs sidebar

    private var refsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let snapshot = dataStore.snapshot {
                    refsSection(
                        title: String(
                            localized: "gitGraph.refs.branches",
                            defaultValue: "Branches"
                        ),
                        count: snapshot.branches.count,
                        isExpanded: $branchesExpanded,
                        items: snapshot.branches.map { branch in
                            RefRowData(
                                label: branch.name,
                                targetSha: branch.sha,
                                isMuted: branch.isRemote
                            )
                        }
                    )
                    refsSection(
                        title: String(
                            localized: "gitGraph.refs.tags",
                            defaultValue: "Tags"
                        ),
                        count: snapshot.tags.count,
                        isExpanded: $tagsExpanded,
                        items: snapshot.tags.map { tag in
                            RefRowData(label: tag.name, targetSha: tag.sha, isMuted: false)
                        }
                    )
                    stashesSection(snapshot: snapshot)
                    worktreesSection(snapshot: snapshot)
                }
            }
        }
        .frame(width: 220)
        .background(theme.sidebar)
    }

    private struct RefRowData: Identifiable {
        let id = UUID()
        let label: String
        let targetSha: String?
        let isMuted: Bool
    }

    // MARK: - Stash sidebar section (Task 9.2)

    @ViewBuilder
    private func stashesSection(snapshot: GitGraphSnapshot) -> some View {
        DisclosureGroup(isExpanded: $stashesExpanded) {
            if snapshot.stashes.isEmpty {
                Text(String(
                    localized: "gitGraph.refs.empty",
                    defaultValue: "None"
                ))
                .font(.system(size: 11))
                .foregroundColor(theme.faint)
                .italic()
                .padding(.leading, 24)
                .padding(.vertical, 3)
            } else {
                ForEach(snapshot.stashes, id: \.ref) { stash in
                    let isPinned = stashStore.pinnedStashRef == stash.ref
                    Button(action: { panel.togglePinnedStash(stash.ref) }) {
                        HStack(spacing: 4) {
                            if isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.refBadgeTag)
                            }
                            Text("\(stash.ref) — \(stash.subject)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(isPinned ? theme.foreground : theme.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 24)
                        .padding(.trailing, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } label: {
            refsSectionLabel(
                title: String(localized: "gitGraph.refs.stashes", defaultValue: "Stashes"),
                count: snapshot.stashes.count
            )
        }
        .padding(.vertical, 4)
    }

    // MARK: - Worktree sidebar section (Task 10.4)

    @ViewBuilder
    private func worktreesSection(snapshot: GitGraphSnapshot) -> some View {
        DisclosureGroup(isExpanded: $worktreesExpanded) {
            if snapshot.worktrees.isEmpty {
                Text(String(
                    localized: "gitGraph.refs.empty",
                    defaultValue: "None"
                ))
                .font(.system(size: 11))
                .foregroundColor(theme.faint)
                .italic()
                .padding(.leading, 24)
                .padding(.vertical, 3)
            } else {
                ForEach(snapshot.worktrees, id: \.path) { wt in
                    let isCurrent = wt.path == panel.workspaceDirectory
                    let isStale = !FileManager.default.fileExists(atPath: wt.path)
                    let branchLabel = wt.branch ?? (wt.isDetached ? "(detached)" : "(unknown)")
                    Button(action: { scrollToSha(wt.headSha) }) {
                        HStack(spacing: 4) {
                            if isCurrent {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.headMarker)
                            }
                            Text("\(branchLabel) — \(wt.path.asDisplayPath)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(
                                    isStale
                                    ? theme.faint
                                    : (isCurrent ? theme.foreground : theme.secondary)
                                )
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 24)
                        .padding(.trailing, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(isStale
                        ? String(
                            localized: "gitGraph.refs.worktree.stale.tooltip",
                            defaultValue: "Worktree path no longer exists on disk"
                        )
                        : wt.path
                    ))
                }
            }
        } label: {
            refsSectionLabel(
                title: String(localized: "gitGraph.refs.worktrees", defaultValue: "Worktrees"),
                count: snapshot.worktrees.count
            )
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func refsSectionLabel(title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundColor(theme.faint)
                .padding(.horizontal, 5)
                .background(Capsule().fill(theme.secondary.opacity(0.12)))
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func refsSection(
        title: String,
        count: Int,
        isExpanded: Binding<Bool>,
        items: [RefRowData]
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            if items.isEmpty {
                Text(String(
                    localized: "gitGraph.refs.empty",
                    defaultValue: "None"
                ))
                .font(.system(size: 11))
                .foregroundColor(theme.faint)
                .italic()
                .padding(.leading, 24)
                .padding(.vertical, 3)
            } else {
                ForEach(items) { item in
                    Button(action: { scrollToSha(item.targetSha) }) {
                        Text(item.label)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(item.isMuted ? theme.secondary : theme.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 24)
                            .padding(.trailing, 6)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.faint)
                    .padding(.horizontal, 5)
                    .background(
                        Capsule().fill(theme.secondary.opacity(0.12))
                    )
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Content area

    @ViewBuilder
    private var content: some View {
        switch dataStore.snapshot?.repoState {
        case .notARepo:
            emptyState(
                title: String(
                    localized: "gitGraph.state.notARepo.title",
                    defaultValue: "Not a git repository"
                ),
                subtitle: panel.workspaceDirectory
            )
        case .gitUnavailable:
            // When a remote workspace reports no git, include the SSH
            // destination in the title so the user knows where they need
            // to install git (task 11.3).
            emptyState(
                title: panel.remoteConfig.map { remote in
                    String(
                        format: String(
                            localized: "gitGraph.state.gitUnavailable.remoteTitle",
                            defaultValue: "git not found on %@"
                        ),
                        remote.destination
                    )
                } ?? String(
                    localized: "gitGraph.state.gitUnavailable.title",
                    defaultValue: "git is not available"
                ),
                subtitle: panel.remoteConfig.map { _ in
                    String(
                        localized: "gitGraph.state.gitUnavailable.remoteSubtitle",
                        defaultValue: "Install git on the remote host, then press refresh."
                    )
                } ?? panel.workspaceDirectory
            )
        case .repo(_, let hasCommits) where !hasCommits && (dataStore.snapshot?.uncommittedCount ?? 0) == 0:
            emptyState(
                title: String(
                    localized: "gitGraph.state.noCommits.title",
                    defaultValue: "No commits yet"
                ),
                subtitle: String(
                    localized: "gitGraph.state.noCommits.subtitle",
                    defaultValue: "Create the first commit to see it here."
                )
            )
        case .some:
            commitList
        case .none:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 28))
                .foregroundColor(theme.faint)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.foreground)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(theme.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Commit list

    private var commitList: some View {
        let snapshot = dataStore.snapshot
        // Precompute once per body pass instead of per commit row:
        // - `lowerQuery` reads the debounced query (see `onChange(of:
        //   searchStore.searchQuery)` in `body`) so a fast typist does not
        //   re-filter the snapshot on every keystroke. `subjectHighlight`
        //   derives from it; rows whose subjects are unaffected keep a
        //   stable Equatable input and skip body evaluation.
        // - `occupancy` reads the cached map maintained in
        //   `onReceive(dataStore.$snapshot)` so the dict only rebuilds when the
        //   snapshot actually changes, not on every unrelated re-render.
        let lowerQuery = debouncedQuery
        let occupancy = cachedOccupancy
        let visibleCommits = visibleCommitsForRender(
            snapshot: snapshot, lowerQuery: lowerQuery
        )
        let isFilterActive = searchStore.branchFilter != nil
        let headOutsideFilter = isFilterActive
            && (snapshot?.headSha).map { head in
                !(snapshot?.commits.contains { $0.sha == head } ?? false)
            } == true
        // Snapshot expansion state at the top so rows receive plain `Bool`
        // inputs. Reading `expansionStore.expandedCommitSha` directly inside the
        // ForEach would pull the entire `panel: ObservableObject` into every
        // row's dependency graph and re-invalidate the whole visible list on
        // any `@Published` change — that's the hazard pattern CLAUDE.md
        // flags, see the "Snapshot boundary for list subtrees" note.
        let expandedSha = expansionStore.expandedCommitSha
        let expandedStashRef = stashStore.expandedStashRef
        let pinnedStashRef = stashStore.pinnedStashRef
        let headSha = snapshot?.headSha
        let uncommittedCount = snapshot?.uncommittedCount ?? 0
        let themeRevision = self.themeRevision
        let theme = self.theme

        // Build the closure bundle once per body pass. Children in the
        // LazyVStack subtree only see closures + value snapshots, never the
        // `panel` reference — so a future `@ObservedObject var panel` on a
        // row becomes a compile-time error rather than a silent regression.
        // Mirrors the pattern in `SessionIndexView.swift`
        // (`IndexSectionActions` / `SectionGapActions`).
        let panelRef = panel
        let rowActions = GitGraphRowActions(
            toggleCommitExpanded: { sha in panelRef.toggleExpanded(sha) },
            toggleStashExpanded: { ref in panelRef.toggleExpandedStash(ref) },
            unpinStash: { panelRef.unpinStash() }
        )

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if headOutsideFilter, let snapshot {
                        headOutsideFilterBanner(snapshot: snapshot)
                    }
                    // Task 7.4: hide Uncommitted row while a branch filter is
                    // active — the banner above already tells the user where
                    // HEAD (and thus the uncommitted diff) actually belongs.
                    if !isFilterActive, uncommittedCount > 0 {
                        uncommittedRow(count: uncommittedCount)
                    }
                    if let pinnedRef = pinnedStashRef,
                       let stash = snapshot?.stashes.first(where: { $0.ref == pinnedRef }) {
                        StashRowView(
                            stash: stash,
                            theme: theme,
                            themeRevision: themeRevision,
                            actions: rowActions
                        ).equatable()
                        if expandedStashRef == pinnedRef {
                            stashDetailView(stashRef: pinnedRef)
                        }
                    }
                    ForEach(visibleCommits) { commit in
                        let isExpanded = expandedSha == commit.sha
                        let isHead = commit.sha == headSha && uncommittedCount == 0
                        // `subjectHighlight` is the substring each row should
                        // highlight inside its subject. It is non-empty only
                        // when this commit's subject actually contains the
                        // query — so rows whose subject is unaffected by a
                        // keystroke keep an identical Equatable input (empty
                        // string) and skip body evaluation. This is the main
                        // win for type-to-filter scroll latency.
                        let subjectMatches = !lowerQuery.isEmpty
                            && commit.subjectLower.contains(lowerQuery)
                        let isMatch = !lowerQuery.isEmpty
                            && (subjectMatches
                                || commit.authorLower.contains(lowerQuery)
                                || commit.sha.hasPrefix(lowerQuery))
                        let subjectHighlight = subjectMatches ? lowerQuery : ""
                        CommitRowView(
                            commit: commit,
                            isHead: isHead,
                            isExpanded: isExpanded,
                            isMatch: isMatch,
                            subjectHighlight: subjectHighlight,
                            occupancy: occupancy,
                            theme: theme,
                            themeRevision: themeRevision,
                            actions: rowActions
                        )
                        .equatable()
                        .id(commit.sha)
                        if isExpanded {
                            commitDetailView(for: commit)
                        }
                    }
                    if snapshot?.hasMoreCommits == true {
                        loadMoreButton
                    }
                }
            }
            .onChange(of: debouncedQuery) { _, newValue in
                // Fires after the 150 ms debounce (or immediately on clear);
                // scrolling on every keystroke felt twitchy and made the
                // list jump around while the user was still composing a
                // query.
                guard !newValue.isEmpty,
                      let firstMatch = firstMatchingSha(for: newValue) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(firstMatch, anchor: .center)
                }
            }
            .onReceive(dataStore.$snapshot) { _ in
                // When a scroll-to request is parked via `scrollTarget`, jump
                // there once the snapshot has arrived and the row is visible.
                if let target = scrollTarget {
                    proxy.scrollTo(target, anchor: .center)
                    scrollTarget = nil
                }
            }
        }
    }

    /// Applies the filter-mode search filter when appropriate. Highlight mode
    /// always returns the full list (the highlighter handles visual emphasis).
    private func visibleCommitsForRender(
        snapshot: GitGraphSnapshot?, lowerQuery: String
    ) -> [CommitNode] {
        guard let snapshot else { return [] }
        let commits = snapshot.commits
        guard searchStore.searchMode == .filter, !lowerQuery.isEmpty else {
            return commits
        }
        return commits.filter { commitMatches($0, lowerQuery: lowerQuery) }
    }

    // MARK: - HEAD outside filter banner (Task 7.4)

    @ViewBuilder
    private func headOutsideFilterBanner(snapshot: GitGraphSnapshot) -> some View {
        let branchName = snapshot.headBranch ?? "HEAD"
        let dirtyNote = snapshot.uncommittedCount > 0
            ? String(
                localized: "gitGraph.banner.headOutsideFilter.dirtySuffix",
                defaultValue: " (uncommitted changes)"
            )
            : ""
        let message = String(
            format: String(
                localized: "gitGraph.banner.headOutsideFilter.message",
                defaultValue: "HEAD is on %@%@, not in current filter"
            ),
            branchName,
            dirtyNote
        )
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.headMarker)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: { selectBranchFilter(nil) }) {
                Text(String(
                    localized: "gitGraph.banner.headOutsideFilter.showAll",
                    defaultValue: "Show All"
                ))
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(theme.headMarker)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.headMarker.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(theme.headMarker.opacity(0.35))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    @State private var scrollTarget: String?

    private func scrollToSha(_ sha: String?) {
        guard let sha else { return }
        scrollTarget = sha
    }

    private func firstMatchingSha(for query: String) -> String? {
        let lower = query.lowercased()
        return dataStore.snapshot?.commits.first(where: { commitMatches($0, lowerQuery: lower) })?.sha
    }

    // MARK: - Stash detail (Task 9.2)

    @ViewBuilder
    private func stashDetailView(stashRef: String) -> some View {
        let files = stashStore.stashDetailCache[stashRef]
        let isLoading = stashStore.loadingStashRef == stashRef && files == nil
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(
                        localized: "gitGraph.detail.loading",
                        defaultValue: "Loading commit details…"
                    ))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondary)
                }
            } else if let files, !files.isEmpty {
                fileListView(files, sha: stashRef)
            } else {
                Text(String(
                    localized: "gitGraph.stashDetail.empty",
                    defaultValue: "Stash contains no tracked files."
                ))
                .font(.system(size: 11))
                .foregroundColor(theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.expandedBackground)
    }

    private func uncommittedRow(count: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(theme.headMarker, lineWidth: 2)
                .frame(width: 10, height: 10)
            Text(uncommittedLabel(count: count))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.success)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.success.opacity(0.08))
    }

    /// Hot-path matcher used by the ForEach filter. Takes the already-lowercased
    /// query so the body evaluation only lowercases once, and reads the
    /// precomputed `subjectLower` / `authorLower` on the commit node instead of
    /// allocating a new lowercased String per row. SHA is hex, so a direct
    /// `hasPrefix` skips a `lowercased()` entirely.
    private func commitMatches(_ commit: CommitNode, lowerQuery: String) -> Bool {
        commit.subjectLower.contains(lowerQuery)
            || commit.authorLower.contains(lowerQuery)
            || commit.sha.hasPrefix(lowerQuery)
    }

    // MARK: - Commit detail expansion

    @ViewBuilder
    private func commitDetailView(for commit: CommitNode) -> some View {
        let detail = expansionStore.commitDetailCache[commit.sha]
        let isLoading = expansionStore.loadingDetailSha == commit.sha && detail == nil
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(
                        localized: "gitGraph.detail.loading",
                        defaultValue: "Loading commit details…"
                    ))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondary)
                }
            } else if let detail {
                detailMetadataView(detail)
                if !detail.files.isEmpty {
                    Rectangle().fill(theme.divider).frame(height: 1)
                    fileListView(detail.files, sha: detail.sha)
                }
            } else {
                Text(String(
                    localized: "gitGraph.detail.unavailable",
                    defaultValue: "Commit details unavailable."
                ))
                .font(.system(size: 11))
                .foregroundColor(theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.expandedBackground)
    }

    private func detailMetadataView(_ detail: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metadataLine(
                key: String(localized: "gitGraph.detail.sha", defaultValue: "SHA"),
                value: detail.sha,
                monospace: true
            )
            if !detail.parents.isEmpty {
                metadataLine(
                    key: String(localized: "gitGraph.detail.parents", defaultValue: "Parents"),
                    value: detail.parents.map { String($0.prefix(10)) }.joined(separator: ", "),
                    monospace: true
                )
            }
            metadataLine(
                key: String(localized: "gitGraph.detail.author", defaultValue: "Author"),
                value: "\(detail.authorName) <\(detail.authorEmail)>",
                monospace: false
            )
            metadataLine(
                key: String(localized: "gitGraph.detail.committer", defaultValue: "Committer"),
                value: "\(detail.committerName) <\(detail.committerEmail)>",
                monospace: false
            )
            metadataLine(
                key: String(localized: "gitGraph.detail.date", defaultValue: "Date"),
                value: absoluteDate(detail.committerDate),
                monospace: false
            )
            if !detail.fullMessage.isEmpty {
                Text(detail.fullMessage)
                    .font(.system(size: 12))
                    .foregroundColor(theme.foreground)
                    .padding(.top, 6)
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func metadataLine(key: String, value: String, monospace: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(
                    size: 11,
                    design: monospace ? .monospaced : .default
                ))
                .foregroundColor(theme.foreground)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    // MARK: - File tree

    /// Threshold above which the full file list is collapsed into a
    /// "too many files" notice with a dispatch-to-terminal button — per
    /// task 5.8. Rendering hundreds of expandable rows otherwise stalls
    /// SwiftUI layout inside the expanded commit detail.
    private static let tooManyFilesThreshold: Int = 500

    private func fileListView(_ files: [FileChange], sha: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(String(
                    localized: "gitGraph.detail.changedFiles",
                    defaultValue: "Changed files"
                ))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondary)
                Text("(\(files.count))")
                    .font(.system(size: 11))
                    .foregroundColor(theme.faint)
            }
            .padding(.bottom, 2)

            if files.count > Self.tooManyFilesThreshold {
                tooManyFilesNotice(fileCount: files.count, sha: sha)
            } else {
                ForEach(files, id: \.path) { file in
                    fileRow(file, sha: sha)
                }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: FileChange, sha: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.system(size: 10))
                .foregroundColor(theme.secondary)
            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if file.isBinary {
                Text(String(
                    localized: "gitGraph.detail.binary",
                    defaultValue: "binary"
                ))
                .font(.system(size: 10))
                .foregroundColor(theme.faint)
            } else {
                if let added = file.added {
                    Text("+\(added)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.success)
                }
                if let deleted = file.deleted {
                    Text("-\(deleted)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.danger)
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            // Task 5.1: fileRow opens a DiffPanel tab instead of writing
            // `git show` into the terminal scrollback.
            AppDelegate.shared?.tabManager?.openOrFocusDiff(
                mode: .commitVsParent(sha: sha, path: file.path)
            )
        }
        .help(Text(String(
            localized: "gitGraph.fileRow.tooltip.diff",
            defaultValue: "Click to view diff in a new tab"
        )))
    }

    @ViewBuilder
    private func tooManyFilesNotice(fileCount: Int, sha: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.headMarker)
                Text(String(
                    format: String(
                        localized: "gitGraph.detail.tooManyFiles",
                        defaultValue: "Too many files (%d) — skipping list to keep the panel responsive."
                    ),
                    fileCount
                ))
                .font(.system(size: 11))
                .foregroundColor(theme.secondary)
            }
            Button(action: { dispatchGitShow(sha: sha, filePath: nil) }) {
                Text(String(
                    localized: "gitGraph.detail.openInTerminal",
                    defaultValue: "Open in terminal"
                ))
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(theme.refBadgeLocal)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Dispatch to terminal (Task 5.6)

    /// Sends `git show <sha> [-- <file>]\n` to a terminal panel in the same
    /// workspace. Shell-escapes the path so spaces / quotes in file names
    /// don't break the invocation.
    private func dispatchGitShow(sha: String, filePath: String?) {
        var command = "git show \(sha)"
        if let filePath {
            command += " -- \(shellEscape(filePath))"
        }
        command += "\n"
        AppDelegate.shared?.tabManager?.dispatchTextToTerminal(
            in: panel.workspaceId,
            text: command
        )
    }

    /// Wraps a path in single quotes and escapes embedded quotes the POSIX
    /// way (`'` → `'\''`). Safe against spaces, tabs, newlines, and shell
    /// metacharacters.
    private func shellEscape(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm Z"
        return formatter.string(from: date)
    }

    private func uncommittedLabel(count: Int) -> String {
        let template = String(
            localized: "gitGraph.uncommitted.title",
            defaultValue: "Uncommitted Changes (%d)"
        )
        return String(format: template, count)
    }

    private var loadMoreButton: some View {
        HStack(spacing: 8) {
            if dataStore.isLoadingMore {
                ProgressView().controlSize(.small)
                Text(String(
                    localized: "gitGraph.loadMore.loading",
                    defaultValue: "Loading more commits…"
                ))
                .font(.system(size: 12))
                .foregroundColor(theme.secondary)
            } else {
                Button(action: { panel.loadMore() }) {
                    Text(String(
                        localized: "gitGraph.loadMore.button",
                        defaultValue: "Load more commits…"
                    ))
                    .font(.system(size: 12))
                    .foregroundColor(theme.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - Row snapshot boundary (value-type row views)

/// Closure bundle handed into `CommitRowView` / `StashRowView` so rows
/// below the `LazyVStack` snapshot boundary cannot reach the
/// `GitGraphPanel` ObservableObject. A future `@ObservedObject var
/// panel: GitGraphPanel` accidentally added to a row becomes a type
/// error rather than a silent 100% CPU regression. Mirrors
/// `IndexSectionActions` / `SectionGapActions` in `SessionIndexView.swift`
/// (CLAUDE.md "Snapshot boundary for list subtrees" note).
struct GitGraphRowActions {
    let toggleCommitExpanded: (String) -> Void
    let toggleStashExpanded: (String) -> Void
    let unpinStash: () -> Void
}

/// Equatable value row rendered inside the `LazyVStack` `ForEach`. Takes
/// only value snapshots + a closure bundle so SwiftUI can skip body
/// evaluation when nothing affecting this specific row has changed.
///
/// `themeRevision` is a cheap scalar proxy for `theme`: the parent bumps
/// it on ghostty theme reload. Comparing the full `GitGraphTheme` struct
/// per row would walk every Color in the palette on each `==` call.
///
/// `subjectHighlight` is non-empty only when this commit's subject
/// actually contains the current search query — so rows unaffected by
/// a keystroke keep an identical Equatable input (empty string) and
/// skip body evaluation.
private struct CommitRowView: View, Equatable {
    let commit: CommitNode
    let isHead: Bool
    let isExpanded: Bool
    let isMatch: Bool
    let subjectHighlight: String
    let occupancy: [String: WorktreeEntry]
    let theme: GitGraphTheme
    let themeRevision: Int
    let actions: GitGraphRowActions

    var body: some View {
        let laneCount = max(
            commit.laneIndex + 1,
            (commit.parentLanes.max() ?? 0) + 1,
            (commit.passThroughLanes.max() ?? 0) + 1
        )
        let graphWidth = CGFloat(laneCount) * GitGraphLaneMetrics.laneSpacing
            + GitGraphLaneMetrics.laneSpacing
        return HStack(spacing: 10) {
            Canvas { context, size in
                drawLanes(in: context, size: size)
            }
            // Fixed frame (not minHeight) — lane rows are a constant height, so
            // letting SwiftUI flex the size would route through FlexFrameLayout
            // which `sample(1)` traces showed as a hot path during scroll.
            .frame(width: graphWidth, height: GitGraphLaneMetrics.rowHeight)

            if !commit.refs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(commit.refs, id: \.name) { ref in
                        refBadge(ref)
                    }
                }
            }

            highlightedSubject
                .font(.system(size: 12))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(
                gitGraphRelativeDateFormatter.localizedString(
                    for: commit.date, relativeTo: Date()
                )
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondary)
            .frame(width: 72, alignment: .trailing)

            Text(commit.authorName)
                .font(.system(size: 11))
                .foregroundColor(theme.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .trailing)

            Text(commit.shortSha)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.faint)
                .frame(width: 72, alignment: .trailing)
        }
        // No vertical padding: the HStack's intrinsic height comes from the
        // Canvas minHeight, so lane segments in adjacent rows line up at the
        // row boundary without a gap.
        .padding(.horizontal, 12)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { actions.toggleCommitExpanded(commit.sha) }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isExpanded {
            theme.selection.opacity(0.35)
        } else if isMatch {
            theme.searchMatch
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var highlightedSubject: some View {
        if subjectHighlight.isEmpty {
            Text(commit.subject)
        } else {
            Text(attributedSubject())
        }
    }

    private func attributedSubject() -> AttributedString {
        let text = commit.subject
        let lowerText = commit.subjectLower
        let lowerQuery = subjectHighlight
        guard !lowerQuery.isEmpty else { return AttributedString(text) }
        var result = AttributedString("")
        var cursor = text.startIndex
        var searchStart = lowerText.startIndex
        let highlightBg = theme.searchHighlightBg
        let highlightFg = theme.searchHighlightFg
        while let range = lowerText.range(
            of: lowerQuery, range: searchStart..<lowerText.endIndex
        ) {
            // Map the lowercased range onto the original `text` (same Unicode
            // structure because `lowercased()` is 1:1 for BMP letters used in
            // commit subjects).
            let matchLow = text.index(
                text.startIndex,
                offsetBy: lowerText.distance(from: lowerText.startIndex, to: range.lowerBound)
            )
            let matchHigh = text.index(
                matchLow,
                offsetBy: lowerText.distance(from: range.lowerBound, to: range.upperBound)
            )
            if cursor < matchLow {
                result.append(AttributedString(String(text[cursor..<matchLow])))
            }
            var highlighted = AttributedString(String(text[matchLow..<matchHigh]))
            highlighted.backgroundColor = highlightBg
            highlighted.foregroundColor = highlightFg
            result.append(highlighted)
            cursor = matchHigh
            searchStart = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(AttributedString(String(text[cursor...])))
        }
        return result
    }

    private func drawLanes(in context: GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let bottomY = size.height
        let dotRadius: CGFloat = isHead ? 5.5 : 3.5
        let ownX = laneCenterX(for: commit.laneIndex)

        for lane in commit.passThroughLanes {
            let x = laneCenterX(for: lane)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bottomY))
            context.stroke(path, with: .color(laneColor(for: lane)), lineWidth: 1.5)
        }

        var topSegment = Path()
        topSegment.move(to: CGPoint(x: ownX, y: 0))
        topSegment.addLine(to: CGPoint(x: ownX, y: midY))
        context.stroke(
            topSegment, with: .color(laneColor(for: commit.laneIndex)), lineWidth: 1.5
        )

        for (index, parentLane) in commit.parentLanes.enumerated() {
            let parentX = laneCenterX(for: parentLane)
            var path = Path()
            path.move(to: CGPoint(x: ownX, y: midY))
            if index == 0 && parentLane == commit.laneIndex {
                path.addLine(to: CGPoint(x: ownX, y: bottomY))
            } else {
                let bendY = midY + (bottomY - midY) * 0.55
                path.addCurve(
                    to: CGPoint(x: parentX, y: bendY),
                    control1: CGPoint(x: ownX, y: bendY * 0.8),
                    control2: CGPoint(x: parentX, y: midY + (bendY - midY) * 0.2)
                )
                path.addLine(to: CGPoint(x: parentX, y: bottomY))
            }
            context.stroke(path, with: .color(laneColor(for: parentLane)), lineWidth: 1.5)
        }

        let dotRect = CGRect(
            x: ownX - dotRadius,
            y: midY - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        if isHead {
            context.stroke(
                Path(ellipseIn: dotRect), with: .color(theme.headMarker), lineWidth: 2
            )
            context.fill(
                Path(ellipseIn: dotRect.insetBy(dx: 2, dy: 2)),
                with: .color(laneColor(for: commit.laneIndex))
            )
        } else {
            context.fill(
                Path(ellipseIn: dotRect),
                with: .color(laneColor(for: commit.laneIndex))
            )
        }
    }

    private func laneCenterX(for laneIndex: Int) -> CGFloat {
        GitGraphLaneMetrics.laneSpacing / 2
            + CGFloat(laneIndex) * GitGraphLaneMetrics.laneSpacing
    }

    private func laneColor(for laneIndex: Int) -> Color {
        theme.lanePalette[laneIndex % theme.lanePalette.count]
    }

    @ViewBuilder
    private func refBadge(_ ref: GitRef) -> some View {
        let color: Color = {
            switch ref.kind {
            case .localBranch: return theme.refBadgeLocal
            case .remoteBranch: return theme.refBadgeRemote
            case .tag: return theme.refBadgeTag
            case .head: return theme.headMarker
            }
        }()
        // Task 10.3: a local branch checked out in *another* worktree gets
        // a `⎘` icon with a tooltip naming the occupying path, so the user
        // can see they shouldn't try to check it out here.
        let occupyingWorktree = ref.kind == .localBranch ? occupancy[ref.name] : nil
        HStack(spacing: 3) {
            Text(ref.name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.refBadgeText(on: color))
            if occupyingWorktree != nil {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 8))
                    .foregroundColor(theme.refBadgeText(on: color))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color)
        .cornerRadius(3)
        .help(Text(occupyingWorktree.map { wt in
            String(
                format: String(
                    localized: "gitGraph.refBadge.worktreeOccupied.tooltip",
                    defaultValue: "Checked out in worktree: %@"
                ),
                wt.path
            )
        } ?? ref.name))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Omit `theme` — `themeRevision` captures its identity cheaply.
        // Omit `actions` — closures are rebuilt once per parent body pass
        // and are not Equatable.
        lhs.commit == rhs.commit
            && lhs.isHead == rhs.isHead
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isMatch == rhs.isMatch
            && lhs.subjectHighlight == rhs.subjectHighlight
            && lhs.themeRevision == rhs.themeRevision
            && lhs.occupancy == rhs.occupancy
    }
}

/// Equatable value row for the pinned stash entry. Same snapshot-boundary
/// reasoning as `CommitRowView`.
private struct StashRowView: View, Equatable {
    let stash: StashEntry
    let theme: GitGraphTheme
    let themeRevision: Int
    let actions: GitGraphRowActions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundColor(theme.refBadgeTag)
            Text(stash.ref)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.refBadgeText(on: theme.refBadgeTag))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(theme.refBadgeTag)
                .cornerRadius(3)
            Text(stash.subject)
                .font(.system(size: 12))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: { actions.unpinStash() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.faint)
            }
            .buttonStyle(.borderless)
            .help(Text(String(
                localized: "gitGraph.stashRow.unpin.tooltip",
                defaultValue: "Remove stash from the list"
            )))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.refBadgeTag.opacity(0.12))
        .contentShape(Rectangle())
        .onTapGesture { actions.toggleStashExpanded(stash.ref) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stash == rhs.stash && lhs.themeRevision == rhs.themeRevision
    }
}

private extension String {
    var asDisplayPath: String {
        let home = NSHomeDirectory()
        if self.hasPrefix(home) {
            return "~" + self.dropFirst(home.count)
        }
        return self
    }
}

enum GitGraphLaneMetrics {
    static let laneSpacing: CGFloat = 16
    static let rowHeight: CGFloat = 28
}

/// Derives every colour the Git Graph panel needs from the workspace's
/// ghostty theme so the panel looks native under any configured scheme
/// (solarized, tokyonight, dracula, rose-pine, etc.). All palette indices
/// below refer to the 16-colour ANSI terminal palette baked into the
/// ghostty config — lanes therefore rotate through colours the user
/// already sees in their terminal.
struct GitGraphTheme {
    // Core chrome
    let background: Color
    let toolbar: Color
    let sidebar: Color
    let inputBackground: Color
    let expandedBackground: Color
    let divider: Color

    // Text
    let foreground: Color
    let secondary: Color
    let faint: Color

    // Accents
    let selection: Color
    let headMarker: Color
    let success: Color
    let danger: Color

    // Search highlighting
    let searchMatch: Color
    let searchHighlightBg: Color
    let searchHighlightFg: Color

    // Lane / ref badges
    let lanePalette: [Color]
    let refBadgeLocal: Color
    let refBadgeRemote: Color
    let refBadgeTag: Color

    /// Picks a readable label colour for a ref badge whose fill may be
    /// dark (then the label is white) or light (then the label is black).
    func refBadgeText(on fill: Color) -> Color {
        NSColor(fill).isLightColor ? .black : .white
    }

    static func make(from config: GhosttyConfig) -> GitGraphTheme {
        let background = config.backgroundColor
        let foreground = config.foregroundColor
        let isDarkBg = !background.isLightColor

        // Toolbar/sidebar sit just off the canvas background; nudging a few
        // percent keeps them legibly separate without clashing with themes
        // that already use near-identical neighbouring colours.
        let chromeTint = isDarkBg
            ? background.lighten(by: 0.04)
            : background.darken(by: 0.04)
        let sidebarTint = isDarkBg
            ? background.lighten(by: 0.02)
            : background.darken(by: 0.02)
        let inputTint = isDarkBg
            ? background.lighten(by: 0.08)
            : background.darken(by: 0.06)
        let expandedTint = isDarkBg
            ? background.lighten(by: 0.06)
            : background.darken(by: 0.04)
        let dividerTint = isDarkBg
            ? background.lighten(by: 0.12)
            : background.darken(by: 0.12)

        // Text shades: foreground → 100%, secondary → 60%, faint → 40%.
        let secondaryFg = foreground.blended(withFraction: 0.4, of: background) ?? foreground
        let faintFg = foreground.blended(withFraction: 0.6, of: background) ?? foreground

        let selection = Color(nsColor: config.selectionBackground)

        // Palette picks: ANSI 1 (red) → danger, ANSI 2 (green) → success,
        // ANSI 3 (yellow) → HEAD ring, ANSI 4/5/6 feed the lane rotation
        // alongside 1/2/3 for branch diversity.
        let ansi = { (i: Int) -> Color in
            if let c = config.palette[i] { return Color(nsColor: c) }
            return GitGraphTheme.ansiFallback(index: i, onDark: isDarkBg)
        }

        let success = ansi(2)
        let danger = ansi(1)
        let yellow = ansi(3)
        let blue = ansi(4)
        let magenta = ansi(5)
        let cyan = ansi(6)

        // Lane palette rotates through six ANSI colours that are visually
        // distinct across every bundled ghostty theme we've checked.
        let lanePalette: [Color] = [blue, magenta, success, yellow, danger, cyan]

        // Search match background lifts yellow enough to be obvious without
        // stomping on a commit row's lane colour.
        let searchMatch = yellow.opacity(isDarkBg ? 0.25 : 0.35)
        let searchHighlightBg = yellow
        let searchHighlightFg: Color = NSColor(yellow).isLightColor ? .black : .white

        return GitGraphTheme(
            background: Color(nsColor: background),
            toolbar: Color(nsColor: chromeTint),
            sidebar: Color(nsColor: sidebarTint),
            inputBackground: Color(nsColor: inputTint),
            expandedBackground: Color(nsColor: expandedTint),
            divider: Color(nsColor: dividerTint),
            foreground: Color(nsColor: foreground),
            secondary: Color(nsColor: secondaryFg),
            faint: Color(nsColor: faintFg),
            selection: selection,
            headMarker: yellow,
            success: success,
            danger: danger,
            searchMatch: searchMatch,
            searchHighlightBg: searchHighlightBg,
            searchHighlightFg: searchHighlightFg,
            lanePalette: lanePalette,
            refBadgeLocal: blue,
            refBadgeRemote: Color(nsColor: secondaryFg),
            refBadgeTag: magenta
        )
    }

    /// Fallback when a ghostty theme hasn't populated a palette slot.
    /// Values mirror the standard xterm "dark background"/"light background"
    /// variants so the panel never falls back to a muddy grey.
    private static func ansiFallback(index: Int, onDark: Bool) -> Color {
        let dark: [Color] = [
            .black,
            Color(red: 0.80, green: 0.27, blue: 0.30),
            Color(red: 0.40, green: 0.78, blue: 0.31),
            Color(red: 0.84, green: 0.73, blue: 0.18),
            Color(red: 0.26, green: 0.56, blue: 0.92),
            Color(red: 0.67, green: 0.33, blue: 0.83),
            Color(red: 0.24, green: 0.74, blue: 0.78)
        ]
        let light: [Color] = [
            .black,
            Color(red: 0.70, green: 0.18, blue: 0.22),
            Color(red: 0.20, green: 0.55, blue: 0.23),
            Color(red: 0.65, green: 0.52, blue: 0.09),
            Color(red: 0.15, green: 0.40, blue: 0.75),
            Color(red: 0.55, green: 0.24, blue: 0.70),
            Color(red: 0.10, green: 0.55, blue: 0.60)
        ]
        let palette = onDark ? dark : light
        return palette[max(0, min(palette.count - 1, index))]
    }
}

private extension NSColor {
    /// Symmetric counterpart to `NSColor.darken(by:)` already defined in
    /// GhosttyConfig; nudges luminance upward without a full invert so
    /// light-theme backgrounds don't flash white.
    func lighten(by amount: CGFloat) -> NSColor {
        guard let rgb = self.usingColorSpace(.sRGB) else { return self }
        let f = max(0, min(1, amount))
        return NSColor(
            red: rgb.redComponent + (1 - rgb.redComponent) * f,
            green: rgb.greenComponent + (1 - rgb.greenComponent) * f,
            blue: rgb.blueComponent + (1 - rgb.blueComponent) * f,
            alpha: rgb.alphaComponent
        )
    }
}
