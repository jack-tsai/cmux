import AppKit
import SwiftUI

/// Full stats block rendered inside the focused workspace's sidebar row.
/// Accepts a pre-built value snapshot + theme. MUST NOT hold references to
/// `ClaudeStatsStore` or any other `ObservableObject` (CLAUDE.md snapshot
/// boundary rule).
struct ClaudeStatsBlockView: View {
    let snapshot: ClaudeStatsBlockSnapshot
    let theme: ClaudeStatsTheme
    /// When true, the block is drawn inside the selected-workspace-row's
    /// accent-tinted background. Palette tones shift toward white so the
    /// text stays legible against the blue fill (mirrors mock's
    /// `.workspace-row.is-selected` palette override).
    var isOnSelectedBackground: Bool = false

    private static let ctxLabel = String(localized: "sidebar.claudeStats.ctx", defaultValue: "ctx")
    private static let fiveHourLabel = String(localized: "sidebar.claudeStats.fiveHour", defaultValue: "5h")
    private static let sevenDayLabel = String(localized: "sidebar.claudeStats.sevenDay", defaultValue: "7d")
    private static let staleLabel = String(localized: "sidebar.claudeStats.stale", defaultValue: "(stale)")

    // MARK: - Palette resolution (matches mock's .is-selected overrides)

    private var fgDim: Color {
        isOnSelectedBackground ? Color.white.opacity(0.90) : theme.dim
    }
    private var fgFaint: Color {
        isOnSelectedBackground ? Color.white.opacity(0.55) : theme.faint
    }
    private var dividerColor: Color {
        isOnSelectedBackground ? Color.white.opacity(0.25) : theme.divider
    }
    private var barTrackColor: Color {
        isOnSelectedBackground ? Color.white.opacity(0.20) : theme.barTrack
    }

    /// Bar fill / numeric value color by threshold. In the selected state the
    /// default (< 60 %) bar uses white instead of ansi blue so it pops
    /// against the blue background.
    private func fillColor(for percent: Double) -> Color {
        if percent >= ClaudeStatsTheme.dangerThreshold { return theme.barDanger }
        if percent >= ClaudeStatsTheme.warnThreshold { return theme.barWarn }
        return isOnSelectedBackground ? .white : theme.barDefault
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !snapshot.sessionIdShort.isEmpty {
                sessionIdentityRow
                    .padding(.bottom, 2)
            }
            tokensRow
                .padding(.bottom, 4)
            ctxRow(snapshot.ctx)
            if let fh = snapshot.fiveHour {
                barRow(labelText: Self.fiveHourLabel, row: fh)
            }
            if let sd = snapshot.sevenDay {
                barRow(labelText: Self.sevenDayLabel, row: sd)
            }
            if let hint = snapshot.freeTierHint {
                Text(hint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(fgFaint)
                    .padding(.top, 2)
            }
            if snapshot.isStale {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(Self.staleLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(fgFaint)
                }
                .padding(.top, 1)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .overlay(alignment: .top) {
            Rectangle().fill(dividerColor).frame(height: 1)
        }
        .opacity(snapshot.isStale ? 0.75 : 1.0)
    }

    // MARK: - Rows

    private var tokensRow: some View {
        HStack(spacing: 0) {
            Text(snapshot.tokensTotalLabel)
                .foregroundColor(fgDim)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(snapshot.tokensSessionLabel)
                .foregroundColor(fgFaint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    /// "session a1b2c3d4" identity line above the tokens row. Kept monospaced
    /// + faint so it reads as metadata, not a primary value. The "session"
    /// label here is the agent-session identifier; the `tokensSessionLabel`
    /// on the right of `tokensRow` is the per-call token count — sharing the
    /// word "session" was the source of the confusion this row is meant to
    /// disambiguate.
    private var sessionIdentityRow: some View {
        HStack(spacing: 6) {
            Text(String(
                localized: "sidebar.claudeStats.sessionIdLabel",
                defaultValue: "session"
            ))
            .foregroundColor(fgFaint)
            Text(snapshot.sessionIdShort)
                .foregroundColor(fgDim)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(Text(snapshot.sessionIdShort))
    }

    private func ctxRow(_ row: ClaudeStatsBlockSnapshot.BarRow) -> some View {
        barRow(labelText: Self.ctxLabel, row: row)
    }

    /// Mimics mock's `grid-template-columns: 30px 1fr auto; gap: 8px` with a
    /// trailing value cell that packs percent + extra tightly.
    private func barRow(labelText: String, row: ClaudeStatsBlockSnapshot.BarRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(labelText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(fgFaint)
                .frame(width: 24, alignment: .leading)

            ProgressBar(percent: row.percent,
                        fill: fillColor(for: row.percent),
                        track: barTrackColor)
                .frame(height: 6)
                .layoutPriority(1)

            valueCell(percent: row.percent, label: row.percentLabel, extra: row.extraLabel)
        }
        .padding(.vertical, 1)
    }

    private func valueCell(percent: Double, label: String, extra: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(fillColor(for: percent))
            if !extra.isEmpty {
                Text(extra)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(fgFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - ProgressBar

private struct ProgressBar: View {
    let percent: Double
    let fill: Color
    let track: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: max(0, min(1, percent / 100)) * geo.size.width)
            }
        }
    }
}
