import Foundation

/// Which side-by-side comparison the `DiffPanel` is displaying.
public enum DiffMode: Equatable, Hashable, Sendable {
    /// Working copy vs HEAD for a single file. Used by File Explorer Cmd+Click.
    case workingCopyVsHead(path: String)
    /// Single-commit diff vs its first parent for a single file. Used by Git Graph.
    case commitVsParent(sha: String, path: String)
}

/// One line inside a hunk. `kind` tells the view how to colour / format it.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case context
        case added
        case removed
        case hunkHeader
        case noNewlineAtEof
    }

    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// One `@@ ... @@` block within a file diff.
public struct DiffHunk: Equatable, Sendable {
    public let header: String
    public let lines: [DiffLine]
    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }
}

/// The parsed result of a `git diff` invocation for a single file.
public struct FileDiff: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        case binary
    }

    public let kind: Kind
    public let path: String
    public let hunks: [DiffHunk]

    /// Header lines that precede the first hunk (`diff --git`, `index`, `---`, `+++`).
    /// Retained so the view can surface rename or mode-change metadata if desired.
    public let headerLines: [String]

    /// True when `git diff` produced no output at all (working copy matches HEAD).
    public var isEmpty: Bool {
        hunks.isEmpty && kind == .text
    }

    public init(
        kind: Kind,
        path: String,
        hunks: [DiffHunk],
        headerLines: [String] = []
    ) {
        self.kind = kind
        self.path = path
        self.hunks = hunks
        self.headerLines = headerLines
    }
}

/// Runs `git diff` / `git show` and parses the unified output into value types.
/// All process work is synchronous; callers SHOULD invoke from a background queue.
public enum DiffProvider {

    // MARK: - Public API

    /// Fetch the unified diff for `mode` rooted at `workingDirectory`.
    /// Returns `nil` when git is unavailable or the invocation fails in a way
    /// that cannot be surfaced as an empty / binary `FileDiff`. The caller
    /// distinguishes "no changes" (returns a `FileDiff` with `isEmpty == true`)
    /// from "git failed" (returns nil).
    public static func fetchDiff(
        mode: DiffMode,
        workingDirectory: String,
        gitExecutablePath: String = "/usr/bin/git"
    ) -> FileDiff? {
        let arguments: [String]
        let path: String
        switch mode {
        case .workingCopyVsHead(let p):
            // Task 3.13: rename detection off. New path only. Single arg.
            arguments = ["diff", "HEAD", "--", p]
            path = p
        case .commitVsParent(let sha, let p):
            // Task 3.12: merge-commit handling — `<sha>^1` pins the first
            // parent explicitly so git never falls back to combined diff.
            arguments = ["diff", "\(sha)^1", sha, "--", p]
            path = p
        }

        guard let raw = runGit(
            executable: gitExecutablePath,
            arguments: arguments,
            workingDirectory: workingDirectory
        ) else {
            return nil
        }

        return parse(rawOutput: raw, fallbackPath: path)
    }

    // MARK: - Parser (task 3.2)

    /// Parse the raw unified-diff output `git diff` emitted for a *single* path.
    /// Exposed for tests; callers normally go through `fetchDiff`.
    public static func parse(rawOutput: String, fallbackPath: String) -> FileDiff {
        if rawOutput.isEmpty {
            return FileDiff(kind: .text, path: fallbackPath, hunks: [])
        }

        // Task 3.2: detect binary marker up-front; `git diff` emits
        // `Binary files a/<path> and b/<path> differ` for non-text blobs.
        if rawOutput.range(of: #"^Binary files .* differ$"#, options: .regularExpression) != nil {
            return FileDiff(kind: .binary, path: resolvedPath(rawOutput: rawOutput) ?? fallbackPath, hunks: [])
        }

        var headerLines: [String] = []
        var hunks: [DiffHunk] = []
        var currentHeader: String? = nil
        var currentLines: [DiffLine] = []

        func flushHunk() {
            guard let header = currentHeader else { return }
            hunks.append(DiffHunk(header: header, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        // Keep trailing empty lines; unified diffs treat them meaningfully.
        let rawLines = rawOutput.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" }
        ).map(String.init)

        // Some git outputs end with a trailing newline producing a spurious
        // empty string; drop it so we don't emit a phantom context row.
        let lines: [String] = {
            guard let last = rawLines.last, last.isEmpty, rawLines.count > 1 else {
                return rawLines
            }
            return Array(rawLines.dropLast())
        }()

        for line in lines {
            if line.hasPrefix("@@") {
                flushHunk()
                currentHeader = line
                continue
            }
            if currentHeader == nil {
                // Pre-hunk metadata (`diff --git ...`, `index ...`, `--- a/...`, `+++ b/...`).
                headerLines.append(line)
                continue
            }
            if line.hasPrefix("+") {
                currentLines.append(DiffLine(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                currentLines.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix(" ") {
                currentLines.append(DiffLine(kind: .context, text: String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                // `\ No newline at end of file`
                currentLines.append(DiffLine(kind: .noNewlineAtEof, text: line))
            } else if line.isEmpty {
                // Blank context line in a hunk (git strips the leading space
                // when the full line was empty). Preserve the blank row.
                currentLines.append(DiffLine(kind: .context, text: ""))
            } else {
                // Fall back to context; anomalous but keep going so we render
                // something rather than throwing the whole diff away.
                currentLines.append(DiffLine(kind: .context, text: line))
            }
        }
        flushHunk()

        let resolved = resolvedPath(headerLines: headerLines) ?? fallbackPath
        return FileDiff(kind: .text, path: resolved, hunks: hunks, headerLines: headerLines)
    }

    // MARK: - Helpers

    private static func resolvedPath(rawOutput: String) -> String? {
        let firstLine = rawOutput.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return resolvedPath(headerLines: [firstLine])
    }

    private static func resolvedPath(headerLines: [String]) -> String? {
        // Prefer `+++ b/<path>`; fall back to `--- a/<path>` or `diff --git`.
        for line in headerLines where line.hasPrefix("+++ b/") {
            return String(line.dropFirst("+++ b/".count))
        }
        for line in headerLines where line.hasPrefix("--- a/") {
            return String(line.dropFirst("--- a/".count))
        }
        for line in headerLines where line.hasPrefix("diff --git ") {
            let components = line.split(separator: " ")
            if components.count >= 4 {
                let b = String(components[3])
                if b.hasPrefix("b/") { return String(b.dropFirst(2)) }
                return b
            }
        }
        return nil
    }

    private static func runGit(
        executable: String,
        arguments: [String],
        workingDirectory: String
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Keep environment minimal so user git config doesn't paginate.
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["LC_ALL"] = "C"
        process.environment = env

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            // Non-UTF8 output is almost always a binary diff in disguise.
            return ""
        }
        return output
    }
}
