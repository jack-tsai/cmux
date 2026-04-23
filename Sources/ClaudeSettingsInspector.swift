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
        var copy = json
        var hooks = (copy["hooks"] as? [String: Any]) ?? [:]
        var preCompact = (hooks["PreCompact"] as? [[String: Any]]) ?? []

        // Check if an entry already invokes `command`.
        let alreadyPresent = preCompact.contains { entry in
            guard let nested = entry["hooks"] as? [[String: Any]] else { return false }
            return nested.contains { hook in
                (hook["command"] as? String) == command
            }
        }
        if alreadyPresent {
            hooks["PreCompact"] = preCompact
            copy["hooks"] = hooks
            return copy
        }

        preCompact.append([
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": command
            ]]
        ])
        hooks["PreCompact"] = preCompact
        copy["hooks"] = hooks
        return copy
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
