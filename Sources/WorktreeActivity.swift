import Darwin
import Foundation

/// A point-in-time view of the current user's visible process working directories.
struct WorktreeActivity: Sendable {
    private struct Entry: Hashable, Sendable {
        let directory: String
        let name: String
    }

    private let entries: Set<Entry>
    let isAvailable: Bool

    static func snapshot() -> Self {
        let unavailable = Self(entries: [], isAvailable: false)
        let type = UInt32(PROC_UID_ONLY)
        let user = getuid()
        let estimate = proc_listpids(type, user, nil, 0)
        guard estimate > 0 else { return unavailable }

        let stride = MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: Int(estimate) / stride + 128)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(type, user, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, Int(bytes) < pids.count * stride else { return unavailable }

        var entries = Set<Entry>()
        let ownPID = getpid()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        for pid in pids.prefix(Int(bytes) / stride) where pid > 0 && pid != ownPID {
            var vnode = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize else { continue }
            let directory = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) {
                String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
            }
            guard let directory, directory.hasPrefix("/") else { continue }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            let name = count > 0 ? String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self) : "PID \(pid)"
            entries.insert(Entry(directory: directory, name: name))
        }
        return Self(entries: entries, isAvailable: !entries.isEmpty)
    }

    func names(for path: String) -> [String] {
        guard let real = realpath(path, nil) else { return [] }
        defer { free(real) }
        guard let root = String(validatingUTF8: real) else { return [] }
        let prefix = root == "/" ? "/" : root + "/"
        return Set(entries.lazy.filter {
            $0.directory == root || $0.directory.hasPrefix(prefix)
        }.map(\.name)).sorted()
    }

    func blockingReason(for path: String) -> String? {
        guard isAvailable else { return "Process activity unavailable" }
        let users = names(for: path)
        return users.isEmpty ? nil : "In use by " + users.joined(separator: ", ")
    }
}
