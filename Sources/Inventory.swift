import Foundation
import Darwin

struct Checkout: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let branch: String?
    let head: String
    let locked: Bool
    let missing: Bool
}

enum CleanupCategory: String, CaseIterable, Hashable, Sendable {
    case cleanable, inUse, unmerged, detached, modified, untracked, ignored, nested
    case locked, primaryBranch, operation, missing, uncertain

    var assessmentVerdict: String {
        switch self {
        case .cleanable: return "Can remove"
        case .uncertain, .unmerged, .detached, .missing: return "Review required"
        default: return "Keep"
        }
    }

    var title: String {
        switch self {
        case .cleanable: return "Cleanable"
        case .inUse: return "In use"
        case .unmerged: return "Unmerged commits"
        case .detached: return "Detached HEAD"
        case .modified: return "Uncommitted changes"
        case .untracked: return "Untracked files"
        case .ignored: return "Ignored files"
        case .nested: return "Nested checkout"
        case .locked: return "Locked worktree"
        case .primaryBranch: return "Default branch checkout"
        case .operation: return "Git operation in progress"
        case .missing: return "Missing checkout"
        case .uncertain: return "Needs inspection"
        }
    }

    var guidance: String {
        switch self {
        case .cleanable: return "Review the folder and its contents before confirming removal."
        case .inUse: return "Finish the session using this folder, then rescan."
        case .unmerged: return "Compare the branch with the local default branch and review its outstanding commits."
        case .detached: return "Check which branch contains HEAD and keep any commits you need on a branch."
        case .modified: return "Review the staged and unstaged changes with git status."
        case .untracked: return "Review the new files and save any work you need to keep."
        case .ignored: return "Back up any local configuration or other ignored files you want to keep."
        case .nested: return "Review the checkout inside this folder first."
        case .locked: return "Check the lock reason with git worktree list --verbose."
        case .primaryBranch: return "Keep the checkout that holds the default branch."
        case .operation: return "Finish the Git operation in this checkout, then rescan."
        case .missing: return "Check whether the volume or checkout folder is available."
        case .uncertain: return "Review the reported error and rescan once the checkout can be verified."
        }
    }
}

struct CleanupBlocker: Error, Sendable {
    let category: CleanupCategory
    let detail: String

    init(_ category: CleanupCategory, _ detail: String) {
        self.category = category
        self.detail = detail
    }
}

enum MergeEvidence: Sendable {
    case unchecked
    case ancestor(base: String)
    case matchingTree(base: String, checkpoint: String, outsideCommits: Int)
    case unproven(base: String, outsideCommits: Int)

    var code: String {
        switch self {
        case .unchecked: return "not_checked"
        case .ancestor: return "ancestor_of_local_default"
        case .matchingTree: return "identical_full_tree_on_local_default_after_fork"
        case .unproven: return "integration_unproven"
        }
    }

    var explanation: String? {
        switch self {
        case .unchecked: return nil
        case let .ancestor(base): return "The local default branch (\(base)) contains this commit."
        case let .matchingTree(base, checkpoint, count):
            return "The final tracked snapshot of all \(count) divergent commits exactly matches commit \(checkpoint.prefix(12)) in the history of local \(base). This also recognizes a squash merge."
        case let .unproven(base, count):
            return "\(count) commits are outside local \(base). Could not prove integration from ancestry or an exact tracked snapshot in the last 512 first-parent commits after the fork."
        }
    }

    var outsideCommits: Int? {
        switch self {
        case .unchecked: return nil
        case .ancestor: return 0
        case let .matchingTree(_, _, count), let .unproven(_, count): return count
        }
    }
}

struct Inspection: Sendable {
    let bytes: Int64?
    let blocker: CleanupBlocker?
    let generatedFolders: [String]
    var mergeEvidence: MergeEvidence = .unchecked
    var reason: String? { blocker?.detail }
    var category: CleanupCategory { blocker?.category ?? .cleanable }

    func measured(bytes: Int64?) -> Inspection {
        let sizeBlocker = bytes == nil ? CleanupBlocker(.uncertain, "Could not measure the whole checkout") : nil
        return Inspection(bytes: bytes, blocker: blocker ?? sizeBlocker, generatedFolders: generatedFolders,
                          mergeEvidence: mergeEvidence)
    }
}

struct CleanupEvidence: Sendable {
    let verdict: String
    let localExplanation: String
    let payload: String

    fileprivate init(_ inspection: Inspection) throws {
        struct SharedFacts: Encodable {
            let verdict: String
            let firstBlocker: String?
            let mergeProof: String
            let commitsOutsideLocalDefault: Int?
            let generatedItemsRequiringApproval: Int
            let branchKeptOnRemoval: Bool
            let scope: String
        }
        verdict = inspection.category.assessmentVerdict
        var lines: [String] = []
        if let history = inspection.mergeEvidence.explanation { lines.append(history) }
        if let blocker = inspection.blocker {
            lines += [blocker.detail, blocker.category.guidance]
        } else {
            lines.append("Local checks passed for activity, repository identity, Git state, nested checkouts and local files. Removal keeps the branch.")
            if !inspection.generatedFolders.isEmpty {
                lines.append("Removal requires approval for all contents of these ignored items: " + inspection.generatedFolders.joined(separator: ", "))
            }
        }
        localExplanation = lines.joined(separator: "\n")
        let facts = SharedFacts(verdict: verdict, firstBlocker: inspection.blocker?.category.rawValue,
                                mergeProof: inspection.mergeEvidence.code,
                                commitsOutsideLocalDefault: inspection.mergeEvidence.outsideCommits,
                                generatedItemsRequiringApproval: inspection.generatedFolders.count,
                                branchKeptOnRemoval: true, scope: "local_git_refs_and_visible_process_working_directories")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        payload = String(decoding: try encoder.encode(facts), as: UTF8.self)
    }
}

struct ChangeEvidence: Encodable {
    var hasBase = false
    var commits = ""
    var branchFiles = ""
    var branchPatch = ""
    var stagedFiles = ""
    var stagedPatch = ""
    var unstagedFiles = ""
    var unstagedPatch = ""
    var untrackedNames = ""

    var hasChanges: Bool {
        [commits, branchFiles, stagedFiles, unstagedFiles, untrackedNames].contains { !$0.isEmpty }
    }

    var gitSummary: String {
        var lines: [String] = []
        if let subject = commits.split(separator: "\n").first {
            lines.append("Latest branch commit · " + String(subject.prefix(160)))
        }
        for (label, sample) in [("Branch files", branchFiles), ("Staged", stagedFiles),
                                ("Unstaged", unstagedFiles), ("Untracked", untrackedNames)] where !sample.isEmpty {
            let names = sample.split(separator: "\n").prefix(2).map {
                String(($0.split(separator: "\t").last ?? $0).prefix(120))
            }
            lines.append(label + " · " + names.joined(separator: ", "))
        }
        if !hasBase { lines.append("Branch comparison unavailable.") }
        return lines.isEmpty ? "No branch-only or uncommitted changes found." : lines.joined(separator: "\n")
    }
}

private struct InventoryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct Output {
    let status: Int32
    let data: Data

    func checked() throws -> Data {
        guard status == 0 else {
            let detail = String(decoding: data.prefix(2048), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InventoryError(detail.isEmpty ? "Git could not complete the operation." : detail)
        }
        return data
    }

    func line() throws -> String {
        var bytes = try checked()
        if bytes.last == 10 { bytes.removeLast() }
        guard let line = String(data: bytes, encoding: .utf8) else {
            throw InventoryError("This Git path cannot be represented as text.")
        }
        return line
    }
}

enum Inventory {
    private static func run(_ executable: String, _ arguments: [String], readTimeout: TimeInterval? = 120, captureLimit: Int? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ALLOW_PROTOCOL"] = ""
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let reader = pipe.fileHandleForReading
        defer { try? reader.close() }
        let data: Data
        if let readTimeout {
            do {
                data = try readInspection(reader, timeout: readTimeout, captureLimit: captureLimit)
            } catch {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw error
            }
        } else {
            data = reader.readDataToEndOfFile()
        }
        process.waitUntilExit()
        return Output(status: process.terminationStatus, data: data)
    }

    private static func readInspection(_ reader: FileHandle, timeout: TimeInterval, captureLimit: Int?) throws -> Data {
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + timeout
        var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 16384)
        var output = Data()
        while true {
            try Task.checkCancellation()
            guard clock.systemUptime < deadline else {
                throw InventoryError("Timed out reading this checkout. Check folder access and analyze again.")
            }
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw InventoryError("Could not read the local inspection result.") }
            let count = read(reader.fileDescriptor, &buffer, buffer.count)
            if count == 0 { return output }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw InventoryError("Could not read the local inspection result.") }
            let kept = captureLimit.map { min(count, $0 - output.count) } ?? count
            output.append(buffer, count: kept)
        }
    }

    private static func git(_ directory: String, _ arguments: [String], readTimeout: TimeInterval? = 120, captureLimit: Int? = nil) throws -> Output {
        try run("/usr/bin/git", [
            "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false", "-C", directory
        ] + arguments, readTimeout: readTimeout, captureLimit: captureLimit)
    }

    private static func canonical(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw InventoryError("Cannot resolve the filesystem path: " + path)
        }
        defer { free(resolved) }
        guard let text = String(validatingUTF8: resolved) else {
            throw InventoryError("This filesystem path cannot be represented as text.")
        }
        return text
    }

    static func list(repo: String) throws -> [Checkout] {
        guard repo.hasPrefix("/") else { throw InventoryError("Choose a repository folder.") }
        let expectedRoot = try git(repo, ["rev-parse", "--show-toplevel"]).line()
        guard try canonical(expectedRoot) == canonical(repo) else {
            throw InventoryError("Choose the root of the main checkout.")
        }

        let bytes = try git(repo, ["worktree", "list", "--porcelain", "-z"]).checked()
        guard let records = String(data: bytes, encoding: .utf8) else {
            throw InventoryError("This repository contains a non-UTF-8 worktree path.")
        }
        var result: [Checkout] = []
        for record in records.components(separatedBy: "\0\0") where !record.isEmpty {
            let fields = record.components(separatedBy: "\0")
            guard let first = fields.first, first.hasPrefix("worktree /"),
                  let head = fields.first(where: { $0.hasPrefix("HEAD ") }) else {
                throw InventoryError("Could not read the worktree list.")
            }
            let branch = fields.first { $0.hasPrefix("branch refs/heads/") }
            result.append(Checkout(
                path: String(first.dropFirst("worktree ".count)),
                branch: branch.map { String($0.dropFirst("branch refs/heads/".count)) },
                head: String(head.dropFirst(5)),
                locked: fields.contains { $0 == "locked" || $0.hasPrefix("locked ") },
                missing: fields.contains { $0 == "prunable" || $0.hasPrefix("prunable ") }
            ))
        }
        guard let primary = result.first, try canonical(primary.path) == canonical(repo) else {
            throw InventoryError("Choose this repository's main checkout, not a linked worktree.")
        }
        return Array(result.dropFirst())
    }

    private static func validate(_ repo: String, _ checkout: Checkout) throws {
        guard try list(repo: repo).contains(checkout) else {
            throw InventoryError("The worktree registration has changed. Refresh the repository.")
        }
    }

    private static func verifyDirectory(_ repo: String, _ checkout: Checkout) throws {
        let url = URL(fileURLWithPath: checkout.path)
        let gitFile = url.appendingPathComponent(".git")
        guard try gitFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try canonical(gitFile.path) == canonical(checkout.path) + "/.git",
              try canonical(checkout.path) == checkout.path,
              try canonical(checkout.path) != canonical(repo) else {
            throw InventoryError("The selected path is no longer a linked checkout.")
        }
        let registeredAdmin = try git(repo, ["rev-parse", "--absolute-git-dir"], readTimeout: 8).line()
        let checkoutAdmin = try git(checkout.path, ["rev-parse", "--absolute-git-dir"], readTimeout: 8).line()
        let parent = URL(fileURLWithPath: try canonical(checkoutAdmin)).deletingLastPathComponent().path
        let root = try git(checkout.path, ["rev-parse", "--show-toplevel"]).line()
        let common = try git(checkout.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).line()
        let pointer = URL(fileURLWithPath: checkoutAdmin).appendingPathComponent("gitdir")
        let backlink = try String(contentsOf: pointer, encoding: .utf8)
        let backlinkPath = backlink.hasSuffix("\n") ? String(backlink.dropLast()) : backlink
        let adminURL = URL(fileURLWithPath: checkoutAdmin, isDirectory: true)
        let linkedFile = URL(fileURLWithPath: backlinkPath, relativeTo: adminURL).absoluteURL.path
        guard try canonical(root) == canonical(checkout.path), try canonical(common) == canonical(registeredAdmin),
              try parent == canonical(registeredAdmin) + "/worktrees",
              try canonical(linkedFile) == canonical(gitFile.path) else {
            throw InventoryError("The checkout and repository registration do not match.")
        }
    }

    static func mainline(_ repo: String) throws -> String? {
        let remote = try git(repo, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])
        if remote.status == 0 {
            let name = try remote.line()
            guard name.hasPrefix("refs/remotes/origin/") else { return nil }
            let local = "refs/heads/" + String(name.dropFirst("refs/remotes/origin/".count))
            return try git(repo, ["show-ref", "--verify", "--quiet", local]).status == 0 ? local : nil
        }
        let names = try ["refs/heads/main", "refs/heads/master"].filter {
            try git(repo, ["show-ref", "--verify", "--quiet", $0]).status == 0
        }
        return names.count == 1 ? names[0] : nil
    }

    /// Only the on-device change-summary pipeline consumes these samples.
    static func changeEvidence(repo: String, checkout: Checkout) throws -> ChangeEvidence {
        try validate(repo, checkout)
        try verifyDirectory(repo, checkout)
        let path = checkout.path
        let head = try git(path, ["rev-parse", "--verify", "HEAD"]).line()
        guard head == checkout.head else { throw InventoryError("Checkout changed. Analyze again.") }

        func sample(_ arguments: [String], bytes: Int) throws -> String {
            let data = try git(path, arguments, readTimeout: 20, captureLimit: bytes + 1).checked()
            let text = String(decoding: data.prefix(bytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return data.count > bytes ? text + "\n[…sample truncated…]" : text
        }

        let diff = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=all", "--no-renames"]
        let patch = diff + ["--unified=1"]
        var evidence = ChangeEvidence()
        if let base = try mainline(repo) {
            let result = try git(path, ["merge-base", base, head])
            if result.status == 0 {
                let fork = try result.line()
                evidence.hasBase = true
                if fork != head {
                    evidence.commits = try sample(["log", "--no-merges", "--no-notes", "--no-show-signature", "--format=%s",
                                                   "-12", fork + ".." + head, "--"], bytes: 1800)
                    evidence.branchFiles = try sample(diff + ["--name-status", fork, head, "--"], bytes: 1300)
                    evidence.branchPatch = try sample(patch + [fork, head, "--"], bytes: 4800)
                }
            } else if result.status != 1 { _ = try result.checked() }
        }
        evidence.stagedFiles = try sample(diff + ["--cached", "--name-status", head, "--"], bytes: 900)
        evidence.unstagedFiles = try sample(diff + ["--name-status", "--"], bytes: 900)
        if !evidence.stagedFiles.isEmpty {
            evidence.stagedPatch = try sample(patch + ["--cached", head, "--"], bytes: 2400)
        }
        if !evidence.unstagedFiles.isEmpty {
            evidence.unstagedPatch = try sample(patch + ["--"], bytes: 2400)
        }
        evidence.untrackedNames = try sample(["ls-files", "--others", "--exclude-standard", "--directory", "--"], bytes: 700)
        guard try git(path, ["rev-parse", "--verify", "HEAD"]).line() == head else {
            throw InventoryError("Checkout changed. Analyze again.")
        }
        return evidence
    }

    private static func history(_ repo: String, _ checkout: Checkout) throws -> Result<MergeEvidence, CleanupBlocker> {
        if checkout.locked { return .failure(CleanupBlocker(.locked, "Locked worktree")) }
        guard let branch = checkout.branch else { return .failure(CleanupBlocker(.detached, "Detached HEAD")) }
        guard let base = try mainline(repo) else { return .failure(CleanupBlocker(.uncertain, "Cannot identify the local default branch")) }
        guard base != "refs/heads/" + branch else { return .failure(CleanupBlocker(.primaryBranch, "Contains the default branch")) }
        let admin = try git(checkout.path, ["rev-parse", "--absolute-git-dir"], readTimeout: 8).line()
        let operations: Set<String> = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_START",
                                       "rebase-apply", "rebase-merge", "sequencer", "index.lock", "HEAD.lock"]
        let entries = try FileManager.default.contentsOfDirectory(atPath: admin)
        if !operations.isDisjoint(with: entries) { return .failure(CleanupBlocker(.operation, "Git operation in progress")) }
        let head = try git(checkout.path, ["rev-parse", "--verify", "HEAD"]).line()
        let currentBranch = try git(checkout.path, ["symbolic-ref", "HEAD"]).line()
        guard head == checkout.head, currentBranch == "refs/heads/" + branch else {
            return .failure(CleanupBlocker(.uncertain, "Branch or commit changed. Refresh the repository."))
        }
        let baseTip = try git(repo, ["rev-parse", "--verify", base + "^{commit}"]).line()
        let baseName = String(base.dropFirst("refs/heads/".count))
        let ancestor = try git(repo, ["merge-base", "--is-ancestor", head, baseTip])
        if ancestor.status == 0 { return .success(.ancestor(base: baseName)) }
        if ancestor.status != 1 { _ = try ancestor.checked() }
        let countText = try git(repo, ["rev-list", "--count", baseTip + ".." + head]).line()
        guard let count = Int(countText), count > 0 else {
            throw InventoryError("Cannot count commits outside the local default branch.")
        }
        let unproven = MergeEvidence.unproven(base: baseName, outsideCommits: count)
        let bases = try git(repo, ["merge-base", "--all", head, baseTip])
        if bases.status == 1 { return .success(unproven) }
        let forks = try bases.line().split(separator: "\n")
        guard forks.count == 1 else { return .success(unproven) }
        let fork = String(forks[0])
        let headTree = try git(repo, ["rev-parse", head + "^{tree}"]).line()
        let forkTree = try git(repo, ["rev-parse", fork + "^{tree}"]).line()
        guard headTree != forkTree else { return .success(unproven) }

        // Search mainline snapshots, not commit subjects, patch fragments or files specified by the repository.
        let records = try git(repo, ["log", "--first-parent", "--max-count=512", "--no-patch", "--no-notes",
                                     "--no-show-signature", "--format=%H %T", fork + ".." + baseTip]).line()
        for line in records.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2, fields[1] == headTree else { continue }
            let checkpoint = String(fields[0])
            let afterFork = try git(repo, ["merge-base", "--is-ancestor", fork, checkpoint])
            if afterFork.status == 0 { return .success(.matchingTree(base: baseName, checkpoint: checkpoint, outsideCommits: count)) }
            if afterFork.status != 1 { _ = try afterFork.checked() }
        }
        return .success(unproven)
    }

    private static func workingContents(_ checkout: Checkout) throws -> Inspection {
        // Skip-worktree and assume-unchanged flags can conceal edits from git status.
        let tags = try git(checkout.path, ["ls-files", "-v", "-z"]).checked()
        if tags.split(separator: 0).contains(where: { $0.first != 72 }) {
            return Inspection(bytes: nil, blocker: CleanupBlocker(.uncertain, "Index contains files that need manual review"), generatedFolders: [])
        }

        // Git can collapse an entire ignored directory, hiding another checkout inside it.
        let nested = try run("/usr/bin/find", [
            "-P", checkout.path, "-mindepth", "2", "-iname", ".git", "-print0", "-quit"
        ])
        guard nested.status == 0 else {
            return Inspection(bytes: nil, blocker: CleanupBlocker(.uncertain, "Could not check every folder for nested repositories"), generatedFolders: [])
        }
        if !nested.data.isEmpty {
            let marker = String(decoding: nested.data.dropLast(), as: UTF8.self)
            let relative = String(marker.dropFirst(checkout.path.count + 1).dropLast("/.git".count))
            return Inspection(bytes: nil, blocker: CleanupBlocker(.nested, "Contains a nested repository at " + relative), generatedFolders: [])
        }
        let status = try git(checkout.path, [
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching",
            "--ignore-submodules=none"
        ]).checked()
        let generatedNames: Set<String> = ["node_modules", ".build", "DerivedData"]
        var folders: [String] = []
        for record in status.split(separator: 0) {
            guard record.count > 3, record.dropFirst(2).first == 0x20,
                  let path = String(data: record.dropFirst(3), encoding: .utf8) else {
                return Inspection(bytes: nil, blocker: CleanupBlocker(.uncertain, "Unreadable Git status entry"), generatedFolders: [])
            }
            let code = String(decoding: record.prefix(2), as: UTF8.self)
            if code == "!!", path.hasSuffix("/") {
                let relative = String(path.dropLast())
                if generatedNames.contains((relative as NSString).lastPathComponent) || ["dist", ".yarn/cache"].contains(relative) {
                    folders.append(relative)
                    continue
                }
            }
            if code == "!!", path == ".yarn/install-state.gz" {
                folders.append(path)
                continue
            }
            let blocker: CleanupBlocker
            switch code {
            case "!!": blocker = CleanupBlocker(.ignored, "Ignored path: " + path)
            case "??": blocker = CleanupBlocker(.untracked, "Untracked file: " + path)
            // A rename or copy is already a blocker; its second NUL-delimited path is never parsed as a status.
            default:
                let trackedCodes = " MTADRCU"
                if code != "  ", code.allSatisfy(trackedCodes.contains) {
                    blocker = CleanupBlocker(.modified, "Uncommitted change: " + path)
                } else {
                    blocker = CleanupBlocker(.uncertain, "Unrecognized Git status entry")
                }
            }
            return Inspection(bytes: nil, blocker: blocker, generatedFolders: [])
        }
        return Inspection(bytes: nil, blocker: nil, generatedFolders: folders.sorted())
    }

    private static func contents(_ repo: String, _ checkout: Checkout) throws -> Inspection {
        switch try history(repo, checkout) {
        case let .failure(blocker):
            return Inspection(bytes: nil, blocker: blocker, generatedFolders: [])
        case let .success(evidence):
            if case let .unproven(base, _) = evidence {
                return Inspection(bytes: nil, blocker: CleanupBlocker(.unmerged, "Commits outside " + base),
                                  generatedFolders: [], mergeEvidence: evidence)
            }
            var local = try workingContents(checkout)
            local.mergeEvidence = evidence
            return local
        }
    }

    static func analysis(repo: String, checkout: Checkout) throws -> CleanupEvidence {
        let inspection: Inspection
        do {
            inspection = try review(repo: repo, checkout: checkout, activity: .snapshot())
        } catch {
            inspection = Inspection(bytes: nil, blocker: CleanupBlocker(.uncertain, error.localizedDescription), generatedFolders: [])
        }
        return try CleanupEvidence(inspection)
    }

    static func review(repo: String, checkout: Checkout, activity: WorktreeActivity) throws -> Inspection {
        try validate(repo, checkout)
        if checkout.missing { return Inspection(bytes: nil, blocker: CleanupBlocker(.missing, "Worktree folder unavailable"), generatedFolders: []) }
        try verifyDirectory(repo, checkout)
        if let reason = activity.blockingReason(for: checkout.path) {
            let category: CleanupCategory = activity.isAvailable ? .inUse : .uncertain
            return Inspection(bytes: nil, blocker: CleanupBlocker(category, reason), generatedFolders: [])
        }
        return try contents(repo, checkout)
    }

    static func inspect(repo: String, checkout: Checkout) throws -> Inspection {
        let result = try review(repo: repo, checkout: checkout, activity: .snapshot())
        guard !checkout.missing else { return result }
        let usage = try WorkspaceStorage.measure(paths: [checkout.path])
        let bytes = usage.incomplete.contains(checkout.path) ? nil : usage.sizes[checkout.path]
        return result.measured(bytes: bytes)
    }

    static func remove(repo: String, checkout: Checkout, approvedGeneratedFolders: [String] = []) throws {
        try validate(repo, checkout)
        guard !checkout.missing else { throw InventoryError("Worktree folder unavailable") }
        try verifyDirectory(repo, checkout)
        let review = try contents(repo, checkout)
        if let reason = review.reason { throw InventoryError(reason) }
        guard review.generatedFolders == approvedGeneratedFolders.sorted() else {
            throw InventoryError("Build folders changed. Inspect and confirm this worktree again.")
        }
        if let reason = WorktreeActivity.snapshot().blockingReason(for: checkout.path) {
            throw InventoryError(reason)
        }
        _ = try git(repo, ["worktree", "remove", "--", checkout.path], readTimeout: nil).checked()
    }
}
