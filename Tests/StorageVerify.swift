import Foundation
import Darwin

private struct CheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func check(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(message) }
}

@main
private struct StorageVerify {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("repo with spaces")
        let child = root.appendingPathComponent("frontend")
        let other = base.appendingPathComponent("external")
        let store = base.appendingPathComponent("store")
        for directory in [child, other, store] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let owned = root.appendingPathComponent("owned")
        let shared = child.appendingPathComponent("shared")
        let both = other.appendingPathComponent("same inode")
        let outside = store.appendingPathComponent("package")
        let dependency = other.appendingPathComponent("package")
        let link = root.appendingPathComponent("store-link")
        // Write real, non-sparse data so a missing hard-link contribution is observable.
        for url in [owned, shared, outside] {
            let bytes = (0..<65536).map { UInt8(truncatingIfNeeded: $0) }
            try Data(bytes).write(to: url)
        }
        try fm.linkItem(at: shared, to: both)
        try fm.linkItem(at: outside, to: dependency)
        try fm.createSymbolicLink(at: link, withDestinationURL: store)
        let alias = root.path + "/."
        let paths = [child.path, root.path, other.path, alias, root.path]
        let measured = try WorkspaceStorage.measure(paths: paths)
        func blocks(_ files: [URL]) throws -> Int64 {
            try files.reduce(0) { total, file in
                var st = stat()
                try check(lstat(file.path, &st) == 0, "fixture stat failed")
                return total + st.st_blocks * 512
            }
        }
        let rootBytes = try blocks([root, child, owned, shared, link])
        let childBytes = try blocks([child, shared])
        let externalBytes = try blocks([other, both, dependency])
        let unionBytes = try blocks([root, child, other, owned, shared, link, outside])
        try check(measured.incomplete.isEmpty, "Complete fixture marked partial")
        try check(measured.total == unionBytes, "Nested or hard-linked data was double counted")
        try check(measured.sizes[root.path] == rootBytes && measured.sizes[alias] == rootBytes, "Root alias totals")
        try check(measured.sizes[child.path] == childBytes && measured.sizes[other.path] == externalBytes, "Inclusive checkout sizes")
        try check(measured.allocated(paths: [child.path, other.path]) == childBytes + externalBytes - (try blocks([shared])), "Shared hard link counted twice")
        try check(measured.reclaimable(paths: [child.path]) == (try blocks([child])), "A single candidate would not free the shared file")
        try check(measured.reclaimable(paths: [other.path, child.path]) == (try blocks([other, child, shared])), "Union reclaim estimate")
        try check(measured.reclaimable(paths: paths) == measured.total - (try blocks([outside])), "External package link inflated reclaimable bytes")

        let unreadable = child.appendingPathComponent("private")
        try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { _ = chmod(unreadable.path, 0o700) }
        let absent = base.appendingPathComponent("missing").path
        let partial = try WorkspaceStorage.measure(paths: [root.path, child.path, other.path, absent])
        if getuid() != 0 {
            try check(partial.incomplete == [root.path, child.path, absent], "Partial child not propagated or unrelated root flagged")
            try check(partial.sizes[root.path] == nil && partial.sizes[child.path] == nil, "Incomplete sizes advertised as complete")
        }
        try check(partial.sizes[other.path] == externalBytes && partial.sizes[absent] == nil, "Missing or independent folder")
        print("Verified physical storage unions, per-repository sizes, hard-link reclamation and partial coverage.")
    }
}
