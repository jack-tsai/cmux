import Foundation

/// Decides which panel a File Explorer Cmd+Click should open, given a path
/// and a workspace. Pure function — no UI side effects — so it can be tested
/// without standing up a workspace controller.
public enum FileOpenDispatcher {

    /// One of four outcomes for Cmd+Click on a file row.
    public enum Decision: Equatable, Sendable {
        case markdown(path: String)
        case diff(path: String)
        case preview(path: String)
        case unsupported
    }

    /// Inputs the dispatcher needs from the environment. Abstracted so tests
    /// can supply pure fixtures instead of shelling out to real `git`.
    public struct Environment {
        public var isRemoteWorkspace: Bool
        public var symlinkTarget: (String) -> String?
        public var isDirectory: (String) -> Bool
        public var pathExists: (String) -> Bool
        public var gitStatus: (_ path: String, _ workspaceDirectory: String) -> GitStatus
        public var workspaceDirectory: String

        public init(
            isRemoteWorkspace: Bool,
            symlinkTarget: @escaping (String) -> String?,
            isDirectory: @escaping (String) -> Bool,
            pathExists: @escaping (String) -> Bool,
            gitStatus: @escaping (String, String) -> GitStatus,
            workspaceDirectory: String
        ) {
            self.isRemoteWorkspace = isRemoteWorkspace
            self.symlinkTarget = symlinkTarget
            self.isDirectory = isDirectory
            self.pathExists = pathExists
            self.gitStatus = gitStatus
            self.workspaceDirectory = workspaceDirectory
        }
    }

    public enum GitStatus: Equatable, Sendable {
        case modified   // M / A / R / D etc. — has a HEAD baseline to diff against.
        case untracked  // ?? — no HEAD baseline.
        case clean      // Tracked, no changes.
        case notARepo   // Path lives outside a git working tree.
    }

    /// Apply the dispatch rules for `path` inside `environment`.
    public static func decide(path: String, environment: Environment) -> Decision {
        // Task 3.11 / 4.2: SSH short-circuits before any further work.
        if environment.isRemoteWorkspace {
            return .unsupported
        }

        // Task 4.8: resolve symlinks first. Broken symlinks → unsupported.
        var resolvedPath = path
        if let target = environment.symlinkTarget(path) {
            let absolute = (target as NSString).isAbsolutePath
                ? target
                : ((path as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent(target)
            let canonical = (absolute as NSString).standardizingPath
            if !environment.pathExists(canonical) {
                return .unsupported
            }
            resolvedPath = canonical
        }

        // Task 4.7: directory rows never open a panel.
        if environment.isDirectory(resolvedPath) {
            return .unsupported
        }

        let lower = resolvedPath.lowercased()
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") {
            return .markdown(path: resolvedPath)
        }

        let status = environment.gitStatus(resolvedPath, environment.workspaceDirectory)
        switch status {
        case .modified:
            return .diff(path: resolvedPath)
        case .untracked, .clean, .notARepo:
            return .preview(path: resolvedPath)
        }
    }

    // MARK: - Live environment factory

    /// Build an `Environment` backed by real filesystem calls and `git status`.
    public static func liveEnvironment(
        workspaceDirectory: String,
        isRemoteWorkspace: Bool,
        gitExecutablePath: String = "/usr/bin/git"
    ) -> Environment {
        Environment(
            isRemoteWorkspace: isRemoteWorkspace,
            symlinkTarget: { path in
                try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            },
            isDirectory: { path in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                return exists && isDir.boolValue
            },
            pathExists: { path in
                FileManager.default.fileExists(atPath: path)
            },
            gitStatus: { path, cwd in
                liveGitStatus(
                    filePath: path,
                    workspaceDirectory: cwd,
                    gitExecutablePath: gitExecutablePath
                )
            },
            workspaceDirectory: workspaceDirectory
        )
    }

    private static func liveGitStatus(
        filePath: String,
        workspaceDirectory: String,
        gitExecutablePath: String
    ) -> GitStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutablePath)
        process.arguments = ["status", "--porcelain", "--", filePath]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceDirectory)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        process.environment = env

        do {
            try process.run()
        } catch {
            return .notARepo
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            return .notARepo
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return .clean
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .clean
        }

        // Porcelain line: first two columns are XY status codes. `??` is
        // untracked; anything else means tracked-with-changes for our purposes.
        let first = trimmed.split(separator: "\n").first.map(String.init) ?? ""
        let prefix = String(first.prefix(2))
        if prefix == "??" {
            return .untracked
        }
        return .modified
    }
}
