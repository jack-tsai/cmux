import AppKit
import SwiftUI

/// Main view for the right-sidebar `.screenshots` mode.
/// Section 3 tasks flesh this out with the preview + gallery layout, empty state,
/// truncated footer, and theme-aware styling.
struct ScreenshotPanelView: View {
    @ObservedObject var store: ScreenshotStore

    var body: some View {
        VStack(spacing: 0) {
            Text(String(
                localized: "screenshotPanel.empty.title",
                defaultValue: "No screenshots yet"
            ))
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
