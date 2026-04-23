import SwiftUI

/// Compact monospace one-liner used on unfocused workspace rows.
/// `opus · ctx 62% · 5h 78% · 7d 38%` — numeric color follows theme thresholds
/// so a quota-near-limit tab visually pops.
struct ClaudeStatsInlineView: View {
    let snapshot: ClaudeStatsInlineSnapshot
    let theme: ClaudeStatsTheme

    private static let ctxLabel = String(localized: "sidebar.claudeStats.ctx", defaultValue: "ctx")
    private static let fiveHourLabel = String(localized: "sidebar.claudeStats.fiveHour", defaultValue: "5h")
    private static let sevenDayLabel = String(localized: "sidebar.claudeStats.sevenDay", defaultValue: "7d")

    var body: some View {
        HStack(spacing: 8) {
            if let model = snapshot.modelShort {
                Text(model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.dim)
            }
            if let ctx = snapshot.ctxPercent {
                segment(label: Self.ctxLabel, percent: ctx)
            }
            if let fh = snapshot.fiveHourPercent {
                separator
                segment(label: Self.fiveHourLabel, percent: fh)
            }
            if let sd = snapshot.sevenDayPercent {
                separator
                segment(label: Self.sevenDayLabel, percent: sd)
            }
            if snapshot.isStale {
                Text("(stale)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.faint)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .opacity(snapshot.isStale ? 0.5 : 1.0)
    }

    private func segment(label: String, percent: Double) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundColor(theme.faint)
            Text(ClaudeStatsFormatter.formatPercent(percent))
                .foregroundColor(theme.thresholdColor(for: percent))
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.faint)
    }
}
