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
        let repo = CommandLine.arguments[1]
        let checkouts = try Inventory.list(repo: repo)
        let expected = Set(["clean branch", "dirty", "ignored", "locked", "unmerged", "stale", "detached", "generated", "concealed", "merging", "nested", "squashed", "partial"])
        let byName = Dictionary(grouping: checkouts) { URL(fileURLWithPath: $0.path).lastPathComponent }
        try require(Set(byName.keys) == expected && checkouts.count == expected.count, "Wrong linked checkout inventory")

        func checkout(_ name: String) throws -> Checkout {
            guard let item = byName[name]?.first else { throw Failure("Missing checkout \(name)") }
            return item
        }

        let dirtyEvidence = try Inventory.changeEvidence(repo: repo, checkout: checkout("dirty"))
        try require(dirtyEvidence.hasBase && dirtyEvidence.stagedPatch.contains("+staged change") &&
                    dirtyEvidence.unstagedPatch.contains("+edited tracked file") &&
                    dirtyEvidence.untrackedNames.contains("untracked.txt"), "Missing working-copy change evidence")
        let localPayload = String(decoding: try JSONEncoder().encode(dirtyEvidence), as: UTF8.self)
        try require(!localPayload.contains("untracked content must stay out"), "Read an untracked file's contents")
        let branchEvidence = try Inventory.changeEvidence(repo: repo, checkout: checkout("partial"))
        try require(branchEvidence.branchPatch.contains("+extra change") && branchEvidence.commits.contains("still unique")
                    && !branchEvidence.branchPatch.contains("later main content"), "Included unrelated mainline changes")
        let unchanged = try Inventory.changeEvidence(repo: repo, checkout: checkout("clean branch"))
        try require(!unchanged.hasChanges && unchanged.hasBase, "Invented a change for an unchanged checkout")
        let unknown = Inspection(bytes: nil, blocker: nil, generatedFolders: []).measured(bytes: nil)
        try require(unknown.category == .uncertain, "Offered Clean with incomplete measurement")

        let categories: [String: CleanupCategory] = ["dirty": .modified, "ignored": .ignored, "locked": .locked,
                                                   "unmerged": .unmerged, "detached": .detached,
                                                   "concealed": .uncertain, "merging": .operation]
        for (name, category) in categories {
            let item = try checkout(name)
            let inspection = try Inventory.inspect(repo: repo, checkout: item)
            try require(inspection.category == category, "Misclassified \(name) eligible")
            try requireRefusal(repo: repo, checkout: item)
        }

        let squashed = try checkout("squashed")
        let evidence = try Inventory.analysis(repo: repo, checkout: squashed)
        let facts = try JSONSerialization.jsonObject(with: Data(evidence.payload.utf8)) as? [String: Any]
        try require(evidence.verdict == "Can remove" && facts?["mergeProof"] as? String == "identical_full_tree_on_local_default_after_fork",
                    "Exact historical squash snapshot was not recognized")
        try require(facts?["commitsOutsideLocalDefault"] as? Int == 5, "Wrong squash history count")
        try require(!evidence.payload.contains(squashed.head) && !evidence.payload.contains(repo)
                    && !evidence.payload.contains("confidential-squash"), "Shared payload leaked local identifiers")
        let partial = try checkout("partial")
        try require(try Inventory.analysis(repo: repo, checkout: partial).verdict == "Review required",
                    "Partial integration must stay blocked")
        try requireRefusal(repo: repo, checkout: partial)
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
