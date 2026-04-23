import AppKit
import SwiftUI

/// SwiftUI view for `DiffPanel`. Renders unified diff output with added /
/// removed / context / hunk-header line coloring, plus empty / binary /
/// loading states.
struct DiffPanelView: View {
    @ObservedObject var panel: DiffPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var theme: GitGraphTheme = GitGraphTheme.make(from: GhosttyConfig.load())
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.divider).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name("com.cmuxterm.themes.reload-config")
            )
        ) { _ in
            theme = GitGraphTheme.make(from: GhosttyConfig.load(useCache: false))
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(scopeLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.foreground)
            Spacer()
            Button(action: { panel.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                Text(String(localized: "diff.refresh", defaultValue: "Refresh"))
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundColor(theme.refBadgeLocal)
            .disabled(panel.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.toolbar)
    }

    private var scopeLabel: String {
        switch panel.mode {
        case .workingCopyVsHead:
            return String(
                localized: "diff.scope.workingCopyVsHEAD",
                defaultValue: "Working copy vs HEAD"
            )
        case .commitVsParent(let sha, _):
            return String(
                format: String(
                    localized: "diff.scope.commitVsParent",
                    defaultValue: "%@ vs parent"
                ),
                DiffPanel.shortSha(sha)
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if panel.isLoading && panel.fileDiff == nil {
            loadingView
        } else if let fileDiff = panel.fileDiff {
            switch fileDiff.kind {
            case .binary:
                binaryView
            case .text:
                if fileDiff.hunks.isEmpty {
                    emptyView
                } else {
                    diffScrollView(fileDiff)
                }
            }
        } else {
            emptyView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(String(localized: "diff.loading", defaultValue: "Loading diff…"))
                .font(.caption)
                .foregroundColor(theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "equal.circle")
                .font(.system(size: 36))
                .foregroundColor(theme.secondary)
            Text(String(localized: "diff.empty.noChanges", defaultValue: "No changes"))
                .font(.headline)
                .foregroundColor(theme.foreground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var binaryView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 36))
                .foregroundColor(theme.secondary)
            Text(String(localized: "diff.binary.changed", defaultValue: "Binary file changed"))
                .font(.headline)
                .foregroundColor(theme.foreground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diffScrollView(_ fileDiff: FileDiff) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(fileDiff.hunks.enumerated()), id: \.offset) { hunkPair in
                    let hunk = hunkPair.element
                    hunkHeaderRow(header: hunk.header)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { linePair in
                        diffLineRow(linePair.element)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hunkHeaderRow(header: String) -> some View {
        HStack(spacing: 0) {
            Text(header)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(nsColor: .systemBlue).opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.expandedBackground)
    }

    private func diffLineRow(_ line: DiffLine) -> some View {
        let (prefix, foreground, background): (String, Color, Color) = {
            switch line.kind {
            case .added:
                return ("+", theme.success, theme.success.opacity(0.08))
            case .removed:
                return ("-", theme.danger, theme.danger.opacity(0.08))
            case .context:
                return (" ", theme.foreground, .clear)
            case .hunkHeader:
                return ("", theme.foreground, theme.expandedBackground)
            case .noNewlineAtEof:
                return ("", theme.faint, .clear)
            }
        }()
        return HStack(spacing: 0) {
            Text(prefix + line.text.replacingEmptyWithSpace)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    // MARK: - Focus flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0
        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimationCurve(segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimationCurve(_ curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        }
    }
}

private extension String {
    /// Keep the row rendered at least one-cell-tall even when the diff line
    /// was a blank context line. Returning " " avoids the `Text("")` layout
    /// collapse without changing selection semantics meaningfully.
    var replacingEmptyWithSpace: String { isEmpty ? " " : self }
}
