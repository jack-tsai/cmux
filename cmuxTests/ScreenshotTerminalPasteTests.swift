import AppKit
import XCTest

@testable import cmux

final class ScreenshotTerminalPasteTests: XCTestCase {

    // MARK: - writeScreenshotEntry

    func testWriteScreenshotEntryPutsFileURLOnPasteboard() throws {
        let tempURL = try writeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.\(UUID().uuidString)"))
        TerminalImageTransferPlanner.writeScreenshotEntry(fileURL: tempURL, to: pasteboard)

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            XCTFail("pasteboard did not carry file URLs")
            return
        }
        XCTAssertEqual(urls.map(\.path), [tempURL.path])
    }

    func testWriteScreenshotEntryPutsImageBytesUnderExtensionUTI() throws {
        let tempURL = try writeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.\(UUID().uuidString)"))
        TerminalImageTransferPlanner.writeScreenshotEntry(fileURL: tempURL, to: pasteboard)

        let pngType = NSPasteboard.PasteboardType(rawValue: "public.png")
        let data = pasteboard.data(forType: pngType)
        XCTAssertNotNil(data, "png data should be on the pasteboard under public.png")
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }

    // MARK: - Plan parity with ⌘V

    func testLocalFileURLPlanMatchesInsertTextPath() {
        let url = URL(fileURLWithPath: "/Users/test/shot.png")
        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: [url],
            target: .local
        )
        guard case .insertText(let text) = plan else {
            XCTFail("expected .insertText, got \(plan)")
            return
        }
        // The escaper uses POSIX-shell-safe encoding that includes the full path.
        XCTAssertTrue(text.contains("shot.png"), "inserted text should reference the file")
    }

    // MARK: - Error shape

    func testNoFocusedTerminalIsEquatable() {
        XCTAssertEqual(
            TerminalImageTransferError.noFocusedTerminal,
            TerminalImageTransferError.noFocusedTerminal
        )
    }

    // MARK: - Helpers

    private func writeTemporaryPNG() throws -> URL {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-paste-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "cmux.test", code: 1)
        }
        try png.write(to: tempURL)
        return tempURL
    }
}
