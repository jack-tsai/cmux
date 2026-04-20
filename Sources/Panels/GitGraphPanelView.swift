import SwiftUI

/// Read-only git graph panel view.
/// Layout (left → right):
///   [Refs sidebar] | [Commit list + optional expanded detail]
struct GitGraphPanelView: View {
    @ObservedObject var panel: GitGraphPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var sidebarVisible: Bool = true
    @State private var branchesExpanded: Bool = true
    @State private var tagsExpanded: Bool = true
    @State private var stashesExpanded: Bool = true
    @State private var worktreesExpanded: Bool = true

    /// Snapshot of the workspace's current ghostty theme. Kept in view state
    /// (rather than recomputed on every redraw) so we only parse + resolve
    /// colors when `CmuxThemeNotifications.reloadConfig` actually fires.
    @State private var ghosttyConfig: GhosttyConfig = GhosttyConfig.load()

    /// Derived palette consumed by every subview — single source of truth
    /// so swapping themes only touches one computed property.
    private var theme: GitGraphTheme { GitGraphTheme.make(from: ghosttyConfig) }

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
            if panel.snapshot == nil {
                panel.reload()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name("com.cmuxterm.themes.reload-config")
            )
        ) { _ in
            // The themes-reload broadcast fires after GhosttyApp invalidates
            // the config cache, so a plain `.load()` returns the fresh theme.
            ghosttyConfig = GhosttyConfig.load(useCache: false)
        }
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

            Spacer(minLength: 8)

            searchField
                .frame(maxWidth: 260)

            if panel.isLoading {
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
                text: $panel.searchQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(theme.foreground)
            if !panel.searchQuery.isEmpty {
                Button(action: { panel.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondary)
                }
                .buttonStyle(.borderless)
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

    // MARK: - Refs sidebar

    private var refsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let snapshot = panel.snapshot {
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
                    refsSection(
                        title: String(
                            localized: "gitGraph.refs.stashes",
                            defaultValue: "Stashes"
                        ),
                        count: snapshot.stashes.count,
                        isExpanded: $stashesExpanded,
                        items: snapshot.stashes.map { stash in
                            RefRowData(
                                label: "\(stash.ref) — \(stash.subject)",
                                targetSha: stash.sha,
                                isMuted: true
                            )
                        }
                    )
                    refsSection(
                        title: String(
                            localized: "gitGraph.refs.worktrees",
                            defaultValue: "Worktrees"
                        ),
                        count: snapshot.worktrees.count,
                        isExpanded: $worktreesExpanded,
                        items: snapshot.worktrees.map { wt in
                            let label = wt.branch ?? (wt.isDetached ? "(detached)" : "(unknown)")
                            return RefRowData(
                                label: "\(label) — \(wt.path.asDisplayPath)",
                                targetSha: wt.headSha,
                                isMuted: wt.path != panel.workspaceDirectory
                            )
                        }
                    )
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
        switch panel.snapshot?.repoState {
        case .notARepo:
            emptyState(
                title: String(
                    localized: "gitGraph.state.notARepo.title",
                    defaultValue: "Not a git repository"
                ),
                subtitle: panel.workspaceDirectory
            )
        case .gitUnavailable:
            emptyState(
                title: String(
                    localized: "gitGraph.state.gitUnavailable.title",
                    defaultValue: "git is not available"
                ),
                subtitle: panel.workspaceDirectory
            )
        case .repo(_, let hasCommits) where !hasCommits && (panel.snapshot?.uncommittedCount ?? 0) == 0:
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let count = panel.snapshot?.uncommittedCount, count > 0 {
                        uncommittedRow(count: count)
                    }
                    ForEach(panel.snapshot?.commits ?? []) { commit in
                        commitRow(commit)
                        if panel.expandedCommitSha == commit.sha {
                            commitDetailView(for: commit)
                        }
                    }
                    if panel.snapshot?.hasMoreCommits == true {
                        loadMoreButton
                    }
                }
            }
            .onChange(of: panel.searchQuery) { _, newValue in
                guard !newValue.isEmpty,
                      let firstMatch = firstMatchingSha(for: newValue) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(firstMatch, anchor: .center)
                }
            }
            .onReceive(panel.$snapshot) { _ in
                // When a scroll-to request is parked via `scrollTarget`, jump
                // there once the snapshot has arrived and the row is visible.
                if let target = scrollTarget {
                    proxy.scrollTo(target, anchor: .center)
                    scrollTarget = nil
                }
            }
        }
    }

    @State private var scrollTarget: String?

    private func scrollToSha(_ sha: String?) {
        guard let sha else { return }
        scrollTarget = sha
    }

    private func firstMatchingSha(for query: String) -> String? {
        let lower = query.lowercased()
        return panel.snapshot?.commits.first(where: { commit in
            commit.subject.lowercased().contains(lower)
                || commit.authorName.lowercased().contains(lower)
                || commit.sha.lowercased().hasPrefix(lower)
        })?.sha
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

    private func commitRow(_ commit: CommitNode) -> some View {
        let isHead = commit.sha == panel.snapshot?.headSha
            && (panel.snapshot?.uncommittedCount ?? 0) == 0
        let isExpanded = panel.expandedCommitSha == commit.sha
        let isMatch = !panel.searchQuery.isEmpty && commitMatchesSearch(commit)
        let laneCount = max(
            commit.laneIndex + 1,
            (commit.parentLanes.max() ?? 0) + 1,
            (commit.passThroughLanes.max() ?? 0) + 1
        )
        let graphWidth = CGFloat(laneCount) * GitGraphLaneMetrics.laneSpacing
            + GitGraphLaneMetrics.laneSpacing
        return HStack(spacing: 10) {
            Canvas { context, size in
                drawLanes(in: context, size: size, commit: commit, isHead: isHead)
            }
            .frame(width: graphWidth)
            .frame(minHeight: GitGraphLaneMetrics.rowHeight)

            if !commit.refs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(commit.refs, id: \.name) { ref in
                        refBadge(ref)
                    }
                }
            }

            highlightedText(commit.subject)
                .font(.system(size: 12))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(relativeDate(commit.date))
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
        // row boundary without a gap. A Divider between rows would reintroduce
        // that gap, so the list uses background-only separation instead.
        .padding(.horizontal, 12)
        .background(rowBackground(isExpanded: isExpanded, isMatch: isMatch))
        .contentShape(Rectangle())
        .onTapGesture { panel.toggleExpanded(commit.sha) }
        .id(commit.sha)
    }

    private func rowBackground(isExpanded: Bool, isMatch: Bool) -> some View {
        Group {
            if isExpanded {
                theme.selection.opacity(0.35)
            } else if isMatch {
                theme.searchMatch
            } else {
                Color.clear
            }
        }
    }

    private func commitMatchesSearch(_ commit: CommitNode) -> Bool {
        let lower = panel.searchQuery.lowercased()
        return commit.subject.lowercased().contains(lower)
            || commit.authorName.lowercased().contains(lower)
            || commit.sha.lowercased().hasPrefix(lower)
    }

    /// Highlights matched substring within the commit subject when search is
    /// active. Case-insensitive search, case-preserving display.
    @ViewBuilder
    private func highlightedText(_ text: String) -> some View {
        let query = panel.searchQuery
        if query.isEmpty {
            Text(text)
        } else {
            Text(attributedSubject(text, query: query))
        }
    }

    private func attributedSubject(_ text: String, query: String) -> AttributedString {
        let lowerQuery = query.lowercased()
        guard !lowerQuery.isEmpty else { return AttributedString(text) }
        let lowerText = text.lowercased()
        var result = AttributedString("")
        var cursor = text.startIndex
        var searchStart = lowerText.startIndex
        let highlightBg = theme.searchHighlightBg
        let highlightFg = theme.searchHighlightFg
        while let range = lowerText.range(of: lowerQuery, range: searchStart..<lowerText.endIndex) {
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

    // MARK: - Commit detail expansion

    @ViewBuilder
    private func commitDetailView(for commit: CommitNode) -> some View {
        let detail = panel.commitDetailCache[commit.sha]
        let isLoading = panel.loadingDetailSha == commit.sha && detail == nil
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
            ForEach(files, id: \.path) { file in
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
            }
        }
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

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Graph lane drawing

    private func drawLanes(
        in context: GraphicsContext,
        size: CGSize,
        commit: CommitNode,
        isHead: Bool
    ) {
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
        context.stroke(topSegment, with: .color(laneColor(for: commit.laneIndex)), lineWidth: 1.5)

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
            context.stroke(Path(ellipseIn: dotRect), with: .color(theme.headMarker), lineWidth: 2)
            context.fill(
                Path(ellipseIn: dotRect.insetBy(dx: 2, dy: 2)),
                with: .color(laneColor(for: commit.laneIndex))
            )
        } else {
            context.fill(Path(ellipseIn: dotRect), with: .color(laneColor(for: commit.laneIndex)))
        }
    }

    private func laneCenterX(for laneIndex: Int) -> CGFloat {
        GitGraphLaneMetrics.laneSpacing / 2
            + CGFloat(laneIndex) * GitGraphLaneMetrics.laneSpacing
    }

    private func laneColor(for laneIndex: Int) -> Color {
        theme.lanePalette[laneIndex % theme.lanePalette.count]
    }

    private func refBadge(_ ref: GitRef) -> some View {
        let color: Color = {
            switch ref.kind {
            case .localBranch: return theme.refBadgeLocal
            case .remoteBranch: return theme.refBadgeRemote
            case .tag: return theme.refBadgeTag
            case .head: return theme.headMarker
            }
        }()
        return Text(ref.name)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(theme.refBadgeText(on: color))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color)
            .cornerRadius(3)
    }

    private var loadMoreButton: some View {
        Button(action: { /* Load More — implemented in task 3.3 */ }) {
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
        .padding(.vertical, 12)
        .disabled(true)
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
