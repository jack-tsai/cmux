import Foundation

// MARK: - Value Types (Task 1.3)

/// State of the repository the Git Graph panel is bound to.
enum GitGraphRepoState: Equatable {
    case repo(toplevel: String, hasCommits: Bool)
    case notARepo
    case gitUnavailable
}

/// A branch, tag, remote-tracking, or HEAD ref pointing at a commit.
struct GitRef: Equatable, Hashable, Codable {
    enum Kind: String, Codable { case localBranch, remoteBranch, tag, head }
    let name: String
    let kind: Kind
}

/// One commit in the graph with its lane assignment.
struct CommitNode: Equatable, Identifiable, Hashable {
    let sha: String
    let parents: [String]
    let authorName: String
    let authorEmail: String
    /// Unix seconds (committer / author date).
    let timestamp: TimeInterval
    let subject: String
    let refs: [GitRef]
    /// Lane index within the rendered graph column (0-based).
    let laneIndex: Int
    /// Lane indices that this commit connects to in the row below (to parents).
    /// Used by the renderer to draw connector lines from the commit dot down
    /// to parent lane positions (merge lines bending sideways to merge sources).
    let parentLanes: [Int]
    /// Lanes occupied by unrelated in-flight branches that pass through this
    /// row but do not originate or terminate here. The renderer draws a plain
    /// vertical segment in each of these lanes.
    let passThroughLanes: [Int]

    var id: String { sha }
    var shortSha: String { String(sha.prefix(8)) }
    var date: Date { Date(timeIntervalSince1970: timestamp) }
}

struct BranchRef: Equatable, Hashable {
    /// Full name (`main`, `feature-x`, `origin/main`).
    let name: String
    let sha: String
    let isRemote: Bool
}

struct TagRef: Equatable, Hashable {
    let name: String
    let sha: String
}

struct StashEntry: Equatable, Hashable {
    /// `stash@{0}`, `stash@{1}`, etc.
    let ref: String
    let subject: String
    let sha: String
}

struct WorktreeEntry: Equatable, Hashable {
    let path: String
    /// Branch checked out in this worktree, if any.
    let branch: String?
    let headSha: String?
    let isBare: Bool
    let isDetached: Bool
    let isLocked: Bool
}

/// One file touched by a commit with its numstat (added / deleted line counts).
struct FileChange: Equatable, Hashable {
    let path: String
    /// `git show --numstat` prints `-` for binary files; these map to nil here.
    let added: Int?
    let deleted: Int?

    var isBinary: Bool { added == nil && deleted == nil }
}

/// Full commit information loaded lazily when a commit row is expanded.
struct CommitDetail: Equatable {
    let sha: String
    let parents: [String]
    let authorName: String
    let authorEmail: String
    let committerName: String
    let committerEmail: String
    let authorDate: Date
    let committerDate: Date
    let fullMessage: String
    let files: [FileChange]
}

/// Complete read-only snapshot consumed by the UI.
struct GitGraphSnapshot: Equatable {
    let repoState: GitGraphRepoState
    let commits: [CommitNode]
    /// SHA that HEAD resolves to (may not appear in `commits` if outside fetch window).
    let headSha: String?
    let headBranch: String?
    let isDetachedHead: Bool
    let uncommittedCount: Int
    let branches: [BranchRef]
    let tags: [TagRef]
    let stashes: [StashEntry]
    let worktrees: [WorktreeEntry]
    /// Set to true when the snapshot was truncated at the fetch limit.
    let hasMoreCommits: Bool

    static let empty = GitGraphSnapshot(
        repoState: .notARepo,
        commits: [],
        headSha: nil,
        headBranch: nil,
        isDetachedHead: false,
        uncommittedCount: 0,
        branches: [],
        tags: [],
        stashes: [],
        worktrees: [],
        hasMoreCommits: false
    )
}

// MARK: - Provider (Tasks 1.4, 1.5, 1.6, 2.1)

/// Runs read-only `git` commands in a workspace directory and parses the output
/// into structured snapshots. Mirrors the `GitStatusProvider` style used by
/// `FileExplorerStore`: static functions, no stored state, safe to call from a
/// background queue.
///
/// SSH variants are defined alongside local ones so `GitGraphPanel` view models
/// can pick based on workspace type. SSH support is added in a later task.
enum GitGraphProvider {

    // MARK: Public API

    /// Detects whether `directory` is inside a git repo and returns its toplevel.
    static func detectRepoState(directory: String) -> GitGraphRepoState {
        // `git rev-parse --show-toplevel` returns the worktree root on stdout,
        // or fails if `directory` is not inside a repo. Presence of the `git`
        // executable itself is checked first so remote/missing-tool paths can
        // be distinguished from "not a repo".
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            return .gitUnavailable
        }
        guard let top = runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty
        else {
            return .notARepo
        }
        // `rev-parse HEAD` fails on a freshly-initialized repo with no commits.
        let hasCommits = runGit(in: directory, arguments: ["rev-parse", "--verify", "HEAD"]) != nil
        return .repo(toplevel: top, hasCommits: hasCommits)
    }

    /// Fetches up to `limit` commits using topo-order. Fixed ordering —
    /// per design, `--date-order` is not exposed to users.
    /// When `branchFilter` is nil, queries `--all`; otherwise `<branch>`.
    static func fetchCommits(
        directory: String,
        limit: Int,
        skip: Int = 0,
        branchFilter: String? = nil
    ) -> [CommitNode] {
        var args = ["log", "--topo-order"]
        args.append(contentsOf: ["-n", String(limit)])
        if skip > 0 {
            args.append(contentsOf: ["--skip", String(skip)])
        }
        // NUL-separate fields; RS (0x1E) separate records so parser is
        // byte-safe against commit messages containing newlines and tabs.
        args.append("--format=%x1e%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s")
        if let branchFilter {
            args.append(branchFilter)
        } else {
            args.append("--all")
        }
        guard let output = runGit(in: directory, arguments: args) else { return [] }
        return parseCommits(output: output)
    }

    /// Counts uncommitted paths via `git status --porcelain`.
    /// A path is counted if its two status chars indicate any change.
    static func fetchUncommittedCount(directory: String) -> Int {
        guard let output = runGit(in: directory, arguments: ["status", "--porcelain"]) else {
            return 0
        }
        var count = 0
        output.enumerateLines { line, _ in
            // Porcelain lines are at least 3 chars: `XY path`.
            if line.count >= 3 { count += 1 }
        }
        return count
    }

    /// Resolves `HEAD` to a commit SHA, or nil if detached with no commits / not a repo.
    static func fetchHeadSha(directory: String) -> String? {
        runGit(in: directory, arguments: ["rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the local branch name HEAD points to, or nil when detached.
    static func fetchHeadBranch(directory: String) -> String? {
        // `symbolic-ref --short HEAD` prints `main` when on a branch and
        // exits non-zero when HEAD is detached; `runGit` returns nil in that case.
        runGit(in: directory, arguments: ["symbolic-ref", "--short", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lists local + remote-tracking branches. Tab separates fields per ref
    /// (git `for-each-ref` ignores the `%x00` log-format placeholder, and
    /// passing a literal NUL byte as a process argument aborts Foundation's
    /// argv conversion — so `\t` is the safest inert separator that cannot
    /// appear in ref names or SHAs); each ref ends with a newline.
    static func fetchBranches(directory: String) -> [BranchRef] {
        let args = [
            "for-each-ref",
            "--format=%(refname)\t%(objectname)",
            "refs/heads/",
            "refs/remotes/"
        ]
        guard let output = runGit(in: directory, arguments: args) else { return [] }
        var refs: [BranchRef] = []
        output.enumerateLines { line, _ in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            let full = String(parts[0])
            let sha = String(parts[1])
            let isRemote = full.hasPrefix("refs/remotes/")
            let name: String
            if isRemote {
                name = String(full.dropFirst("refs/remotes/".count))
                // Skip the synthetic `origin/HEAD -> origin/main` alias.
                if name.hasSuffix("/HEAD") { return }
            } else {
                name = String(full.dropFirst("refs/heads/".count))
            }
            refs.append(BranchRef(name: name, sha: sha, isRemote: isRemote))
        }
        return refs
    }

    /// Lists annotated + lightweight tags. Tags can point at tag objects,
    /// so we resolve `%(*objectname)` (target commit) with fallback to
    /// `%(objectname)` for lightweight tags that directly reference a commit.
    /// See fetchBranches() for why the separator is Tab.
    static func fetchTags(directory: String) -> [TagRef] {
        let args = [
            "for-each-ref",
            "--format=%(refname:short)\t%(objectname)\t%(*objectname)",
            "refs/tags/"
        ]
        guard let output = runGit(in: directory, arguments: args) else { return [] }
        var tags: [TagRef] = []
        output.enumerateLines { line, _ in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return }
            let name = String(parts[0])
            let objSha = String(parts[1])
            let resolvedSha = String(parts[2])
            let commitSha = resolvedSha.isEmpty ? objSha : resolvedSha
            tags.append(TagRef(name: name, sha: commitSha))
        }
        return tags
    }

    /// Lists stash entries. `%gd` is the stash selector (e.g. `stash@{0}`),
    /// `%s` the subject, `%H` the commit SHA.
    static func fetchStashes(directory: String) -> [StashEntry] {
        let args = [
            "stash",
            "list",
            "--format=%gd%x00%H%x00%s"
        ]
        guard let output = runGit(in: directory, arguments: args) else { return [] }
        var stashes: [StashEntry] = []
        output.enumerateLines { line, _ in
            let parts = line.split(separator: "\u{00}", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return }
            stashes.append(StashEntry(
                ref: String(parts[0]),
                subject: String(parts[2]),
                sha: String(parts[1])
            ))
        }
        return stashes
    }

    /// Parses `git worktree list --porcelain`. Entries are blank-line separated;
    /// each contains `worktree <path>`, `HEAD <sha>`, one of `branch <ref>` /
    /// `detached` / `bare`, and optionally `locked`.
    static func fetchWorktrees(directory: String) -> [WorktreeEntry] {
        guard let output = runGit(in: directory, arguments: ["worktree", "list", "--porcelain"]) else {
            return []
        }
        var worktrees: [WorktreeEntry] = []
        var currentPath: String?
        var currentHead: String?
        var currentBranch: String?
        var currentBare = false
        var currentDetached = false
        var currentLocked = false

        func flush() {
            guard let path = currentPath else { return }
            worktrees.append(WorktreeEntry(
                path: path,
                branch: currentBranch,
                headSha: currentHead,
                isBare: currentBare,
                isDetached: currentDetached,
                isLocked: currentLocked
            ))
            currentPath = nil
            currentHead = nil
            currentBranch = nil
            currentBare = false
            currentDetached = false
            currentLocked = false
        }

        output.enumerateLines { line, _ in
            if line.isEmpty {
                flush()
                return
            }
            if line.hasPrefix("worktree ") {
                // New entry starts — flush the previous one if we forgot to
                // on a missing trailing blank line.
                if currentPath != nil { flush() }
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                currentHead = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                var branch = String(line.dropFirst("branch ".count))
                if branch.hasPrefix("refs/heads/") {
                    branch = String(branch.dropFirst("refs/heads/".count))
                }
                currentBranch = branch
            } else if line == "detached" {
                currentDetached = true
            } else if line == "bare" {
                currentBare = true
            } else if line.hasPrefix("locked") {
                currentLocked = true
            }
        }
        flush()
        return worktrees
    }

    /// Loads full commit detail including per-file numstat. Uses `%n` to
    /// embed newlines inside the message safely because the format string
    /// ends with a sentinel line that separates metadata from numstat.
    static func fetchCommitDetail(directory: String, sha: String) -> CommitDetail? {
        // Output layout:
        //   %H\n
        //   %P\n
        //   %an\n
        //   %ae\n
        //   %cn\n
        //   %ce\n
        //   %at\n
        //   %ct\n
        //   %B                <-- full message (may span many lines)
        //   ---CMUX-NUMSTAT---
        //   added\tdeleted\tpath
        //   added\tdeleted\tpath
        //   ...
        let separator = "---CMUX-NUMSTAT---"
        let format = "%H%n%P%n%an%n%ae%n%cn%n%ce%n%at%n%ct%n%B%n\(separator)"
        let args = ["show", "--numstat", "--format=\(format)", sha]
        guard let output = runGit(in: directory, arguments: args) else { return nil }

        guard let sepRange = output.range(of: "\n\(separator)\n")
            ?? output.range(of: "\n\(separator)") else {
            return nil
        }
        let metaPart = String(output[..<sepRange.lowerBound])
        let numstatPart = String(output[sepRange.upperBound...])

        let metaLines = metaPart.components(separatedBy: "\n")
        guard metaLines.count >= 9 else { return nil }

        let parents = metaLines[1]
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let authorName = metaLines[2]
        let authorEmail = metaLines[3]
        let committerName = metaLines[4]
        let committerEmail = metaLines[5]
        let authorTs = TimeInterval(metaLines[6]) ?? 0
        let committerTs = TimeInterval(metaLines[7]) ?? 0
        // Everything from index 8 onward (until the final separator) is the
        // body of the commit message. Trim the trailing blank line `git show`
        // injects between the body and numstat.
        let fullMessage = metaLines.dropFirst(8)
            .joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet.newlines)

        var files: [FileChange] = []
        for line in numstatPart.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let addedStr = String(parts[0])
            let deletedStr = String(parts[1])
            let path = String(parts[2])
            let added = addedStr == "-" ? nil : Int(addedStr)
            let deleted = deletedStr == "-" ? nil : Int(deletedStr)
            files.append(FileChange(path: path, added: added, deleted: deleted))
        }

        return CommitDetail(
            sha: metaLines[0],
            parents: parents,
            authorName: authorName,
            authorEmail: authorEmail,
            committerName: committerName,
            committerEmail: committerEmail,
            authorDate: Date(timeIntervalSince1970: authorTs),
            committerDate: Date(timeIntervalSince1970: committerTs),
            fullMessage: fullMessage,
            files: files
        )
    }

    // MARK: Parsing

    /// Parses the record-separated output of `git log --format=%x1e...`.
    /// Each record:
    ///   RS %H NUL %P NUL %an NUL %ae NUL %at NUL %D NUL %s
    /// - `%P`: space-separated parent SHAs (may be empty for root commit).
    /// - `%D`: comma-separated ref names with `HEAD -> ` / `tag: ` prefixes.
    /// - `%at`: author date as Unix seconds.
    static func parseCommits(output: String) -> [CommitNode] {
        // Split by RS then drop the leading empty chunk (output starts with RS).
        let records = output.split(separator: "\u{1E}", omittingEmptySubsequences: true)
        var nodes: [CommitNode] = []
        nodes.reserveCapacity(records.count)
        for record in records {
            let fields = record.split(separator: "\u{00}", maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count == 7 else { continue }
            let sha = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count >= 7 else { continue }
            let parents = String(fields[1])
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            let authorName = String(fields[2])
            let authorEmail = String(fields[3])
            let ts = TimeInterval(String(fields[4])) ?? 0
            let refs = parseRefNames(String(fields[5]))
            // Subject may include a trailing newline before the next RS.
            let subject = String(fields[6]).trimmingCharacters(in: .newlines)

            nodes.append(CommitNode(
                sha: sha,
                parents: parents,
                authorName: authorName,
                authorEmail: authorEmail,
                timestamp: ts,
                subject: subject,
                refs: refs,
                // Lane assignment is a second pass so parent positions are
                // known when each row is placed. See assignLanes(...).
                laneIndex: 0,
                parentLanes: [],
                passThroughLanes: []
            ))
        }
        return assignLanes(commits: nodes)
    }

    /// Decorates from `%D` look like:
    ///   `HEAD -> main, origin/main, tag: v1.0, feature-x`
    /// Empty strings (no decorates) are handled by early-return.
    static func parseRefNames(_ decorate: String) -> [GitRef] {
        let trimmed = decorate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [GitRef] = []
        for part in trimmed.split(separator: ",") {
            var token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if token.hasPrefix("HEAD -> ") {
                token.removeFirst("HEAD -> ".count)
                // HEAD is synthesized separately; the local branch after
                // `HEAD -> ` is what the user is on.
                out.append(GitRef(name: "HEAD", kind: .head))
                out.append(GitRef(name: token, kind: .localBranch))
            } else if token == "HEAD" {
                out.append(GitRef(name: "HEAD", kind: .head))
            } else if token.hasPrefix("tag: ") {
                token.removeFirst("tag: ".count)
                out.append(GitRef(name: token, kind: .tag))
            } else if token.contains("/") {
                // `origin/main` and similar remote-tracking refs.
                out.append(GitRef(name: token, kind: .remoteBranch))
            } else {
                out.append(GitRef(name: token, kind: .localBranch))
            }
        }
        return out
    }

    // MARK: Lane Assignment (Task 1.6)

    /// Assigns each commit a lane index for the graph column.
    ///
    /// Algorithm (single-pass, top-to-bottom, topo-order input):
    /// - Maintain `reservedLanes`: sha -> lane index a future row expects at that lane.
    /// - For each commit row:
    ///   - If this sha is reserved, use that lane. Else pick the lowest free lane.
    ///   - Remove the reservation for this sha (consumed).
    ///   - For its parents:
    ///     - First parent inherits the commit's lane (keeps the trunk straight).
    ///     - Other parents (merge) get a newly-allocated lane, unless the parent
    ///       is already reserved by a later commit at some lane — in which case
    ///       we reuse that lane and record it as the merge connection.
    ///   - Record `parentLanes` so the renderer can draw connectors.
    static func assignLanes(commits: [CommitNode]) -> [CommitNode] {
        guard !commits.isEmpty else { return commits }
        var reservations: [String: Int] = [:]
        var laneBusy: [Bool] = [] // laneBusy[i] == true means lane i is currently occupied by some reservation
        var result: [CommitNode] = []
        result.reserveCapacity(commits.count)

        func allocateLane() -> Int {
            if let idx = laneBusy.firstIndex(of: false) {
                laneBusy[idx] = true
                return idx
            }
            laneBusy.append(true)
            return laneBusy.count - 1
        }

        for commit in commits {
            let lane: Int
            if let reserved = reservations.removeValue(forKey: commit.sha) {
                lane = reserved
                // The reservation lane stays busy until we re-reserve below.
            } else {
                lane = allocateLane()
            }

            // Snapshot the lanes that are currently reserved *before* we add
            // this commit's parent reservations. Any lane in this set that is
            // not the commit's own lane represents an unrelated branch that
            // passes through this row — the renderer draws a vertical segment
            // in each of those lanes.
            let passThroughLanes = Set(reservations.values)
                .subtracting([lane])
                .sorted()

            var parentLanes: [Int] = []
            for (index, parentSha) in commit.parents.enumerated() {
                if let existing = reservations[parentSha] {
                    // Parent already reserved by an earlier-seen descendant.
                    // This is the merge-to-existing-branch case — draw a line
                    // to that lane without allocating a new one.
                    parentLanes.append(existing)
                    continue
                }
                let parentLane: Int
                if index == 0 {
                    // First parent inherits current lane; lane stays busy.
                    parentLane = lane
                } else {
                    parentLane = allocateLane()
                }
                reservations[parentSha] = parentLane
                parentLanes.append(parentLane)
            }

            // If this commit has no parents (root) OR its first parent went to
            // a different lane (never happens by construction), free our lane.
            if commit.parents.isEmpty {
                // No lane inheritance — free it so future siblings can reuse.
                if lane < laneBusy.count { laneBusy[lane] = false }
            } else if !parentLanes.contains(lane) {
                // The current lane is no longer reserved by any parent.
                if lane < laneBusy.count { laneBusy[lane] = false }
            }

            result.append(CommitNode(
                sha: commit.sha,
                parents: commit.parents,
                authorName: commit.authorName,
                authorEmail: commit.authorEmail,
                timestamp: commit.timestamp,
                subject: commit.subject,
                refs: commit.refs,
                laneIndex: lane,
                parentLanes: parentLanes,
                passThroughLanes: passThroughLanes
            ))
        }
        return result
    }

    // MARK: Process Runners
    // Pattern mirrors `GitStatusProvider.runGit` / `runSSH` in
    // `FileExplorerStore.swift`. Kept private so callers use the typed
    // `fetch*` API above.

    private static func runGit(in directory: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
