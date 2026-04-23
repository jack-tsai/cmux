import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ClaudeSettingsInspectorTests: XCTestCase {

    // MARK: - Classify

    func testClassify_fileMissing() {
        let (settings, _) = tmpURLs()
        try? FileManager.default.removeItem(at: settings)
        let inspector = ClaudeSettingsInspector(
            settingsURL: settings, backupURL: settings.appendingPathExtension("bak"),
            statusLineCommand: "cmux statusline",
            compactHookCommand: "cmux record-compact"
        )
        XCTAssertEqual(inspector.classifyConnectionStatus(), .fileMissing)
    }

    func testClassify_connected_bareCommand() throws {
        let (settings, inspector) = makePair()
        let contents = #"{"statusLine":{"type":"command","command":"cmux statusline"}}"#
        try writeData(contents, to: settings)
        XCTAssertEqual(inspector.classifyConnectionStatus(), .connected)
    }

    func testClassify_connected_devVariant() throws {
        let (settings, inspector) = makePair()
        let contents = #"{"statusLine":{"type":"command","command":"cmux-dev statusline"}}"#
        try writeData(contents, to: settings)
        XCTAssertEqual(inspector.classifyConnectionStatus(), .connected)
    }

    func testClassify_connected_absolutePath() throws {
        let (settings, inspector) = makePair()
        let contents = #"{"statusLine":{"type":"command","command":"/Applications/cmux.app/Contents/Resources/bin/cmux statusline"}}"#
        try writeData(contents, to: settings)
        XCTAssertEqual(inspector.classifyConnectionStatus(), .connected)
    }

    func testClassify_disconnected_otherTool() throws {
        let (settings, inspector) = makePair()
        let contents = #"{"statusLine":{"type":"command","command":"npx cc-statusline"}}"#
        try writeData(contents, to: settings)
        XCTAssertEqual(inspector.classifyConnectionStatus(), .disconnected)
    }

    func testClassify_disconnected_missingStatusLineKey() throws {
        let (settings, inspector) = makePair()
        try writeData("{}", to: settings)
        XCTAssertEqual(inspector.classifyConnectionStatus(), .disconnected)
    }

    // MARK: - mergeStatusline

    func testMergeStatusline_onEmptyJson_setsCommand() {
        let merged = ClaudeSettingsInspector.mergeStatusline(into: [:], command: "cmux statusline")
        let sl = merged["statusLine"] as? [String: Any]
        XCTAssertEqual(sl?["command"] as? String, "cmux statusline")
        XCTAssertEqual(sl?["type"] as? String, "command")
    }

    func testMergeStatusline_replacesExistingCommand() {
        let existing: [String: Any] = [
            "statusLine": ["type": "command", "command": "old-script.sh"]
        ]
        let merged = ClaudeSettingsInspector.mergeStatusline(into: existing, command: "cmux statusline")
        let sl = merged["statusLine"] as? [String: Any]
        XCTAssertEqual(sl?["command"] as? String, "cmux statusline")
    }

    func testMergeStatusline_preservesUnrelatedKeys() {
        let existing: [String: Any] = [
            "autoAcceptEdits": true,
            "env": ["FOO": "bar"]
        ]
        let merged = ClaudeSettingsInspector.mergeStatusline(into: existing, command: "cmux statusline")
        XCTAssertEqual(merged["autoAcceptEdits"] as? Bool, true)
        XCTAssertEqual((merged["env"] as? [String: Any])?["FOO"] as? String, "bar")
    }

    // MARK: - mergePreCompactHook

    func testMergePreCompact_addsNewEntry() {
        let merged = ClaudeSettingsInspector.mergePreCompactHook(into: [:], command: "cmux record-compact")
        let hooks = merged["hooks"] as? [String: Any]
        let pre = hooks?["PreCompact"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 1)
        let nested = pre?[0]["hooks"] as? [[String: Any]]
        XCTAssertEqual(nested?[0]["command"] as? String, "cmux record-compact")
    }

    func testMergePreCompact_doesNotDuplicateExistingEntry() {
        let existing: [String: Any] = [
            "hooks": [
                "PreCompact": [[
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": "cmux record-compact"
                    ]]
                ]]
            ]
        ]
        let merged = ClaudeSettingsInspector.mergePreCompactHook(into: existing, command: "cmux record-compact")
        let pre = (merged["hooks"] as? [String: Any])?["PreCompact"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 1, "Should not duplicate the cmux hook entry")
    }

    // MARK: - autoConfigureAtomic backup semantics

    func testAutoConfigure_fromEmpty_createsFileAndNoBackup() throws {
        let (settings, _) = tmpURLs()
        let backup = settings.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: settings)
        try? FileManager.default.removeItem(at: backup)
        let inspector = ClaudeSettingsInspector(
            settingsURL: settings, backupURL: backup,
            statusLineCommand: "cmux statusline",
            compactHookCommand: "cmux record-compact"
        )
        try inspector.autoConfigureAtomic()
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "No backup needed when starting empty")
    }

    func testAutoConfigure_existingFile_createsBackupOnce() throws {
        let (settings, _) = tmpURLs()
        let backup = settings.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: settings)
        try? FileManager.default.removeItem(at: backup)
        try writeData(#"{"autoAcceptEdits":true}"#, to: settings)
        let inspector = ClaudeSettingsInspector(
            settingsURL: settings, backupURL: backup,
            statusLineCommand: "cmux statusline",
            compactHookCommand: "cmux record-compact"
        )

        try inspector.autoConfigureAtomic()
        let firstBackup = try String(contentsOf: backup)
        XCTAssertEqual(firstBackup, #"{"autoAcceptEdits":true}"#)

        // Second run should NOT overwrite backup (spec: .bak is write-once).
        try writeData(#"{"somethingElse": 1}"#, to: settings)
        try inspector.autoConfigureAtomic()
        let secondBackup = try String(contentsOf: backup)
        XCTAssertEqual(secondBackup, firstBackup, ".bak must be preserved across auto-configure runs")
    }

    // MARK: - Test helpers

    private func tmpURLs() -> (settings: URL, backup: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSettingsInspectorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        let backup = dir.appendingPathComponent("settings.json.bak")
        return (settings, backup)
    }

    private func makePair() -> (settings: URL, inspector: ClaudeSettingsInspector) {
        let (settings, backup) = tmpURLs()
        let inspector = ClaudeSettingsInspector(
            settingsURL: settings, backupURL: backup,
            statusLineCommand: "cmux statusline",
            compactHookCommand: "cmux record-compact"
        )
        return (settings, inspector)
    }

    private func writeData(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try string.data(using: .utf8)!.write(to: url, options: .atomic)
    }
}
