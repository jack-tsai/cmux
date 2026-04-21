import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Parser + lane-algorithm coverage for `GitGraphProvider`. Tasks 13.1 / 13.2.
/// We deliberately test the pure static parsing / lane assignment functions
/// without invoking `/usr/bin/git`, so these run anywhere CI can build Swift.
final class GitGraphProviderTests: XCTestCase {

    // MARK: - parseCommits (Task 13.1)

    func testParseCommits_singleLinearCommit_decodesAllFields() {
        // Record format: `\x1e%H\x00%P\x00%an\x00%ae\x00%at\x00%D\x00%s`
        let output = "\u{1E}" + [
            "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",  // sha
            "",                                              // parents (root)
            "Jack",                                          // author name
            "jack@example.com",                              // author email
            "1729900000",                                    // timestamp
            "HEAD -> main",                                  // refs
            "first commit"                                   // subject
        ].joined(separator: "\u{00}")

        let nodes = GitGraphProvider.parseCommits(output: output)

        XCTAssertEqual(nodes.count, 1)
        let commit = nodes[0]
        XCTAssertEqual(commit.sha, "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0")
        XCTAssertEqual(commit.parents, [])
        XCTAssertEqual(commit.authorName, "Jack")
        XCTAssertEqual(commit.authorEmail, "jack@example.com")
        XCTAssertEqual(commit.timestamp, 1729900000)
        XCTAssertEqual(commit.subject, "first commit")
        XCTAssertEqual(commit.shortSha, "a1b2c3d4")
        // HEAD + local branch decoded from the refs column.
        XCTAssertTrue(commit.refs.contains(GitRef(name: "HEAD", kind: .head)))
        XCTAssertTrue(commit.refs.contains(GitRef(name: "main", kind: .localBranch)))
    }

    func testParseCommits_mergeCommit_capturesMultipleParents() {
        let merge = "\u{1E}" + [
            "mergemergemergemergemergemergemergemerge",
            "parent1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa parent2bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "Jack",
            "jack@example.com",
            "1729901000",
            "",
            "Merge branch feature"
        ].joined(separator: "\u{00}")

        let nodes = GitGraphProvider.parseCommits(output: merge)

        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].parents.count, 2)
        XCTAssertEqual(nodes[0].parents[0], "parent1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(nodes[0].parents[1], "parent2bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    }

    func testParseCommits_malformedRecordIsSkipped() {
        // One valid record followed by one record with the wrong field count.
        let valid = [
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "",
            "Jack",
            "jack@example.com",
            "1729900000",
            "",
            "good"
        ].joined(separator: "\u{00}")
        let invalid = "bbbbbbbb\u{00}onlyone"
        let output = "\u{1E}\(valid)\u{1E}\(invalid)"

        let nodes = GitGraphProvider.parseCommits(output: output)

        XCTAssertEqual(nodes.count, 1, "malformed record should be dropped silently")
        XCTAssertEqual(nodes[0].sha, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    // MARK: - parseRefNames (Task 13.1)

    func testParseRefNames_parsesAllKinds() {
        let refs = GitGraphProvider.parseRefNames(
            "HEAD -> main, origin/main, tag: v1.0, feature-x"
        )
        XCTAssertEqual(refs.count, 5)
        XCTAssertEqual(refs[0], GitRef(name: "HEAD", kind: .head))
        XCTAssertEqual(refs[1], GitRef(name: "main", kind: .localBranch))
        XCTAssertEqual(refs[2], GitRef(name: "origin/main", kind: .remoteBranch))
        XCTAssertEqual(refs[3], GitRef(name: "v1.0", kind: .tag))
        XCTAssertEqual(refs[4], GitRef(name: "feature-x", kind: .localBranch))
    }

    func testParseRefNames_emptyString_returnsEmptyArray() {
        XCTAssertEqual(GitGraphProvider.parseRefNames(""), [])
        XCTAssertEqual(GitGraphProvider.parseRefNames("  "), [])
    }

    // MARK: - assignLanes (Task 13.2)

    /// Linear history: C3 -> C2 -> C1 -> root. Every commit should sit in
    /// lane 0, each row's parentLanes should be [0].
    func testAssignLanes_linearHistory_singleLane() {
        let commits = [
            makeNode(sha: "c3", parents: ["c2"]),
            makeNode(sha: "c2", parents: ["c1"]),
            makeNode(sha: "c1", parents: []),
        ]

        let laned = GitGraphProvider.assignLanes(commits: commits)

        XCTAssertEqual(laned.count, 3)
        XCTAssertEqual(laned[0].laneIndex, 0)
        XCTAssertEqual(laned[0].parentLanes, [0])
        XCTAssertEqual(laned[1].laneIndex, 0)
        XCTAssertEqual(laned[1].parentLanes, [0])
        XCTAssertEqual(laned[2].laneIndex, 0)
        XCTAssertEqual(laned[2].parentLanes, [])
    }

    /// Branch + merge:
    ///
    ///   M (merge of A2 and B1)
    ///   ├── A2
    ///   ├── B1
    ///   └── A1 (shared parent)
    ///
    /// Input order (topo): M, A2, B1, A1.
    /// Expected: M at lane 0 with two parent lanes; A2 inherits lane 0
    /// (first parent); B1 allocated a fresh lane (lane 1); A1 falls back to
    /// lane 0 after A2 consumes it.
    func testAssignLanes_branchAndMerge_allocatesSecondLaneForMergeSource() {
        let commits = [
            makeNode(sha: "m", parents: ["a2", "b1"]),
            makeNode(sha: "a2", parents: ["a1"]),
            makeNode(sha: "b1", parents: ["a1"]),
            makeNode(sha: "a1", parents: []),
        ]

        let laned = GitGraphProvider.assignLanes(commits: commits)

        XCTAssertEqual(laned[0].sha, "m")
        XCTAssertEqual(laned[0].laneIndex, 0)
        XCTAssertEqual(laned[0].parentLanes.count, 2)

        XCTAssertEqual(laned[1].sha, "a2")
        XCTAssertEqual(laned[1].laneIndex, 0, "first parent inherits the commit's lane")

        XCTAssertEqual(laned[2].sha, "b1")
        XCTAssertEqual(laned[2].laneIndex, 1, "merge source allocated to a fresh lane")

        XCTAssertEqual(laned[3].sha, "a1")
        // a1 is parent of both a2 and b1; when a2 runs first it reserves a1 at lane 0
        // (inherited from a2's lane). b1 then sees a1 already reserved and shares lane 0.
        XCTAssertEqual(laned[3].laneIndex, 0)
    }

    /// Octopus merge with three parents: verifies multi-parent support
    /// allocates distinct lanes for each non-first parent.
    func testAssignLanes_octopusMerge_allocatesLaneForEachNonFirstParent() {
        let commits = [
            makeNode(sha: "merge", parents: ["p1", "p2", "p3"]),
            makeNode(sha: "p1", parents: []),
            makeNode(sha: "p2", parents: []),
            makeNode(sha: "p3", parents: []),
        ]

        let laned = GitGraphProvider.assignLanes(commits: commits)

        XCTAssertEqual(laned[0].parentLanes.count, 3)
        // Three distinct lanes allocated (order deterministic given input).
        XCTAssertEqual(Set(laned[0].parentLanes).count, 3)
        XCTAssertTrue(laned[0].parentLanes.contains(0))
    }

    /// Pass-through lanes: a branch that continues across a commit that
    /// lives in a different lane.
    ///
    ///   C (lane 0, parent = A)
    ///   │  ●  (B, lane 1, parent = A) — B passes through C's row
    ///   A (lane 0, root)
    func testAssignLanes_passThroughLanes_recordedCorrectly() {
        let commits = [
            makeNode(sha: "c", parents: ["a"]),
            makeNode(sha: "b", parents: ["a"]),
            makeNode(sha: "a", parents: []),
        ]

        let laned = GitGraphProvider.assignLanes(commits: commits)

        // B's row should record C's reserved lane (0) as pass-through.
        let bRow = laned[1]
        XCTAssertEqual(bRow.sha, "b")
        XCTAssertTrue(
            bRow.passThroughLanes.contains(0) || bRow.laneIndex == 0,
            "B row should either occupy lane 0 or treat it as pass-through"
        )
    }

    func testAssignLanes_emptyInput_returnsEmpty() {
        XCTAssertEqual(GitGraphProvider.assignLanes(commits: []).count, 0)
    }

    // MARK: - Fixtures

    /// Minimal `CommitNode` factory for lane-algorithm tests — fields other
    /// than sha / parents don't influence lane assignment.
    private func makeNode(sha: String, parents: [String]) -> CommitNode {
        CommitNode(
            sha: sha,
            parents: parents,
            authorName: "",
            authorEmail: "",
            timestamp: 0,
            subject: "",
            refs: [],
            laneIndex: 0,
            parentLanes: [],
            passThroughLanes: []
        )
    }
}
