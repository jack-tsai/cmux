import AppKit
import SwiftUI

/// SwiftUI view for `FilePreviewPanel`. Monospace text with a right-aligned
/// line-number gutter, plus binary / missing / truncated empty states.
struct FilePreviewPanelView: View {
    @ObservedObject var panel: FilePreviewPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var theme: GitGraphTheme = GitGraphTheme.make(from: GhosttyConfig.load())
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        Group {
            switch panel.state {
            case .missing:
                missingView
            case .binary:
                binaryView
            case .text(let lines, let isTruncated):
                textView(lines: lines, isTruncated: isTruncated)
            }
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

    // MARK: - Content

    private func textView(lines: [String], isTruncated: Bool) -> some View {
        let gutterDigits = max(1, String(lines.count).count)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                    previewRow(
                        lineNumber: pair.offset + 1,
                        text: pair.element,
                        gutterDigits: gutterDigits
                    )
                }
                if isTruncated {
                    truncationFooter
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func previewRow(lineNumber: Int, text: String, gutterDigits: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(lineNumber))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.faint)
                .frame(width: CGFloat(gutterDigits) * 8 + 8, alignment: .trailing)
                .padding(.leading, 8)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var binaryView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 36))
                .foregroundColor(theme.secondary)
            Text(String(localized: "filePreview.binary", defaultValue: "Binary file"))
                .font(.headline)
                .foregroundColor(theme.foreground)
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
            Button(action: openInTerminal) {
                Text(String(localized: "filePreview.openInTerminal", defaultValue: "Open in Terminal"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(theme.refBadgeLocal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 36))
                .foregroundColor(theme.secondary)
            Text(String(localized: "filePreview.missing", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(theme.foreground)
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var truncationFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(theme.headMarker)
            Text(String(
                localized: "filePreview.truncated",
                defaultValue: "File truncated — showing first \(FilePreviewPanel.maxLines) lines / 2 MB."
            ))
            .font(.system(size: 11))
            .foregroundColor(theme.secondary)
            Button(action: openInTerminal) {
                Text(String(localized: "filePreview.openInTerminal", defaultValue: "Open in Terminal"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(theme.refBadgeLocal)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    // MARK: - Actions

    private func openInTerminal() {
        let command = "less \(shellEscape(panel.filePath))\n"
        AppDelegate.shared?.tabManager?.dispatchTextToTerminal(
            in: panel.workspaceId,
            text: command
        )
    }

    private func shellEscape(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
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
