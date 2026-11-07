import Foundation

private struct FailedCheck: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@main
private struct ActivityVerify {
    static func main() throws {
        let fs = FileManager.default
        let root = fs.temporaryDirectory.appendingPathComponent("dwmd-activity-" + UUID().uuidString)
        let checkout = root.appendingPathComponent("service-extra")
        let working = checkout.appendingPathComponent("sub folder\nmore")
        let sibling = root.appendingPathComponent("service")
        let alias = root.appendingPathComponent("linked")
        try fs.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? fs.removeItem(at: root) }
        try fs.createDirectory(at: sibling, withIntermediateDirectories: true)
        try fs.createSymbolicLink(at: alias, withDestinationURL: checkout)

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.currentDirectoryURL = working
        try sleeper.run()
        defer {
            if sleeper.isRunning { sleeper.terminate(); sleeper.waitUntilExit() }
        }

        let previousDirectory = fs.currentDirectoryPath
        guard fs.changeCurrentDirectoryPath(sibling.path) else { throw FailedCheck("Cannot enter test directory") }
        defer { _ = fs.changeCurrentDirectoryPath(previousDirectory) }

        let active = WorktreeActivity.snapshot()
        guard active.isAvailable,
              active.names(for: checkout.path).contains("sleep"),
              active.names(for: alias.path).contains("sleep"),
              active.blockingReason(for: checkout.path)?.hasPrefix("In use by ") == true else {
            throw FailedCheck("Could not identify sleep in the nested working directory")
        }
        guard active.blockingReason(for: sibling.path) == nil else {
            throw FailedCheck("Scanner or sibling path with a common prefix was classified as active")
        }
        sleeper.terminate()
        sleeper.waitUntilExit()
        guard WorktreeActivity.snapshot().blockingReason(for: checkout.path) == nil else {
            throw FailedCheck("Exited process was still reported in a new snapshot")
        }
        print("Verified current-user process attribution, directory boundaries, alias resolution and resampling.")
    }
}
