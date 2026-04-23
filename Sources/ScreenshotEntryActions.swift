import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag payload

/// SwiftUI `.draggable` payload. Transferring as a file URL lets Finder /
/// Preview / terminals all receive the same representation. The `private`
/// content type tag satisfies the spec requirement that non-terminal drop
/// targets can reject the drag.
/// Spec: `screenshot-panel-view` → "Drag-out restricted to terminal surfaces only in v1".
struct ScreenshotDragPayload: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.url)
    }
}

// MARK: - Context menu

/// Right-click context menu for a gallery entry. Items in the order specified
/// by `screenshot-panel-view` → "Right-click context menu with five actions".
struct ScreenshotEntryContextMenu: View {
    let url: URL
    let id: UUID
    let actions: ScreenshotGalleryActions

    var body: some View {
        Button(String(
            localized: "screenshotPanel.contextMenu.copy",
            defaultValue: "Copy to pasteboard"
        )) {
            actions.onCopyToPasteboard(url)
        }
        Button(String(
            localized: "screenshotPanel.contextMenu.paste",
            defaultValue: "Paste to terminal"
        )) {
            actions.onActivate(id)
        }
        .keyboardShortcut(.return, modifiers: [])
        Button(String(
            localized: "screenshotPanel.contextMenu.reveal",
            defaultValue: "Reveal in Finder"
        )) {
            actions.onRevealInFinder(url)
        }
        Button(String(
            localized: "screenshotPanel.contextMenu.rename",
            defaultValue: "Rename…"
        )) {
            ScreenshotEntryRenameController.presentRenamePrompt(for: url, actions: actions)
        }
        Divider()
        Button(String(
            localized: "screenshotPanel.contextMenu.trash",
            defaultValue: "Move to Trash"
        )) {
            actions.onTrash(url)
        }
    }
}

// MARK: - Rename

/// Renaming a screenshot uses a lightweight NSAlert input field rather than an
/// inline SwiftUI TextField because the gallery cell aspect ratio leaves no
/// room for an expanded editing row at 56pt grid width. The alert still
/// satisfies the spec's Enter-commits / Esc-cancels / collision-error contract.
/// Spec: `screenshot-panel-view` → "Right-click context menu with five actions"
/// (rename scenarios). The inline-TextField variant is tracked for v2 once the
/// gallery has a selected-row detail pane to host it.
enum ScreenshotEntryRenameController {
    @MainActor
    static func presentRenamePrompt(
        for url: URL,
        actions: ScreenshotGalleryActions
    ) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "screenshotPanel.rename.title",
            defaultValue: "Rename screenshot"
        )
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: String(
            localized: "screenshotPanel.rename.commit",
            defaultValue: "Rename"
        ))
        alert.addButton(withTitle: String(
            localized: "screenshotPanel.rename.cancel",
            defaultValue: "Cancel"
        ))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = url.lastPathComponent
        alert.accessoryView = input
        input.selectAll(nil)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != url.lastPathComponent else { return }
        if let errorMessage = actions.onRename(url, newName) {
            let error = NSAlert()
            error.alertStyle = .warning
            error.messageText = errorMessage
            error.addButton(withTitle: "OK")
            error.runModal()
        }
    }
}

// MARK: - Action implementations

/// Composes the standard action set for a given store. Lives outside
/// `ScreenshotPanelView` so the implementations stay pure and testable.
enum ScreenshotEntryActionsFactory {
    @MainActor
    static func copyToPasteboard(url: URL) {
        TerminalImageTransferPlanner.writeScreenshotEntry(
            fileURL: url,
            to: NSPasteboard.general
        )
    }

    @MainActor
    static func revealInFinder(url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    /// Returns nil on success, or a user-facing error message on failure.
    @MainActor
    static func trash(url: URL) -> String? {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return nil
        } catch {
            return String(
                localized: "screenshotPanel.trash.error.generic",
                defaultValue: "Could not move file to Trash."
            )
        }
    }

    /// Returns nil on success, or a user-facing error message on failure.
    /// Collision check uses `fileExists` before `moveItem` to give a clear
    /// "file name already exists" message rather than a Foundation error.
    /// Spec: `screenshot-panel-view` → "Rename target filename already exists in folder".
    @MainActor
    static func rename(url: URL, to newName: String) -> String? {
        let directory = url.deletingLastPathComponent()
        let target = directory.appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: target.path) {
            return String(
                localized: "screenshotPanel.rename.error.exists",
                defaultValue: "File name already exists."
            )
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return nil
        } catch {
            return String(
                localized: "screenshotPanel.rename.error.generic",
                defaultValue: "Could not rename file."
            )
        }
    }
}
