import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Task 4.9: verify the value-type identity dedup relies on when
/// `openOrFocusDiff(mode:)` / `openOrFocusFilePreview(filePath:)` look up an
/// existing tab. The Workspace-side dedup logic hashes on these same
/// identities, so preserving `DiffMode` equality semantics is load-bearing.
final class WorkspaceTabDedupTests: XCTestCase {

    func testDiffMode_sameWorkingCopyPath_areEqual() {
        let a = DiffMode.workingCopyVsHead(path: "/ws/a.swift")
        let b = DiffMode.workingCopyVsHead(path: "/ws/a.swift")
        XCTAssertEqual(a, b)
    }

    func testDiffMode_differentPath_areNotEqual() {
        let a = DiffMode.workingCopyVsHead(path: "/ws/a.swift")
        let b = DiffMode.workingCopyVsHead(path: "/ws/b.swift")
        XCTAssertNotEqual(a, b)
    }

    func testDiffMode_workingCopyVsCommit_areDistinctIdentities() {
        // A preview tab for path.swift and a diff tab for path.swift must
        // live in different dedup buckets — opening a diff while a preview is
        // already open should NOT land on the same tab.
        let preview = DiffMode.workingCopyVsHead(path: "/ws/a.swift")
        let commit = DiffMode.commitVsParent(sha: "abc123", path: "/ws/a.swift")
        XCTAssertNotEqual(preview, commit)
    }

    func testDiffMode_commitVsParent_differentSha_notEqual() {
        let lhs = DiffMode.commitVsParent(sha: "abc123", path: "a.swift")
        let rhs = DiffMode.commitVsParent(sha: "def456", path: "a.swift")
        XCTAssertNotEqual(lhs, rhs)
    }

    func testDiffMode_hashable_canBeUsedAsDictionaryKey() {
        var seen: [DiffMode: Int] = [:]
        let a = DiffMode.workingCopyVsHead(path: "/ws/a.swift")
        seen[a] = 1
        XCTAssertEqual(seen[DiffMode.workingCopyVsHead(path: "/ws/a.swift")], 1)
        XCTAssertNil(seen[DiffMode.workingCopyVsHead(path: "/ws/b.swift")])
    }
}
