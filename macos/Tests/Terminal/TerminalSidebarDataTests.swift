import Foundation
import Testing
@testable import Ghostty

struct TerminalSidebarDataTests {
    @Test(arguments: [
        ("feature/pr sidebar", "feature-pr-sidebar"),
        ("bugfix///nested", "bugfix-nested"),
        (" release candidate ", "release-candidate"),
        ("...", "worktree"),
    ])
    func sanitizedPathComponent(branchName: String, expected: String) {
        #expect(TerminalRepositoryService.sanitizedPathComponent(from: branchName) == expected)
    }

    @Test(arguments: [
        ("origin/feature/sidebar", "feature/sidebar"),
        ("upstream/main", "main"),
        ("local-branch", "local-branch"),
    ])
    func shortBranchName(reference: String, expected: String) {
        #expect(TerminalRepositoryService.shortBranchName(for: reference) == expected)
    }

    @Test
    func defaultWorktreePathUsesRepoNameAndSanitizedBranch() {
        let path = TerminalRepositoryService.defaultWorktreePath(
            repositoryName: "/tmp/ghostty",
            branchName: "feature/pr sidebar"
        )

        #expect(path.hasSuffix("/.workspace/ghostty/feature-pr-sidebar"))
    }

    @Test
    func parseNumstatFilesParsesTextAndBinaryEntries() {
        let files = TerminalRepositoryService.parseNumstatFiles(
            "12\t4\tSources/App.swift\n-\t-\tAssets/logo.png\n",
            badges: ["Staged"]
        )

        #expect(files.count == 2)
        #expect(files[0].path == "Sources/App.swift")
        #expect(files[0].additions == 12)
        #expect(files[0].deletions == 4)
        #expect(!files[0].isBinary)
        #expect(files[1].path == "Assets/logo.png")
        #expect(files[1].isBinary)
        #expect(files[1].badges == ["Staged"])
    }

    @Test
    func pullRequestCheckPrioritySortsFailuresBeforePendingAndPass() {
        let checks = [
            TerminalPullRequestCheck(
                id: "pass",
                name: "pass",
                link: nil,
                bucket: "pass",
                state: "SUCCESS",
                workflow: nil,
                description: nil,
                startedAt: nil,
                completedAt: nil
            ),
            TerminalPullRequestCheck(
                id: "pending",
                name: "pending",
                link: nil,
                bucket: "pending",
                state: "IN_PROGRESS",
                workflow: nil,
                description: nil,
                startedAt: nil,
                completedAt: nil
            ),
            TerminalPullRequestCheck(
                id: "fail",
                name: "fail",
                link: nil,
                bucket: "fail",
                state: "FAILURE",
                workflow: nil,
                description: nil,
                startedAt: nil,
                completedAt: nil
            ),
        ]

        let ordered = checks.sorted { $0.sortPriority < $1.sortPriority }.map(\.bucket)
        #expect(ordered == ["fail", "pending", "pass"])
    }

    @Test
    func executableResolverFindsCommandInProvidedSearchPaths() throws {
        try withTemporaryDirectorySync { temporaryRoot in
            let binDirectory = temporaryRoot.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

            let executable = binDirectory.appendingPathComponent("gh")
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: executable.path
            )

            let resolved = TerminalExecutableResolver.resolveFromSearchPaths(
                command: "gh",
                searchPaths: [binDirectory.path]
            )
            #expect(resolved == executable.path)
        }
    }

    @Test
    func listBranchesSeparatesLocalAndRemoteBranches() async throws {
        try await withTemporaryDirectory { temporaryRoot in
            let remoteRepository = temporaryRoot.appendingPathComponent("remote.git", isDirectory: true)
            try await createBareRepository(at: remoteRepository)

            let sourceRepository = temporaryRoot.appendingPathComponent("source", isDirectory: true)
            try await createRepository(at: sourceRepository, localBranches: ["feature/sidebar"])
            _ = try await git(["remote", "add", "origin", remoteRepository.path], in: sourceRepository.path)
            _ = try await git(["push", "-u", "origin", "main"], in: sourceRepository.path)
            _ = try await git(["push", "-u", "origin", "feature/sidebar"], in: sourceRepository.path)

            let cloneRepository = temporaryRoot.appendingPathComponent("clone", isDirectory: true)
            _ = try await git(["clone", remoteRepository.path, cloneRepository.path])

            let service = TerminalRepositoryService(
                workspaceRoot: temporaryRoot.appendingPathComponent("workspace", isDirectory: true)
            )
            let catalog = try await service.listBranches(in: cloneRepository.path)

            #expect(catalog.local.map(\.reference) == ["main"])
            #expect(catalog.remote.contains(where: { $0.reference == "origin/main" }))
            #expect(catalog.remote.contains(where: { $0.reference == "origin/feature/sidebar" }))
            #expect(!catalog.remote.contains(where: { $0.reference == "origin/HEAD" }))
        }
    }

    @Test
    func createOrReuseWorktreeRejectsExistingPathFromDifferentRepository() async throws {
        try await withTemporaryDirectory { temporaryRoot in
            let workspaceRoot = temporaryRoot.appendingPathComponent("workspace", isDirectory: true)
            let firstRepository = temporaryRoot
                .appendingPathComponent("first", isDirectory: true)
                .appendingPathComponent("shared-name", isDirectory: true)
            let secondRepository = temporaryRoot
                .appendingPathComponent("second", isDirectory: true)
                .appendingPathComponent("shared-name", isDirectory: true)

            try await createRepository(at: firstRepository, localBranches: ["feature/sidebar"])
            try await createRepository(at: secondRepository, localBranches: ["feature/sidebar"])

            let branch = TerminalBranchDescriptor(
                kind: .local,
                reference: "feature/sidebar",
                name: "feature/sidebar"
            )
            let service = TerminalRepositoryService(workspaceRoot: workspaceRoot)

            let firstResult = try await service.createOrReuseWorktree(
                request: TerminalWorktreeRequest(
                    repositoryRoot: firstRepository.path,
                    selection: .existing(branch)
                )
            )
            #expect(!firstResult.reusedExistingPath)

            let reusedResult = try await service.createOrReuseWorktree(
                request: TerminalWorktreeRequest(
                    repositoryRoot: firstRepository.path,
                    selection: .existing(branch)
                )
            )
            #expect(reusedResult.reusedExistingPath)
            #expect(reusedResult.workingDirectory == firstResult.workingDirectory)

            do {
                _ = try await service.createOrReuseWorktree(
                    request: TerminalWorktreeRequest(
                        repositoryRoot: secondRepository.path,
                        selection: .existing(branch)
                    )
                )
                Issue.record("Expected worktree reuse for a different repository to fail.")
            } catch let error as TerminalRepositoryServiceError {
                guard case let .invalidExistingWorktree(existingPath) = error else {
                    Issue.record("Unexpected error: \(error.localizedDescription)")
                    return
                }

                #expect(existingPath == firstResult.workingDirectory)
            }
        }
    }

    @Test
    func fetchRepositoryChangesFallsBackToLocalMainAndMergesWorkingTreeState() async throws {
        try await withTemporaryDirectory { temporaryRoot in
            let repository = temporaryRoot.appendingPathComponent("changes", isDirectory: true)
            try await createRepository(at: repository)

            _ = try await git(["checkout", "-b", "feature/sidebar"], in: repository.path)

            let readmeURL = repository.appendingPathComponent("README.md")
            try "ghostty\ncommitted line\n".write(to: readmeURL, atomically: true, encoding: .utf8)
            _ = try await git(["add", "README.md"], in: repository.path)
            _ = try await git(["commit", "-m", "Committed sidebar changes"], in: repository.path)

            try "ghostty\ncommitted line\nstaged line\n".write(to: readmeURL, atomically: true, encoding: .utf8)
            _ = try await git(["add", "README.md"], in: repository.path)
            try "ghostty\ncommitted line\nstaged line\nunstaged line\n".write(to: readmeURL, atomically: true, encoding: .utf8)

            let notesURL = repository.appendingPathComponent("notes.txt")
            try "untracked\n".write(to: notesURL, atomically: true, encoding: .utf8)

            let service = TerminalRepositoryService(
                workspaceRoot: temporaryRoot.appendingPathComponent("workspace", isDirectory: true)
            )
            let context = try await service.resolveContext(for: repository.path)
            let summary = try await service.fetchRepositoryChanges(for: context, preferredBaseBranch: nil)

            #expect(summary.baseBranchName == "main")
            #expect(summary.committed.files.contains(where: { $0.path == "README.md" }))
            #expect(summary.uncommitted.files.contains(where: { $0.path == "README.md" }))
            #expect(summary.uncommitted.files.contains(where: { $0.path == "notes.txt" }))

            let readme = try #require(summary.uncommitted.files.first(where: { $0.path == "README.md" }))
            #expect(readme.badges.contains("Staged"))
            #expect(readme.badges.contains("Unstaged"))

            let notes = try #require(summary.uncommitted.files.first(where: { $0.path == "notes.txt" }))
            #expect(notes.badges == ["Untracked"])
        }
    }
}

private func withTemporaryDirectory<T>(
    _ body: (URL) async throws -> T
) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    return try await body(directory)
}

private func withTemporaryDirectorySync<T>(
    _ body: (URL) throws -> T
) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    return try body(directory)
}

@discardableResult
private func createBareRepository(at url: URL) async throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    _ = try await git(["-c", "init.defaultBranch=main", "init", "--bare", url.path])
    return url
}

@discardableResult
private func createRepository(
    at url: URL,
    localBranches: [String] = []
) async throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    _ = try await git(["-c", "init.defaultBranch=main", "init"], in: url.path)
    _ = try await git(["config", "user.name", "Ghostty Tests"], in: url.path)
    _ = try await git(["config", "user.email", "ghostty-tests@example.com"], in: url.path)

    let readmeURL = url.appendingPathComponent("README.md")
    try "ghostty\n".write(to: readmeURL, atomically: true, encoding: .utf8)
    _ = try await git(["add", "README.md"], in: url.path)
    _ = try await git(["commit", "-m", "Initial commit"], in: url.path)

    for branch in localBranches {
        _ = try await git(["branch", branch], in: url.path)
    }

    return url
}

private func git(
    _ arguments: [String],
    in currentDirectory: String? = nil
) async throws -> TerminalCommandOutput {
    try await TerminalProcessRunner.runCommand("git", arguments: arguments, currentDirectory: currentDirectory)
}
