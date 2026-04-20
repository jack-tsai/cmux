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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if sidebarVisible {
                    refsSidebar
                    Divider()
                }
                content
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if panel.snapshot == nil {
                panel.reload()
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: { sidebarVisible.toggle() }) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(Text(String(
                localized: "gitGraph.toolbar.toggleSidebar",
                defaultValue: "Toggle Refs Sidebar"
            )))

            Text(panel.workspaceDirectory.asDisplayPath)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
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
            }
            .buttonStyle(.borderless)
            .help(Text(String(
                localized: "gitGraph.toolbar.refresh",
                defaultValue: "Refresh"
            )))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField(
                String(
                    localized: "gitGraph.search.placeholder",
                    defaultValue: "Search commits, authors, SHAs"
                ),
                text: $panel.searchQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            if !panel.searchQuery.isEmpty {
                Button(action: { panel.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
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
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }

    private struct RefRowData: Identifiable {
        let id = UUID()
        let label: String
        let targetSha: String?
        let isMuted: Bool
    }

    @ViewBuilder
    private func refsSection(title: String, count: Int, items: [RefRowData]) -> some View {
        DisclosureGroup {
            if items.isEmpty {
                Text(String(
                    localized: "gitGraph.refs.empty",
                    defaultValue: "None"
                ))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .italic()
                .padding(.leading, 24)
                .padding(.vertical, 3)
            } else {
                ForEach(items) { item in
                    Button(action: { scrollToSha(item.targetSha) }) {
                        Text(item.label)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(item.isMuted ? .secondary : .primary)
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
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.horizontal, 5)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
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
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
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
                        Divider().opacity(0.4)
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
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: 10, height: 10)
            Text(uncommittedLabel(count: count))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.green)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.06))
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
            .frame(width: graphWidth, height: GitGraphLaneMetrics.rowHeight)

            if !commit.refs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(commit.refs, id: \.name) { ref in
                        refBadge(ref)
                    }
                }
            }

            highlightedText(commit.subject)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(relativeDate(commit.date))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .trailing)

            Text(commit.authorName)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .trailing)

            Text(commit.shortSha)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(rowBackground(isExpanded: isExpanded, isMatch: isMatch))
        .contentShape(Rectangle())
        .onTapGesture { panel.toggleExpanded(commit.sha) }
        .id(commit.sha)
    }

    private func rowBackground(isExpanded: Bool, isMatch: Bool) -> some View {
        Group {
            if isExpanded {
                Color.accentColor.opacity(0.12)
            } else if isMatch {
                Color.orange.opacity(0.18)
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
            highlighted.backgroundColor = .orange
            highlighted.foregroundColor = .black
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
                    .foregroundColor(.secondary)
                }
            } else if let detail {
                detailMetadataView(detail)
                if !detail.files.isEmpty {
                    Divider()
                    fileListView(detail.files, sha: detail.sha)
                }
            } else {
                Text(String(
                    localized: "gitGraph.detail.unavailable",
                    defaultValue: "Commit details unavailable."
                ))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
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
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(
                    size: 11,
                    design: monospace ? .monospaced : .default
                ))
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
                .foregroundColor(.secondary)
                Text("(\(files.count))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.bottom, 2)
            ForEach(files, id: \.path) { file in
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(file.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if file.isBinary {
                        Text(String(
                            localized: "gitGraph.detail.binary",
                            defaultValue: "binary"
                        ))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                    } else {
                        if let added = file.added {
                            Text("+\(added)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.green)
                        }
                        if let deleted = file.deleted {
                            Text("-\(deleted)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.red)
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
            context.stroke(Path(ellipseIn: dotRect), with: .color(.yellow), lineWidth: 2)
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
        let palette: [Color] = [
            Color(red: 0.04, green: 0.52, blue: 1.00),
            Color(red: 0.75, green: 0.35, blue: 0.95),
            Color(red: 0.19, green: 0.82, blue: 0.35),
            Color(red: 1.00, green: 0.62, blue: 0.04),
            Color(red: 1.00, green: 0.22, blue: 0.37),
            Color(red: 0.35, green: 0.78, blue: 0.98)
        ]
        return palette[laneIndex % palette.count]
    }

    private func refBadge(_ ref: GitRef) -> some View {
        let color: Color = {
            switch ref.kind {
            case .localBranch: return Color.blue
            case .remoteBranch: return Color.gray
            case .tag: return Color.purple
            case .head: return Color.orange
            }
        }()
        return Text(ref.name)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white)
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
