import Foundation

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message) }
}

private func requireRefusal(repo: String, checkout: Checkout, approvedFolders: [String] = []) throws {
    do {
        try Inventory.remove(repo: repo, checkout: checkout, approvedGeneratedFolders: approvedFolders)
    } catch {
        try require(FileManager.default.fileExists(atPath: checkout.path), "Removed a protected checkout at \(checkout.path)")
        return
    }
    throw Failure("Accepted deletion of a protected checkout at \(checkout.path)")
}

@main
private struct Verify {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data(("Verification failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func run() throws {
        try require(confirmationName("ok\n\u{202E}txt") == #"ok\u{A}\u{202E}txt"# &&
                    confirmationName(#"ok\u{A}"#) != confirmationName("ok\n"),
                    "Confirmation hid or misrepresented filename characters")
        let repo = CommandLine.arguments[1]
        let checkouts = try Inventory.list(repo: repo)
        let expected = Set(["clean branch", "dirty", "ignored", "locked", "unmerged", "stale", "detached", "generated", "concealed", "merging", "nested", "squashed", "partial"])
        let byName = Dictionary(grouping: checkouts) { URL(fileURLWithPath: $0.path).lastPathComponent }
        try require(Set(byName.keys) == expected && checkouts.count == expected.count, "Wrong linked checkout inventory")

        func checkout(_ name: String) throws -> Checkout {
            guard let item = byName[name]?.first else { throw Failure("Missing checkout \(name)") }
            return item
        }

        let previews = Inventory.recentBranchWork(repo: repo, trees: checkouts)
        let changedHead = try checkout("partial").head, cleanHead = try checkout("clean branch").head
        try require(previews[changedHead]?.contains("still unique") == true &&
                    previews[cleanHead]?.hasPrefix("No branch-only") == true, "Launch preview missing or attributed shared work to a branch")
        func evidence(_ tree: Checkout) throws -> ChangeEvidence {
            guard case let .changed(value, _) = try Inventory.checkChanges(repo: repo, checkout: tree, matching: nil)
            else { throw Failure("First run unexpectedly reused") }
            return value
        }
        let dirtyEvidence = try evidence(checkout("dirty"))
        try require(dirtyEvidence.hasBase && dirtyEvidence.stagedPatch.contains("+staged change") &&
                    dirtyEvidence.unstagedPatch.contains("+edited tracked file") &&
                    dirtyEvidence.untrackedNames.contains("untracked.txt"), "Missing working-copy change evidence")
        func signature(_ tree: Checkout, previous: String? = nil) throws -> String {
            guard case let .changed(_, fingerprint?) = try Inventory.checkChanges(repo: repo, checkout: tree, matching: previous)
            else { throw Failure("A changed checkout reused its earlier summary") }
            return fingerprint
        }
        func mustReuse(_ tree: Checkout, _ fingerprint: String) throws {
            guard case .reused = try Inventory.checkChanges(repo: repo, checkout: tree, matching: fingerprint)
            else { throw Failure("Unchanged checkout missed its summary cache") }
        }
        let dirty = try checkout("dirty")
        let initial = try signature(dirty)
        try mustReuse(dirty, initial)
        let tracked = URL(fileURLWithPath: dirty.path).appendingPathComponent("readme")
        try Data("another local edit".utf8).write(to: tracked)
        let changed = try signature(dirty, previous: initial)
        let untracked = URL(fileURLWithPath: dirty.path).appendingPathComponent("untracked.txt")
        try Data("different content".utf8).write(to: untracked)
        let edited = try signature(dirty, previous: changed)
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", dirty.path] + args
            try process.run(); process.waitUntilExit()
            try require(process.terminationStatus == 0, "Fixture Git operation failed")
        }
        try git(["add", "readme"])
        let staged = try signature(dirty, previous: edited)
        try git(["commit", "-qm", "Record a new task commit"])
        let advanced = try Inventory.list(repo: repo).first { $0.path == dirty.path }!
        _ = try signature(advanced, previous: staged)
        try git(["reset", "-q", "--soft", dirty.head])
        let localPayload = String(decoding: try JSONEncoder().encode(dirtyEvidence), as: UTF8.self)
        try require(!localPayload.contains("untracked content must stay out"), "Read an untracked file's contents")
        let branchEvidence = try evidence(checkout("partial"))
        try require(branchEvidence.branchPatch.contains("+extra change") && branchEvidence.commits.contains("still unique")
                    && !branchEvidence.branchPatch.contains("later main content"), "Included unrelated mainline changes")
        let unchanged = try evidence(checkout("clean branch"))
        try require(!unchanged.hasChanges && unchanged.hasBase, "Invented a change for an unchanged checkout")
        let unknown = Inspection(bytes: nil, blocker: nil, generatedFolders: []).measured(bytes: nil, reclaimableBytes: nil)
        try require(unknown.category == .uncertain, "Offered Clean with incomplete measurement")

        // The configured filter is harmless. The app must refuse a comparison that needs it.
        let attributes = URL(fileURLWithPath: dirty.path).appendingPathComponent(".gitattributes")
        try Data("readme filter=fixture\n".utf8).write(to: attributes)
        try git(["config", "filter.fixture.clean", "/usr/bin/cat"])
        try Data("change requiring normalization".utf8).write(to: tracked)
        var filterRefused = false
        do { _ = try evidence(dirty) } catch { filterRefused = true }
        try require(filterRefused, "Analysis used a configured external filter")
        try FileManager.default.removeItem(at: attributes)
        try git(["config", "--remove-section", "filter.fixture"])

        let categories: [String: CleanupCategory] = ["dirty": .modified, "ignored": .ignored, "locked": .locked,
                                                   "detached": .detached,
                                                   "concealed": .uncertain, "merging": .operation]
        for (name, category) in categories {
            let item = try checkout(name)
            let inspection = try Inventory.inspect(repo: repo, checkout: item)
            try require(inspection.category == category, "Misclassified \(name) eligible")
            try requireRefusal(repo: repo, checkout: item)
        }

        try git(["replace", "--graft", "main", "partial-integration"])
        try git(["merge-base", "--is-ancestor", "partial-integration", "main"])
        let rewritten = try Inventory.inspect(repo: repo, checkout: checkout("partial"))
        try require(rewritten.mergeEvidence.integrationUnproven, "Replacement history falsely proved integration")
        try git(["replace", "-d", "main"])

        let squashed = try checkout("squashed")
        let evidence = try Inventory.analysis(repo: repo, checkout: squashed)
        let facts = try JSONSerialization.jsonObject(with: Data(evidence.payload.utf8)) as? [String: Any]
        try require(evidence.verdict == "Can remove" && facts?["mergeProof"] as? String == "identical_full_tree_on_local_default_after_fork",
                    "Exact historical squash snapshot was not recognized")
        try require(facts?["commitsOutsideLocalDefault"] as? Int == 5, "Wrong squash history count")
        try require(!evidence.payload.contains(squashed.head) && !evidence.payload.contains(repo)
                    && !evidence.payload.contains("confidential-squash"), "Shared payload leaked local identifiers")
        let partial = try checkout("partial")
        try require(try Inventory.analysis(repo: repo, checkout: partial).verdict == "Can remove",
                    "Unique committed work on a retained branch should be eligible")
        try requireRefusal(repo: repo, checkout: partial) // Old approval did not cover unmerged work.
        let loose = URL(fileURLWithPath: partial.path).appendingPathComponent(".env")
        try Data("private fixture".utf8).write(to: loose)
        var refusedLateFile = false
        do { try Inventory.remove(repo: repo, checkout: partial, allowUnverifiedMerge: true) }
        catch { refusedLateFile = true }
        try require(refusedLateFile && FileManager.default.fileExists(atPath: loose.path), "Ignored file lost")
        try FileManager.default.removeItem(at: loose)
        try Inventory.remove(repo: repo, checkout: partial, allowUnverifiedMerge: true)
        let restored = partial.path + "-restored"
        try git(["worktree", "add", "-q", restored, partial.branch!])
        let reopened = try Inventory.list(repo: repo).first { $0.path == restored }
        let contents = try String(contentsOfFile: restored + "/secret-tracked-name", encoding: .utf8)
        try require(reopened?.head == partial.head && contents.contains("extra change"),
                    "Could not reopen the retained branch at its unique commit")
        let squashArtifacts = try Inventory.inspect(repo: repo, checkout: squashed).generatedFolders
        try require(squashArtifacts == [".yarn/cache", ".yarn/install-state.gz", "dist"], "Ignored artifact confirmation is incomplete")
        try requireRefusal(repo: repo, checkout: squashed)
        let privateFile = URL(fileURLWithPath: squashed.path).appendingPathComponent("private-untracked-file")
        try Data("dummy sensitive content".utf8).write(to: privateFile)
        let dirtySquash = try Inventory.analysis(repo: repo, checkout: squashed)
        try require(dirtySquash.verdict == "Keep" && !dirtySquash.payload.contains(privateFile.lastPathComponent)
                    && !dirtySquash.payload.contains("dummy"), "Squash proof overrode local files or disclosed their names")
        try requireRefusal(repo: repo, checkout: squashed, approvedFolders: squashArtifacts)
        try FileManager.default.removeItem(at: privateFile)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.currentDirectoryURL = URL(fileURLWithPath: squashed.path)
        sleeper.arguments = ["45"]
        try sleeper.run()
        do {
            defer { sleeper.terminate(); sleeper.waitUntilExit() }
            let active = try Inventory.analysis(repo: repo, checkout: squashed)
            try require(active.verdict == "Keep" && active.payload.contains("inUse") && !active.payload.contains("sleep"),
                        "Active process escaped protection or leaked its name")
            try requireRefusal(repo: repo, checkout: squashed, approvedFolders: squashArtifacts)
        }
        try Inventory.remove(repo: repo, checkout: squashed, approvedGeneratedFolders: squashArtifacts)

        let stale = try checkout("stale")
        try require(try Inventory.inspect(repo: repo, checkout: stale).reason == nil, "Expected clean starting state")
        try Data("new work".utf8).write(to: URL(fileURLWithPath: stale.path).appendingPathComponent("new work.txt"))
        try require(try Inventory.inspect(repo: repo, checkout: stale).category == .untracked, "Missed untracked file")
        try requireRefusal(repo: repo, checkout: stale)

        let nested = try checkout("nested")
        let nestedReview = try Inventory.inspect(repo: repo, checkout: nested)
        try require(nestedReview.reason?.contains("node_modules/.jobs/frontend") == true, "Missed nested linked checkout")
        try requireRefusal(repo: repo, checkout: nested, approvedFolders: ["node_modules"])

        let generated = try checkout("generated")
        let folders = try Inventory.inspect(repo: repo, checkout: generated).generatedFolders
        try require(folders == ["node_modules"], "Expected only node_modules in generated folder confirmation")
        try requireRefusal(repo: repo, checkout: generated)
        let secret = URL(fileURLWithPath: generated.path).appendingPathComponent(".env")
        try Data("secret".utf8).write(to: secret)
        try requireRefusal(repo: repo, checkout: generated, approvedFolders: folders)
        try require(try Data(contentsOf: secret) == Data("secret".utf8), "Lost ignored data after stale approval")
        try FileManager.default.removeItem(at: secret)
        let nestedRepo = URL(fileURLWithPath: generated.path).appendingPathComponent("node_modules/new-repo")
        let childRepo = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.copyItem(at: childRepo, to: nestedRepo)
        try requireRefusal(repo: repo, checkout: generated, approvedFolders: folders)
        try require(FileManager.default.fileExists(atPath: nestedRepo.appendingPathComponent(".git/HEAD").path),
                    "Lost nested repo created after inspection")
        try FileManager.default.removeItem(at: nestedRepo)
        let package = URL(fileURLWithPath: generated.path).appendingPathComponent("node_modules/a-package")
        if getuid() != 0 {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: package.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }
            try requireRefusal(repo: repo, checkout: generated, approvedFolders: folders)
        }
        try Inventory.remove(repo: repo, checkout: generated, approvedGeneratedFolders: folders)
        try require(!FileManager.default.fileExists(atPath: generated.path), "Approved generated directory remains")

        let clean = try checkout("clean branch")
        let inspection = try Inventory.inspect(repo: repo, checkout: clean)
        try require(inspection.reason == nil, "Blocked clean checkout: \(inspection.reason ?? "")")
        try require((inspection.bytes ?? 0) > 0, "No disk usage estimate for seeded checkout")
        try Inventory.remove(repo: repo, checkout: clean)
        try require(!FileManager.default.fileExists(atPath: clean.path), "Clean checkout still exists")
        let remaining = try Inventory.list(repo: repo)
        try require(remaining.count == checkouts.count - 3 && !remaining.contains(clean) && !remaining.contains(generated),
                    "Removed checkout remains registered")
    }
}
