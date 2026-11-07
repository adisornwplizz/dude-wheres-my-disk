import Darwin
import Foundation

enum BranchState: Sendable { case suggested, keep, unknown }

struct BranchCandidate: Identifiable, Equatable, Sendable {
    let name: String
    let tip: String
    let remote: String?
    let upstream: String?
    let state: BranchState
    let reason: String
    fileprivate let remoteURL: String?
    var id: String { name }
}

struct BranchReport: Sendable {
    let rows: [BranchCandidate]
    let defaultBranch: String?
}

private struct BranchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum BranchCleanup {
    private struct Result {
        let status: Int32
        let output: Data

        func text() throws -> String {
            guard status == 0, let text = String(data: output, encoding: .utf8) else {
                throw BranchError("Git could not complete the local branch check.")
            }
            return text
        }
    }

    private struct Local {
        let name: String
        let tip: String
        let symbolic: Bool
        let remote: String?
        let merge: String?
        let trackingRef: String
        let unambiguous: Bool
    }

    private struct Advertisement {
        let url: String
        let branches: Set<String>
        let defaultRef: String?
    }

    // A pipe read must finish even when an SSH child is waiting on a remote host.
    private static func git(_ args: [String], in repo: String, transport: String? = nil,
                            hooks: URL? = nil, extra: [String: String] = [:]) throws -> Result {
        try Task.checkCancellation()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["--no-replace-objects", "-c", "core.hooksPath=" + (hooks?.path ?? "/dev/null"),
                          "-c", "core.fsmonitor=false", "-C", repo] + args
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["LC_ALL"] = "C"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_NO_LAZY_FETCH"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ALLOW_PROTOCOL"] = transport ?? ""
        env["GIT_ASKPASS"] = "/usr/bin/false"
        if transport != nil {
            // The remote query runs outside the reviewed repository, without its Git helpers or URL rewrites.
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=6 -o ConnectionAttempts=1"
        }
        proc.environment = env.merging(extra) { _, value in value }
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        let fd = pipe.fileHandleForReading.fileDescriptor
        defer { try? pipe.fileHandleForReading.close() }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            kill(proc.processIdentifier, SIGKILL)
            throw BranchError("Could not monitor the Git process.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + (transport == nil ? 20 : 12)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        var eof = false
        do {
            while !eof || proc.isRunning {
                if hooks == nil { try Task.checkCancellation() }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BranchError("Git timed out.") }
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard bytes.count + count <= 8_388_608 else { throw BranchError("The Git response exceeds the size limit.") }
                    bytes.append(contentsOf: buffer.prefix(count))
                } else {
                    if count == 0 { eof = true }
                    else if errno != EAGAIN && errno != EINTR { throw BranchError("Could not read Git output.") }
                    if !eof {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        _ = poll(&descriptor, 1, 100)
                    } else if proc.isRunning { Thread.sleep(forTimeInterval: 0.005) }
                }
            }
        } catch {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            throw error
        }
        return Result(status: proc.terminationStatus, output: bytes)
    }

    private static func localBranches(in repo: String) throws -> [Local] {
        let format = "%(refname)%00%(objectname)%00%(symref)%00%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream)"
        let refs = try git(["for-each-ref", "--format=" + format, "refs/heads"], in: repo).text()
        let config = try git(["config", "--null", "--get-regexp", #"^branch\..*\.(remote|merge)$"#], in: repo)
        var values: [String: [String]] = [:]
        if config.status != 1 {
            for field in try config.text().split(separator: "\0") {
                guard let split = field.firstIndex(of: "\n") else { throw BranchError("Unreadable branch configuration.") }
                values[String(field[..<split]), default: []].append(String(field[field.index(after: split)...]))
            }
        }
        return try refs.split(separator: "\n").map { record in
            let f = record.components(separatedBy: "\0")
            guard f.count == 6, f[0].hasPrefix("refs/heads/"), validOID(f[1]) else { throw BranchError("Unreadable branch registration.") }
            let name = String(f[0].dropFirst("refs/heads/".count))
            let remotes = values["branch." + name + ".remote"] ?? []
            let merges = values["branch." + name + ".merge"] ?? []
            return Local(name: name, tip: f[1], symbolic: !f[2].isEmpty,
                         remote: remotes.first, merge: merges.first, trackingRef: f[5],
                         unambiguous: remotes == [f[3]] && merges == [f[4]] && f[4].hasPrefix("refs/heads/"))
        }
    }

    private static func validOID(_ text: String) -> Bool {
        [40, 64].contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func advertisement(_ remote: String, in repo: String) throws -> Advertisement {
        let urls = try git(["remote", "get-url", "--all", "--", remote], in: repo).text().split(separator: "\n")
        guard urls.count == 1 else { throw BranchError("Ambiguous remote URL.") }
        let url = String(urls[0])
        let proto: String
        if url.hasPrefix("https://") { proto = "https" }
        else if url.hasPrefix("ssh://") || url.range(of: #"^[A-Za-z0-9_.]+@[A-Za-z0-9][A-Za-z0-9.-]*:[^:]"#, options: .regularExpression) != nil {
            proto = "ssh"
        } else if url.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: url + "/HEAD"),
                  FileManager.default.fileExists(atPath: url + "/objects") {
            proto = "file"
        } else { throw BranchError("Unsupported remote transport.") }
        guard !url.contains(where: { $0.isWhitespace || $0.isNewline }) || proto == "file" else {
            throw BranchError("Invalid remote URL.")
        }
        let response = try git(["-c", "credential.helper=osxkeychain", "-c", "http.followRedirects=false",
                                "ls-remote", "--symref", "--", url, "HEAD", "refs/heads/*"], in: "/", transport: proto)
        let records = try response.text().split(separator: "\n")
        var branches: Set<String> = []
        var defaultRef: String?
        for record in records {
            let fields = record.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw BranchError("Unreadable remote advertisement.") }
            if fields[1] == "HEAD", fields[0].hasPrefix("ref: refs/heads/") {
                defaultRef = String(fields[0].dropFirst(5))
            } else if validOID(String(fields[0])) && (fields[1] == "HEAD" || fields[1].hasPrefix("refs/heads/")) {
                if fields[1] != "HEAD" { branches.insert(String(fields[1])) }
            } else { throw BranchError("Unexpected remote advertisement.") }
        }
        return Advertisement(url: url, branches: branches, defaultRef: defaultRef)
    }

    static func review(repo: String) throws -> BranchReport {
        _ = try Inventory.list(repo: repo)
        let locals = try localBranches(in: repo)
        return try review(repo: repo, locals: locals)
    }

    private static func review(repo: String, locals: [Local]) throws -> BranchReport {
        var advertisements: [String: Advertisement] = [:]
        for remote in Set(locals.compactMap(\.remote)).sorted() where remote != "." {
            do { advertisements[remote] = try advertisement(remote, in: repo) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Each affected row reports that its remote could not be verified. */ }
        }
        let linked = try Inventory.list(repo: repo)
        var occupied = Set(linked.compactMap(\.branch))
        let current = try git(["symbolic-ref", "--quiet", "HEAD"], in: repo)
        if current.status != 1 {
            let ref = try current.text().trimmingCharacters(in: .newlines)
            guard ref.hasPrefix("refs/heads/") else { throw BranchError("Unexpected primary checkout.") }
            occupied.insert(String(ref.dropFirst(11)))
        }
        let base = try Inventory.mainline(repo)
        let localBase = base.map { String($0.dropFirst(11)) }
        var rows: [BranchCandidate] = []
        for branch in locals {
            let ad = branch.remote.flatMap { advertisements[$0] }
            let state: BranchState
            let reason: String
            if branch.name == localBase || ad?.defaultRef == "refs/heads/" + branch.name {
                (state, reason) = (.keep, "Default branch")
            } else if occupied.contains(branch.name) {
                (state, reason) = (.keep, "Checked out in a worktree")
            } else if branch.remote == nil && branch.merge == nil || branch.remote == "." {
                (state, reason) = (.keep, "No remote upstream configured")
            } else if branch.symbolic || !branch.unambiguous {
                (state, reason) = (.unknown, "Ambiguous branch or upstream configuration")
            } else if let ad, let upstream = branch.merge {
                if ad.branches.contains(upstream) {
                    (state, reason) = (.keep, "Upstream still exists")
                } else if let base, let localBase {
                    let merged = try git(["merge-base", "--is-ancestor", branch.tip, base], in: repo)
                    switch merged.status {
                    case 0:
                        // Git branch -d checks its cached upstream, or HEAD when that ref is gone.
                        let cached = try git(["show-ref", "--verify", "--quiet", branch.trackingRef], in: repo)
                        guard cached.status == 0 || cached.status == 1 else { throw BranchError("Could not resolve the local tracking ref.") }
                        let guardRef = cached.status == 0 ? branch.trackingRef : "HEAD"
                        let native = try git(["merge-base", "--is-ancestor", branch.tip, guardRef], in: repo)
                        if native.status == 0 {
                            (state, reason) = (.suggested, "Upstream absent and merged into " + localBase)
                        } else {
                            (state, reason) = (.keep, "Local tracking or HEAD history still protects this branch")
                        }
                    case 1: (state, reason) = (.keep, "Upstream absent with commits outside " + localBase)
                    default: (state, reason) = (.unknown, "Could not verify commit ancestry")
                    }
                } else { (state, reason) = (.unknown, "Could not identify the local default branch") }
            } else { (state, reason) = (.unknown, "Could not verify remote branch list") }
            rows.append(BranchCandidate(name: branch.name, tip: branch.tip, remote: branch.remote,
                                        upstream: branch.merge, state: state, reason: reason, remoteURL: ad?.url))
        }
        return BranchReport(rows: rows, defaultBranch: localBase)
    }

    static func remove(repo: String, candidate: BranchCandidate) throws {
        guard candidate.state == .suggested,
              let local = try localBranches(in: repo).first(where: { $0.name == candidate.name }), local.tip == candidate.tip else {
            throw BranchError("The branch changed. Check remote branches again.")
        }
        let checked = try review(repo: repo, locals: [local])
        guard let fresh = checked.rows.first, fresh == candidate, let base = checked.defaultBranch,
              let afterContact = try localBranches(in: repo).first(where: { $0.name == candidate.name }),
              afterContact.unambiguous, afterContact.tip == candidate.tip,
              afterContact.remote == candidate.remote, afterContact.merge == candidate.upstream else {
            throw BranchError("The upstream, checkout or branch state changed. Check remote branches again.")
        }

        // Native branch -d may omit the old OID in the transaction. Read the ref while
        // Git holds its lock so a branch moved since approval survives.
        let hooks = FileManager.default.temporaryDirectory.appendingPathComponent("dwmd-ref-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: hooks) }
        let hook = hooks.appendingPathComponent("reference-transaction")
        let script = """
        #!/bin/sh
        test "$1" = prepared || exit 0
        found=1
        while read -r old new ref; do
            if test "$ref" = "$DWMD_REF"; then
                tip=$(/usr/bin/git --no-replace-objects rev-parse --verify "$DWMD_REF") || exit 1
                test "$tip" = "$DWMD_TIP" || exit 1
                case "$new" in *[!0]*|'') exit 1;; esac
                /usr/bin/git --no-replace-objects merge-base --is-ancestor "$DWMD_TIP" "$DWMD_BASE" || exit 1
                found=0
            fi
        done
        exit "$found"
        """
        try Data(script.utf8).write(to: hook, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        let removed = try git(["branch", "-d", "--", candidate.name], in: repo, hooks: hooks,
                              extra: ["DWMD_REF": "refs/heads/" + candidate.name, "DWMD_TIP": candidate.tip, "DWMD_BASE": "refs/heads/" + base])
        guard removed.status == 0 else { throw BranchError("Git declined to delete the local branch. Review it again.") }
    }
}
