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
        return HStack(spacing: 10) {
            // Lane column placeholder — real Canvas-based lane rendering lands
            // in a later task (1.7 full implementation). For now draw a dot
            // and a faint vertical hint so the column has visible presence.
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1.5)
                if isHead {
                    Circle()
                        .strokeBorder(Color.yellow, lineWidth: 2)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 24)

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
