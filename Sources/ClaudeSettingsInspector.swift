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
    ///
    /// The command string is an **absolute path** to the bundled CLI binary,
    /// not a bare name. The bare-name form used to be written here, which
    /// sent Claude's hook dispatcher to whatever `cmux` happened to win the
    /// `$PATH` race — on at least one user's machine that was Oracle Instant
    /// Client's `cmux`, which cheerfully prints "OK" and exits 0, swallowing
    /// the hook call and leaving `~/.cmuxterm/claude-hook-sessions.json`
    /// unwritten. Pinning to the `.app` bundle's copy of the CLI sidesteps
    /// every PATH-shadowing class of bug for the same cost as the bare form.
    static var defaultStatusLineCommand: String {
        "\(bundledCLIAbsolutePath) statusline"
    }

    static var defaultCompactHookCommand: String {
        "\(bundledCLIAbsolutePath) record-compact"
    }

    /// Absolute path to the bundled `cmux` (or `cmux-dev`) CLI, resolved off
    /// the running app bundle. Falls back to the bare binary name when the
    /// bundle resource path is unavailable (unit tests) so string assertions
    /// against the default commands still hold.
    static var bundledCLIAbsolutePath: String {
        let binaryName = Bundle.main.object(forInfoDictionaryKey: "CMUXCLIBinaryName") as? String
        let name = binaryName?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "cmux"
        guard let resourcePath = Bundle.main.resourcePath else { return name }
        return "\(resourcePath)/bin/\(name)"
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
    /// against the bundled CLI's **absolute path** (`cmux` or `cmux-dev`).
    /// Absolute on purpose — see `defaultStatusLineCommand` for the PATH
    /// collision story. The user whose diagnosis triggered this fix had a
    /// different `cmux` (Oracle Instant Client) winning PATH resolution, so
    /// the bare-name hook quietly no-op'd on every invocation.
    var desiredSessionHookCommands: [(event: String, command: String)] {
        let binary = Self.bundledCLIAbsolutePath
        return Self.claudeSessionHookEvents.map {
            (event: $0.event, command: "\(binary) claude-hook \($0.subcommand)")
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
    /// least one hook entry whose command exactly matches the current
    /// `desiredSessionHookCommands` target (absolute path to this bundle's
    /// CLI). Used by the migration path on app start to decide whether an
    /// already-"connected" user needs the session hooks re-written. Returns
    /// false on a missing / unreadable settings file too.
    ///
    /// Why exact-match on the absolute path: an older cmux release installed
    /// these hooks as a bare name (`cmux claude-hook …`). If that lands
    /// ahead of the real cmux in `$PATH` (Oracle Instant Client ships a
    /// `cmux`, so this isn't hypothetical), the hook silently no-ops.
    /// Requiring the exact absolute-path command means the migration re-runs
    /// on upgrade and appends the reliable form alongside whatever was there
    /// before. `mergeCommandHook` is idempotent on the new command, so this
    /// stabilises after one migration tick.
    func hasCompleteSessionTrackingSetup() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let hooksDict = (parsed["hooks"] as? [String: Any]) ?? [:]
        for entry in desiredSessionHookCommands {
            guard let eventEntries = hooksDict[entry.event] as? [[String: Any]] else {
                return false
            }
            let hasDesired = eventEntries.contains { outer in
                guard let nested = outer["hooks"] as? [[String: Any]] else { return false }
                return nested.contains { hook in
                    (hook["command"] as? String) == entry.command
                }
            }
            if !hasDesired { return false }
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
