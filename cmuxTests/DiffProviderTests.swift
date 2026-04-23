import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Parser coverage for `DiffProvider`. Task 3.3: cover added, removed, mixed,
/// binary, no-newline-at-eof, empty output, multi-hunk, rename.
final class DiffProviderTests: XCTestCase {

    func testParse_emptyOutput_returnsEmptyTextDiff() {
        let diff = DiffProvider.parse(rawOutput: "", fallbackPath: "foo.swift")
        XCTAssertEqual(diff.kind, .text)
        XCTAssertEqual(diff.path, "foo.swift")
        XCTAssertTrue(diff.hunks.isEmpty)
        XCTAssertTrue(diff.isEmpty)
    }

    func testParse_purelyAddedBlock_surfacesAddedLinesOnly() {
        let raw = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,3 @@
        +alpha
        +beta
        +gamma
        """
        let diff = DiffProvider.parse(rawOutput: raw, fallbackPath: "new.txt")
        XCTAssertEqual(diff.kind, .text)
        XCTAssertEqual(diff.path, "new.txt")
        XCTAssertEqual(diff.hunks.count, 1)
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.kind == .added })
        XCTAssertEqual(lines.map(\.text), ["alpha", "beta", "gamma"])
    }

    func testParse_purelyRemovedBlock_surfacesRemovedLinesOnly() {
        let raw = """
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        """
        let diff = DiffProvider.parse(rawOutput: raw, fallbackPath: "old.txt")
        XCTAssertEqual(diff.hunks.count, 1)
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.removed, .removed])
        XCTAssertEqual(lines.map(\.text), ["one", "two"])
    }

    func testParse_mixedHunk_separatesKinds() {
        let raw = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         context
        -removed
        +added
        """
        let diff = DiffProvider.parse(rawOutput: raw, fallbackPath: "a.txt")
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].kind, .context)
        XCTAssertEqual(lines[0].text, "context")
        XCTAssertEqual(lines[1].kind, .removed)
        XCTAssertEqual(lines[1].text, "removed")
        XCTAssertEqual(lines[2].kind, .added)
        XCTAssertEqual(lines[2].text, "added")
    }

    func testParse_binaryMarker_returnsBinaryKind() {
        let raw = "Binary files a/logo.png and b/logo.png differ"
        let diff = DiffProvider.parse(rawOutput: raw, fallbackPath: "logo.png")
        XCTAssertEqual(diff.kind, .binary)
        XCTAssertTrue(diff.hunks.isEmpty)
    }

    func testParse_noNewlineAtEof_preservedAsOwnLine() {
        let raw = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -one
        +one!
        \\ No newline at end of file
        """
        let diff = DiffProvider.parse(rawOutput: raw, fallbackPath: "a.txt")
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[2].kind, .noNewlineAtEof)
    }

    func testParse_multipleHunks_emittedIndividually() {
        let raw = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         top
        -first
        +first!
        @@ -10,2 +10,2 @@
         middle
        -second
        +second!
        """
        let diff = DiffProvider.parse(rawOutput: raw, fallbackPath: "a.txt")
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertTrue(diff.hunks[0].header.hasPrefix("@@ -1,2"))
        XCTAssertTrue(diff.hunks[1].header.hasPrefix("@@ -10,2"))
    }

    func testParse_rename_surfacesAsDeletePlusAddBlocks() {
        // Task 3.13: we invoke git without `-M` so the fixture should look
        // like git's default "whole-file delete + whole-file add".
        let raw = """
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -hello
        -world
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let diff = DiffProvider.parse(rawOutput: raw, fallbackPath: "new.txt")
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertTrue(diff.hunks[0].lines.allSatisfy { $0.kind == .removed })
        XCTAssertTrue(diff.hunks[1].lines.allSatisfy { $0.kind == .added })
    }

    func testParse_blankContextLine_preservedAsBlankRow() {
        // Git strips the single leading space on empty context lines, so the
        // parser has to infer them from bare-empty lines between `+/-` entries.
        let raw = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         before

         after
        """
        let diff = DiffProvider.parse(rawOutput: raw, fallbackPath: "a.txt")
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[1].text, "")
    }
}
