import Darwin
import Foundation

enum WorkspaceStorage {
    fileprivate struct LinkGroup: Hashable {
        let owners: Set<Int>
        let allLinksSeen: Bool
    }

    struct Measurement: Sendable {
        let total: Int64
        /// A partial or missing path is omitted here and named in incomplete.
        let sizes: [String: Int64]
        let incomplete: Set<String>
        private let regions: [String: Set<Int>]
        private let ordinary: [Int64]
        private let linked: [LinkGroup: Int64]

        fileprivate init(regions: [String: Set<Int>], incomplete: Set<String>,
                         ordinary: [Int64], linked: [LinkGroup: Int64]) {
            self.regions = regions
            self.incomplete = incomplete
            self.ordinary = ordinary
            self.linked = linked
            total = ordinary.reduce(0, +) + linked.values.reduce(0, +)
            sizes = regions.filter { !incomplete.contains($0.key) }.mapValues { owners in
                owners.reduce(Int64(0)) { $0 + ordinary[$1] } +
                    linked.reduce(Int64(0)) { $0 + ($1.key.owners.isDisjoint(with: owners) ? 0 : $1.value) }
            }
        }

        /// Returns measured blocks in the union; check incomplete before presenting it as a complete total.
        func allocated(paths: [String]) -> Int64 {
            let owners = paths.reduce(into: Set<Int>()) { $0.formUnion(regions[$1] ?? []) }
            return owners.reduce(Int64(0)) { $0 + ordinary[$1] } +
                linked.reduce(Int64(0)) { $0 + ($1.key.owners.isDisjoint(with: owners) ? 0 : $1.value) }
        }

        /// Files with any directory entry outside the chosen checkouts cannot be freed by deleting them.
        func reclaimable(paths: [String]) -> Int64 {
            let owners = paths.filter { !incomplete.contains($0) }.reduce(into: Set<Int>()) {
                $0.formUnion(regions[$1] ?? [])
            }
            return owners.reduce(Int64(0)) { $0 + ordinary[$1] } + linked.reduce(Int64(0)) {
                $0 + ($1.key.allLinksSeen && $1.key.owners.isSubset(of: owners) ? $1.value : 0)
            }
        }
    }

    private struct Inode: Hashable {
        let device: dev_t
        let number: ino_t

        init(_ info: stat) {
            device = info.st_dev
            number = info.st_ino
        }
    }

    private struct Links {
        let allocated: Int64
        let expected: Int
        var seen = 0
        var owners: Set<Int> = []
        var consistent = true

        mutating func observe(owner: Int, info: stat) {
            seen += 1
            owners.insert(owner)
            if allocated != Int64(info.st_blocks) * 512 || expected != Int(info.st_nlink) {
                consistent = false
            }
        }
    }

    static func measure(paths: [String]) throws -> Measurement {
        var resolved: [String: String] = [:]
        var rootIDs: [String: Inode] = [:]
        var incomplete: Set<String> = []
        for path in Set(paths) {
            var info = stat()
            guard path.hasPrefix("/"), lstat(path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, let buffer = realpath(path, nil) else {
                incomplete.insert(path)
                continue
            }
            defer { free(buffer) }
            if let physical = String(validatingUTF8: buffer) {
                resolved[path] = physical
                rootIDs[physical] = Inode(info)
            } else {
                incomplete.insert(path)
            }
        }

        let roots = Set(resolved.values).sorted()
        var ordinary = Array(repeating: Int64(0), count: roots.count)
        var links: [Inode: Links] = [:]
        var failed: Set<Int> = []
        var descendants: [String: Set<Int>] = [:]
        for (owner, root) in roots.enumerated() {
            try Task.checkCancellation()
            let prefix = root == "/" ? "/" : root + "/"
            let children = roots.indices.filter { roots[$0] != root && roots[$0].hasPrefix(prefix) }
            descendants[root] = Set(children + [owner])
            let boundaries = Set(children.compactMap { rootIDs[roots[$0]] })
            let complete = try walk(root, expected: rootIDs[root]!, excluding: boundaries) { info in
                let bytes = Int64(info.st_blocks) * 512
                if info.st_mode & S_IFMT == S_IFDIR || info.st_nlink <= 1 {
                    ordinary[owner] += bytes
                } else {
                    let inode = Inode(info)
                    let initial = Links(allocated: bytes, expected: Int(info.st_nlink))
                    links[inode, default: initial].observe(owner: owner, info: info)
                }
            }
            if !complete { failed.insert(owner) }
        }
        let regions = resolved.mapValues { descendants[$0]! }
        for (path, coverage) in regions where !coverage.isDisjoint(with: failed) {
            incomplete.insert(path)
        }
        var grouped: [LinkGroup: Int64] = [:]
        for file in links.values {
            let group = LinkGroup(owners: file.owners, allLinksSeen: file.consistent && file.seen == file.expected)
            grouped[group, default: 0] += file.allocated
        }
        return Measurement(regions: regions, incomplete: incomplete, ordinary: ordinary, linked: grouped)
    }

    /// Each named subtree owns its own walk. Parents omit these branches to avoid walking the same files twice.
    private static func walk(_ root: String, expected: Inode, excluding boundaries: Set<Inode>,
                             visit: (stat) -> Void) throws -> Bool {
        guard let path = strdup(root) else { throw POSIXError(.ENOMEM) }
        defer { free(path) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let tree = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return false }
        defer { fts_close(tree) }
        var complete = true
        var visited = 0
        while true {
            errno = 0
            guard let node = fts_read(tree) else { return complete && errno == 0 }
            visited += 1
            if visited.isMultiple(of: 512) { try Task.checkCancellation() }
            let entry = node.pointee
            switch Int32(entry.fts_info) {
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let info = entry.fts_statp?.pointee else {
                    complete = false
                    continue
                }
                if entry.fts_level == 0 {
                    guard Int32(entry.fts_info) == FTS_D, Inode(info) == expected else { return false }
                }
                if Int32(entry.fts_info) == FTS_D && !boundaries.isEmpty &&
                    boundaries.contains(Inode(info)) {
                    guard fts_set(tree, node, FTS_SKIP) == 0 else { return false }
                    continue
                }
                if info.st_dev != expected.device {
                    complete = false
                    continue
                }
                visit(info)
            case FTS_DNR, FTS_ERR, FTS_NS, FTS_DC:
                complete = false
            default:
                break
            }
        }
    }
}
