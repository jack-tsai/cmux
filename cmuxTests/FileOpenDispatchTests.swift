import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Scenario coverage for `FileOpenDispatcher.decide`. Task 4.3 enumerates the
/// six spec scenarios plus the two symlink cases from task 4.8.
final class FileOpenDispatchTests: XCTestCase {

    // MARK: - Fixture helpers

    private func environment(
        isRemote: Bool = false,
        symlinks: [String: String] = [:],
        directories: Set<String> = [],
        existing: Set<String> = [],
        gitStatusByPath: [String: FileOpenDispatcher.GitStatus] = [:],
        workspaceDirectory: String = "/ws"
    ) -> FileOpenDispatcher.Environment {
        FileOpenDispatcher.Environment(
            isRemoteWorkspace: isRemote,
            symlinkTarget: { symlinks[$0] },
            isDirectory: { directories.contains($0) },
            pathExists: { existing.contains($0) || $0.hasSuffix(".exists") },
            gitStatus: { path, _ in gitStatusByPath[path] ?? .notARepo },
            workspaceDirectory: workspaceDirectory
        )
    }

    // MARK: - Scenarios

    func testDecide_markdownExtension_returnsMarkdown() {
        let env = environment(gitStatusByPath: ["/ws/README.md": .clean])
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/README.md", environment: env),
            .markdown(path: "/ws/README.md")
        )
    }

    func testDecide_markdownExtensionUppercase_returnsMarkdown() {
        let env = environment()
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/NOTES.MARKDOWN", environment: env),
            .markdown(path: "/ws/NOTES.MARKDOWN")
        )
    }

    func testDecide_cleanNonMarkdownFile_returnsPreview() {
        let env = environment(gitStatusByPath: ["/ws/a.swift": .clean])
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/a.swift", environment: env),
            .preview(path: "/ws/a.swift")
        )
    }

    func testDecide_modifiedNonMarkdownFile_returnsDiff() {
        let env = environment(gitStatusByPath: ["/ws/a.swift": .modified])
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/a.swift", environment: env),
            .diff(path: "/ws/a.swift")
        )
    }

    func testDecide_untrackedFile_returnsPreview() {
        let env = environment(gitStatusByPath: ["/ws/new.txt": .untracked])
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/new.txt", environment: env),
            .preview(path: "/ws/new.txt")
        )
    }

    func testDecide_pathOutsideGitRepo_returnsPreview() {
        let env = environment(gitStatusByPath: ["/ws/loose.txt": .notARepo])
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/loose.txt", environment: env),
            .preview(path: "/ws/loose.txt")
        )
    }

    func testDecide_markdownOutsideGitRepo_returnsMarkdown() {
        let env = environment(gitStatusByPath: ["/ws/loose.md": .notARepo])
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/loose.md", environment: env),
            .markdown(path: "/ws/loose.md")
        )
    }

    func testDecide_sshWorkspace_returnsUnsupported() {
        let env = environment(
            isRemote: true,
            gitStatusByPath: ["/ws/a.swift": .modified]
        )
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/a.swift", environment: env),
            .unsupported
        )
    }

    func testDecide_directoryRow_returnsUnsupported() {
        let env = environment(directories: ["/ws/src"])
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/src", environment: env),
            .unsupported
        )
    }

    // MARK: - Symlink handling (task 4.8)

    func testDecide_symlinkToMarkdown_resolvesTarget() {
        let env = environment(
            symlinks: ["/ws/link.md": "/ws/docs/real.md"],
            existing: ["/ws/docs/real.md"],
            gitStatusByPath: ["/ws/docs/real.md": .clean]
        )
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/link.md", environment: env),
            .markdown(path: "/ws/docs/real.md")
        )
    }

    func testDecide_brokenSymlink_returnsUnsupported() {
        let env = environment(
            symlinks: ["/ws/broken": "/ws/missing.txt"],
            existing: []
        )
        XCTAssertEqual(
            FileOpenDispatcher.decide(path: "/ws/broken", environment: env),
            .unsupported
        )
    }
}
