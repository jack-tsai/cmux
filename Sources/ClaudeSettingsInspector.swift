import Foundation

/// Detects whether `~/.claude/settings.json` is wired to cmux, and performs
/// the atomic auto-configure write when the user opts in from the sidebar
/// setup card. See spec `claude-statusline-setup` for the normative rules.
final class ClaudeSettingsInspector {

    enum ConnectionStatus: Equatable {
        case connected
        case disconnected
        case fileMissing
    }

    /// Errors surfaced inline in the setup card when auto-configure fails.
    enum AutoConfigureError: Error, Equatable {
        case readFailed(String)
        case writeFailed(String)
        case backupFailed(String)
        case decodeFailed(String)
    }

    let settingsURL: URL
    let backupURL: URL
    /// `cmux statusline` (Release) or `cmux-dev statusline` (tagged Debug).
    let desiredStatusLineCommand: String
    let desiredCompactHookCommand: String

    init(
        settingsURL: URL = ClaudeSettingsInspector.defaultSettingsURL,
        backupURL: URL = ClaudeSettingsInspector.defaultBackupURL,
        statusLineCommand: String = ClaudeSettingsInspector.defaultStatusLineCommand,
        compactHookCommand: String = ClaudeSettingsInspector.defaultCompactHookCommand
    ) {
        self.settingsURL = settingsURL
        self.backupURL = backupURL
        self.desiredStatusLineCommand = statusLineCommand
        self.desiredCompactHookCommand = compactHookCommand
    }

    // MARK: - Default paths / commands

    static var defaultSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    static var defaultBackupURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json.bak")
    }

    /// Tagged Debug builds set `CMUX_DEV_CLI_BINARY_NAME=cmux-dev` at compile
    /// time (via Info.plist) so the spec's requirement — Release → `cmux` and
    /// tagged → `cmux-dev` — resolves automatically. For unit tests we fall
    /// back to `cmux` so deterministic assertions hold.
    static var defaultStatusLineCommand: String {
        let binaryName = Bundle.main.object(forInfoDictionaryKey: "CMUXCLIBinaryName") as? String
        let prefix = binaryName?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "cmux"
        return "\(prefix) statusline"
    }

    static var defaultCompactHookCommand: String {
        let binaryName = Bundle.main.object(forInfoDictionaryKey: "CMUXCLIBinaryName") as? String
        let prefix = binaryName?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "cmux"
        return "\(prefix) record-compact"
    }

    // MARK: - Session-tracking hooks

    /// Claude event → `cmux claude-hook <subcommand>` mapping. These hooks
    /// populate `~/.cmuxterm/claude-hook-sessions.json` — the store
    /// `RestorableAgentSessionIndex.load()` reads so the app can auto-resume
    /// the agent session attached to each terminal tab after relaunch.
    /// Without them, both the save-path (`Workspace.sessionSnapshot`) and
    /// the restore-path (`Workspace.createPanel`) run against an empty
    /// index and restored tabs come up as blank shells.
    ///
    /// Essential for session restore:
    ///   - `SessionStart`   → seeds the store with (sessionId, workspaceId, surfaceId)
    ///   - `PreToolUse`     → keeps the record fresh on every tool call
    ///   - `Stop` / `SessionEnd` → clears the record so dead sessions don't
    ///     resurface on the next relaunch
    ///
    /// Nice-to-have for status/notifications:
    ///   - `UserPromptSubmit` / `Notification` — used elsewhere in cmux to
    ///     surface "needs attention" chrome; included here so users get the
    ///     full integration from one opt-in.
    static let claudeSessionHookEvents: [(event: String, subcommand: String)] = [
        ("SessionStart", "session-start"),
        ("PreToolUse", "pre-tool-use"),
        ("Stop", "stop"),
        ("SessionEnd", "session-end"),
        ("Notification", "notification"),
        ("UserPromptSubmit", "prompt-submit"),
    ]

    /// Concrete command strings for each session-tracking hook, resolved
    /// against the active binary name (`cmux` or `cmux-dev`). Computed so
    /// tagged Debug builds get `cmux-dev claude-hook …` without test setup.
    var desiredSessionHookCommands: [(event: String, command: String)] {
        let binaryName = Bundle.main.object(forInfoDictionaryKey: "CMUXCLIBinaryName") as? String
        let prefix = binaryName?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "cmux"
        return Self.claudeSessionHookEvents.map {
            (event: $0.event, command: "\(prefix) claude-hook \($0.subcommand)")
        }
    }

    // MARK: - Classify

    /// Returns the current connection status by inspecting the settings file.
    /// Pure: no side effects.
    func classifyConnectionStatus() -> ConnectionStatus {
        let fm = FileManager.default
        if !fm.fileExists(atPath: settingsURL.path) {
            return .fileMissing
        }
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return .disconnected
        }
        return Self.isCmuxStatuslineCommand(command) ? .connected : .disconnected
    }

    /// Pure matcher for the "command" string we consider "connected". Accepts
    /// bare `cmux statusline`, `cmux-dev statusline`, or any absolute path
    /// that ends in `/cmux` or `/cmux-dev` followed by ` statusline`.
    static func isCmuxStatuslineCommand(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "cmux statusline" || trimmed == "cmux-dev statusline" {
            return true
        }
        // Absolute path form: `/abs/path/to/cmux[-dev] statusline [extra...]`
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return false }
        let exe = (parts[0] as NSString).lastPathComponent
        guard exe == "cmux" || exe == "cmux-dev" else { return false }
        return parts[1].hasPrefix("statusline")
    }

    /// Pure matcher for a `cmux claude-hook <subcommand>` command string.
    /// Accepts bare or absolute-path binary + matches the subcommand token
    /// so an absolute-path entry still reads as "installed".
    static func isCmuxClaudeHookCommand(_ raw: String, subcommand: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return false }
        let exe = (parts[0] as NSString).lastPathComponent
        guard exe == "cmux" || exe == "cmux-dev" else { return false }
        guard parts[1] == "claude-hook" else { return false }
        return parts[2] == subcommand
    }

    /// True when every Claude event in `claudeSessionHookEvents` has at
    /// least one hook entry pointing at `cmux claude-hook <subcommand>`.
    /// Used by the migration path on app start to decide whether an
    /// already-"connected" user (statusLine set, pre-session-hooks era)
    /// needs to have the session hooks appended. Returns false on a
    /// missing / unreadable settings file too.
    func hasCompleteSessionTrackingSetup() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let hooksDict = (parsed["hooks"] as? [String: Any]) ?? [:]
        for entry in Self.claudeSessionHookEvents {
            guard let eventEntries = hooksDict[entry.event] as? [[String: Any]] else {
                return false
            }
            let hasCmuxHook = eventEntries.contains { outer in
                guard let nested = outer["hooks"] as? [[String: Any]] else { return false }
                return nested.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return Self.isCmuxClaudeHookCommand(command, subcommand: entry.subcommand)
                }
            }
            if !hasCmuxHook { return false }
        }
        return true
    }

    /// One-shot migration hook. If `classifyConnectionStatus() == .connected`
    /// (the user already opted into cmux's settings integration at some
    /// point) but the session-tracking hooks are missing, re-run
    /// `autoConfigureAtomic` so the appended hooks land without requiring
    /// the user to click "Auto-configure" again. No-op for fresh installs
    /// (they go through the normal setup card flow) and for users who
    /// never opted in. Swallows failures — the setup card remains
    /// available for manual retry if the silent attempt didn't land.
    @discardableResult
    func migrateSessionTrackingHooksIfNeeded() -> Bool {
        guard classifyConnectionStatus() == .connected else { return false }
        guard !hasCompleteSessionTrackingSetup() else { return false }
        do {
            try autoConfigureAtomic()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Auto-configure

    /// Merge the desired `statusLine.command` + `hooks.PreCompact` into the
    /// settings file atomically. `.bak` is write-once (per spec) so repeated
    /// clicks never overwrite the user's pre-cmux snapshot.
    func autoConfigureAtomic() throws {
        let fm = FileManager.default

        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existingData: Data? = try? Data(contentsOf: settingsURL)

        // Backup only on first run when there is something to back up.
        if let existingData,
           !existingData.isEmpty,
           !fm.fileExists(atPath: backupURL.path) {
            do {
                try existingData.write(to: backupURL, options: .atomic)
            } catch {
                throw AutoConfigureError.backupFailed(error.localizedDescription)
            }
        }

        var json: [String: Any]
        if let existingData, !existingData.isEmpty {
            do {
                let parsed = try JSONSerialization.jsonObject(with: existingData)
                guard let dict = parsed as? [String: Any] else {
                    throw AutoConfigureError.decodeFailed("Top-level value is not an object")
                }
                json = dict
            } catch {
                throw AutoConfigureError.decodeFailed(error.localizedDescription)
            }
        } else {
            json = [:]
        }

        json = Self.mergeStatusline(into: json, command: desiredStatusLineCommand)
        json = Self.mergePreCompactHook(into: json, command: desiredCompactHookCommand)
        // Session-tracking hooks populate the on-disk panel↔session map the
        // restore path falls back to. Installed idempotently alongside the
        // long-standing statusLine + PreCompact merges; existing non-cmux
        // entries under the same event are preserved (see `mergeCommandHook`).
        for entry in desiredSessionHookCommands {
            json = Self.mergeCommandHook(into: json, event: entry.event, command: entry.command)
        }

        let newData: Data
        do {
            newData = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw AutoConfigureError.writeFailed("Re-encode failed: \(error.localizedDescription)")
        }

        do {
            try newData.write(to: settingsURL, options: .atomic)
        } catch {
            throw AutoConfigureError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Pure merge helpers (exposed for tests)

    static func mergeStatusline(into json: [String: Any], command: String) -> [String: Any] {
        var copy = json
        copy["statusLine"] = [
            "type": "command",
            "command": command
        ]
        return copy
    }

    static func mergePreCompactHook(into json: [String: Any], command: String) -> [String: Any] {
        mergeCommandHook(into: json, event: "PreCompact", command: command)
    }

    /// Generic idempotent merge of a Claude `hooks.<event>` entry. Appends
    /// `{matcher:"", hooks:[{type:"command", command:<command>}]}` to the
    /// event's array if no existing entry under that event already invokes
    /// `<command>`. Leaves unrelated entries for the same event in place so
    /// a user's own hook scripts coexist with cmux's.
    static func mergeCommandHook(
        into json: [String: Any],
        event: String,
        command: String
    ) -> [String: Any] {
        var copy = json
        var hooks = (copy["hooks"] as? [String: Any]) ?? [:]
        var entries = (hooks[event] as? [[String: Any]]) ?? []

        // Check if an entry already invokes `command`.
        let alreadyPresent = entries.contains { entry in
            guard let nested = entry["hooks"] as? [[String: Any]] else { return false }
            return nested.contains { hook in
                (hook["command"] as? String) == command
            }
        }
        if alreadyPresent {
            hooks[event] = entries
            copy["hooks"] = hooks
            return copy
        }

        entries.append([
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": command
            ]]
        ])
        hooks[event] = entries
        copy["hooks"] = hooks
        return copy
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
