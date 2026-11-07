import Foundation

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@main
private enum BranchCleanupVerify {
    static func main() throws {
        let repo = CommandLine.arguments[1], remote = CommandLine.arguments[2], root = CommandLine.arguments[3]
        func require(_ ok: Bool, _ text: String) throws { if !ok { throw Failure(text) } }
        func git(_ args: [String], at directory: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory] + args
            try process.run()
            process.waitUntilExit()
            try require(process.terminationStatus == 0, "Fixture git failed: " + args.joined(separator: " "))
        }
        let report = try BranchCleanup.review(repo: repo)
        func candidate(_ name: String, _ state: BranchState) throws -> BranchCandidate {
            guard let row = report.rows.first(where: { $0.name == name }), row.state == state else {
                throw Failure("Incorrect state for " + name + ": " + String(describing: report.rows.first { $0.name == name }?.reason))
            }
            return row
        }
        func requireRefusal(_ row: BranchCandidate) throws {
            do { try BranchCleanup.remove(repo: repo, candidate: row) }
            catch { try git(["show-ref", "--verify", "--quiet", "refs/heads/" + row.name], at: repo); return }
            throw Failure("Deleted protected branch " + row.name)
        }
        try require(report.defaultBranch == "main", "Wrong default")
        for name in ["main", "present", "checked", "unmerged", "no-upstream", "collision", "advanced"] {
            try requireRefusal(candidate(name, .keep))
        }
        try requireRefusal(candidate("offline", .unknown))
        let renamed = try candidate("renamed", .suggested)
        try require(renamed.upstream == "refs/heads/remote-topic", "Used local rather than remote name")
        let restored = try candidate("recreated", .suggested)
        try git(["update-ref", "refs/heads/recreated", restored.tip], at: remote)
        try requireRefusal(restored)
        let moved = try candidate("moved", .suggested)
        try git(["branch", "-f", "moved", "unmerged"], at: repo)
        try requireRefusal(moved)
        let occupied = try candidate("occupancy", .suggested)
        try git(["worktree", "add", "-q", root + "/new checkout", "occupancy"], at: repo)
        try requireRefusal(occupied)
        let archive = try candidate("archive", .suggested)
        try git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/archive"], at: repo)
        try BranchCleanup.remove(repo: repo, candidate: archive)
        let final = try BranchCleanup.review(repo: repo)
        try require(!final.rows.contains { $0.name == "archive" }, "Branch still listed")
        try require(final.rows.count == report.rows.count - 1, "Changed other branches")
        try git(["show-ref", "--verify", "--quiet", "refs/heads/main"], at: repo)
        try git(["show-ref", "--verify", "--quiet", "refs/heads/recreated"], at: remote)
        print("Verified live upstream names, stale tracking refs, merged-only local deletion, unchanged-tip and checkout protection, offline handling, and preserved siblings.")
    }
}
