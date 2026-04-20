import SwiftUI

/// Read-only git graph panel view. First-pass skeleton: renders repo state,
/// Uncommitted Changes row, and a flat commit list. Lanes, ref badges,
/// commit-detail expansion, and refs sidebar land in later tasks.
struct GitGraphPanelView: View {
    @ObservedObject var panel: GitGraphPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if panel.snapshot == nil {
                panel.reload()
            }
        }
    }

    // MARK: - Toolbar (Tasks 3.4 / 7.1 / 8.1 later refine)

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(panel.workspaceDirectory.asDisplayPath)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

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
            // Initial load in flight.
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

    // MARK: - Commit list (Task 1.7 skeleton)

    private var commitList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let count = panel.snapshot?.uncommittedCount, count > 0 {
                    uncommittedRow(count: count)
                }
                ForEach(panel.snapshot?.commits ?? []) { commit in
                    commitRow(commit)
                    Divider().opacity(0.4)
                }
                if panel.snapshot?.hasMoreCommits == true {
                    loadMoreButton
                }
            }
        }
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
        let laneCount = max(
            commit.laneIndex + 1,
            (commit.parentLanes.max() ?? 0) + 1,
            (commit.passThroughLanes.max() ?? 0) + 1
        )
        let graphWidth = CGFloat(laneCount) * GitGraphLaneMetrics.laneSpacing
            + GitGraphLaneMetrics.laneSpacing
        return HStack(spacing: 10) {
            Canvas { context, size in
                drawLanes(
                    in: context,
                    size: size,
                    commit: commit,
                    isHead: isHead
                )
            }
            .frame(width: graphWidth, height: GitGraphLaneMetrics.rowHeight)

            // Ref badges
            if !commit.refs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(commit.refs, id: \.name) { ref in
                        refBadge(ref)
                    }
                }
            }

            Text(commit.subject)
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
        .contentShape(Rectangle())
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

        // Pass-through lanes: branches unrelated to this commit that continue
        // from the row above to the row below. Draw a full vertical segment.
        for lane in commit.passThroughLanes {
            let x = laneCenterX(for: lane)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bottomY))
            context.stroke(path, with: .color(laneColor(for: lane)), lineWidth: 1.5)
        }

        // Top half of the own lane (segment coming in from the row above).
        var topSegment = Path()
        topSegment.move(to: CGPoint(x: ownX, y: 0))
        topSegment.addLine(to: CGPoint(x: ownX, y: midY))
        context.stroke(
            topSegment,
            with: .color(laneColor(for: commit.laneIndex)),
            lineWidth: 1.5
        )

        // Connector lines from this commit's dot to each parent lane's top.
        // First parent: straight vertical (inherits own lane). Others: bend
        // sideways and then continue down.
        for (index, parentLane) in commit.parentLanes.enumerated() {
            let parentX = laneCenterX(for: parentLane)
            var path = Path()
            path.move(to: CGPoint(x: ownX, y: midY))
            if index == 0 && parentLane == commit.laneIndex {
                // Straight down — trunk continuation.
                path.addLine(to: CGPoint(x: ownX, y: bottomY))
            } else {
                // Bend to the parent lane: short diagonal then vertical.
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

        // Commit dot on top of any lines that pass through.
        let dotRect = CGRect(
            x: ownX - dotRadius,
            y: midY - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        if isHead {
            // Ring-style marker so the HEAD commit stays legible even on a
            // coloured lane background.
            context.stroke(
                Path(ellipseIn: dotRect),
                with: .color(.yellow),
                lineWidth: 2
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

    /// Six-colour rotating palette mirroring the HTML mockup (see
    /// `docs/uidesign/git-graph-panel-design.html`).
    private func laneColor(for laneIndex: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.04, green: 0.52, blue: 1.00),  // lane-0
            Color(red: 0.75, green: 0.35, blue: 0.95),  // lane-1
            Color(red: 0.19, green: 0.82, blue: 0.35),  // lane-2
            Color(red: 1.00, green: 0.62, blue: 0.04),  // lane-3
            Color(red: 1.00, green: 0.22, blue: 0.37),  // lane-4
            Color(red: 0.35, green: 0.78, blue: 0.98)   // lane-5
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
}

private extension String {
    /// Abbreviates `~/...` from an absolute path for toolbar display.
    var asDisplayPath: String {
        let home = NSHomeDirectory()
        if self.hasPrefix(home) {
            return "~" + self.dropFirst(home.count)
        }
        return self
    }
}

/// Graph-column sizing constants shared between the row layout and the
/// Canvas drawer so the commit dot lines up with lane separator positions.
enum GitGraphLaneMetrics {
    /// Horizontal spacing between adjacent lanes (centre to centre).
    static let laneSpacing: CGFloat = 16
    /// Vertical height of one commit row. Matches `.padding(.vertical, 5)` +
    /// the row's content and is passed to Canvas so lane segments reach the
    /// row edges (needed for seamless vertical lines across adjacent rows).
    static let rowHeight: CGFloat = 28
}
