import SwiftUI

/// Setup card shown in place of the Claude stats block on the focused
/// workspace row when `~/.claude/settings.json` does not yet point
/// `statusLine.command` at cmux. Offers auto-configure / manual / dismiss.
/// Corresponds to spec `claude-statusline-setup`.
struct ClaudeStatsSetupCardView: View {
    let theme: ClaudeStatsTheme
    let onAutoConfigure: () -> Void
    let onManual: () -> Void
    let onDismiss: () -> Void
    /// Non-nil when the last `Auto-configure` attempt failed; shown inline.
    let errorMessage: String?

    private static let titleLabel = String(
        localized: "sidebar.claudeStats.setup.title",
        defaultValue: "Claude Code not connected"
    )
    private static let autoLabel = String(
        localized: "sidebar.claudeStats.setup.autoConfigure",
        defaultValue: "Auto-configure"
    )
    private static let manualLabel = String(
        localized: "sidebar.claudeStats.setup.manual",
        defaultValue: "I'll edit it myself"
    )
    private static let dismissLabel = String(
        localized: "sidebar.claudeStats.setup.dismiss",
        defaultValue: "Don't show again"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.titleLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.foreground)

            // Primary action — visually distinct via theme-driven filled capsule.
            Button(action: onAutoConfigure) {
                Text(Self.autoLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.background)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(theme.barDefault)
                    )
            }
            .buttonStyle(.plain)

            // Secondary links — small underlined-feel rows below the primary.
            HStack(spacing: 12) {
                Button(action: onManual) {
                    Text(Self.manualLabel)
                        .font(.system(size: 11))
                        .foregroundColor(theme.dim)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Text(Self.dismissLabel)
                        .font(.system(size: 11))
                        .foregroundColor(theme.faint)
                }
                .buttonStyle(.plain)
            }

            if let message = errorMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.barDanger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}
