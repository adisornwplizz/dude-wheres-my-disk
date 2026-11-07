import Foundation

private struct CheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}

@main
private struct WorkspaceVerify {
    @MainActor
    private static func finish(_ library: Library) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while library.activity != nil {
            guard ContinuousClock.now < deadline else { throw CheckFailure("Workspace operation timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    static func main() async throws {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let group = try RepositoryChoices.discover(in: parent)
        let names = group.repositories.map(\.lastPathComponent)
        try check(names == [parent.lastPathComponent, "backend", "frontend"], "Root and immediate nested repositories: \(names)")
        let suite = "workspaces-verification." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure("No test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(defaults: defaults)

        let root = group.repositories[0]
        let backend = group.repositories[1]
        let frontend = group.repositories[2]
        library.addWorkspace(group, selected: [root, frontend])
        try await finish(library)
        try check(library.workspaces.count == 1 && library.selected?.projects.count == 2, "Expected one workspace and two approved members")
        try check(library.selected?.projects.allSatisfy { $0.id != backend.path && $0.inspections.isEmpty } == true, "Unexpected repository access")

        library.addWorkspace(group, selected: Set(group.repositories))
        try await finish(library)
        guard let workspace = library.selected else { throw CheckFailure("Expected selected workspace") }
        try check(workspace.projects.count == 3 && library.workspaces.count == 1, "Repeated add duplicated or dropped a repository")
        for project in workspace.projects {
            try check(project.error == nil && project.trees.count == 1, "Wrong registration for \(project.name)")
            try check(project.trees[0].path.hasSuffix("/" + project.name + "-linked"), "Tree routed to wrong repository")
        }

        let frontendTree = workspace.projects.first { $0.id == frontend.path }!.trees[0]
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/bin/sleep")
        worker.currentDirectoryURL = URL(fileURLWithPath: frontendTree.path)
        worker.arguments = ["90"]
        try worker.run()
        defer { if worker.isRunning { worker.terminate(); worker.waitUntilExit() } }

        library.scanStorage(for: workspace, child: nil)
        try await finish(library)
        guard let usage = library.report(for: workspace, child: nil) else { throw CheckFailure("Missing storage report") }
        try check(usage.total > 0 && usage.cleanableBytes > 0 && !usage.partial, "Expected measured disk and cleanable bytes")
        try check(usage.cleanableCount == 2 && usage.inUseCount == 1 && usage.users.contains("sleep"), "Incorrect active/cleanable classification")
        try check(usage.cleanup.rows.count == 3 && usage.cleanup.groups.reduce(0) { $0 + $1.rows.count } == 3,
                  "Review did not account for every checkout exactly once")
        try check(usage.cleanup.groups.first { $0.category == .cleanable }?.rows.count == 2 &&
                  usage.cleanup.groups.first { $0.category == .inUse }?.rows.first?.tree.path == frontendTree.path,
                  "Review grouped a checkout under the wrong reason")
        let ranked = usage.cleanup.rows.compactMap(\.bytes)
        try check(ranked == ranked.sorted(by: >), "Worktrees are not ranked by measured size")
        let childReport = library.report(for: workspace, child: workspace.projects.first { $0.id == frontend.path })
        try check(childReport?.cleanableCount == 0 && childReport?.inUseCount == 1, "Incorrect child report")
        let busy = library.selected?.projects.first { $0.id == frontend.path }?.inspections[frontendTree.id]
        try check(busy?.reason?.contains("sleep") == true, "Worktree row lost active process name")
        worker.terminate()
        worker.waitUntilExit()
        let previouslyClean = workspace.projects.first { $0.id == backend.path }!.trees[0]
        let lateWorker = Process()
        lateWorker.executableURL = URL(fileURLWithPath: "/bin/sleep")
        lateWorker.currentDirectoryURL = URL(fileURLWithPath: previouslyClean.path)
        lateWorker.arguments = ["90"]
        try lateWorker.run()
        defer { if lateWorker.isRunning { lateWorker.terminate(); lateWorker.waitUntilExit() } }
        library.remove(Removal(repo: backend.path, tree: previouslyClean, generatedFolders: []))
        try await finish(library)
        try check(FileManager.default.fileExists(atPath: previouslyClean.path) && library.failure?.text.contains("sleep") == true,
                  "Deletion ignored a process started after the scan")
        lateWorker.terminate()
        lateWorker.waitUntilExit()

        let solo = try RepositoryChoices.discover(in: parent.deletingLastPathComponent().appendingPathComponent("standalone"))
        try check(solo.repositories == [solo.folder], "Standalone repository should have no children")
        library.addWorkspace(solo, selected: Set(solo.repositories))
        try await finish(library)
        try check(library.workspaces.count == 2 && library.selected?.projects.count == 1, "Standalone did not open alongside a workspace")

        let backendFolder = URL(fileURLWithPath: backend.path)
        let moved = parent.deletingLastPathComponent().appendingPathComponent("temporarily-moved-backend")
        try FileManager.default.moveItem(at: backendFolder, to: moved)
        library.refresh(workspace.projects)
        try await finish(library)
        guard let refreshed = library.workspaces.first(where: { $0.id == workspace.id }) else {
            throw CheckFailure("Refresh dropped the workspace")
        }
        let unavailable = refreshed.projects.first { $0.id == backend.path }
        try check(unavailable?.error != nil && unavailable?.trees.isEmpty == true, "Missing member retained stale worktrees")
        try check(refreshed.projects.filter { $0.error == nil }.count == 2, "Failure in one repository affected its siblings")
        try FileManager.default.moveItem(at: moved, to: backendFolder)
        guard let member = refreshed.projects.first(where: { $0.id == frontend.path }) else {
            throw CheckFailure("Expected frontend in workspace")
        }
        library.forget(member, in: refreshed)
        let retained = library.workspaces.first { $0.id == workspace.id }?.projects
        try check(Set(retained?.map(\.id) ?? []) == [backend.path, root.path], "Removing one child affected a sibling")
        try check(FileManager.default.fileExists(atPath: frontend.appendingPathComponent(".git").path), "Removing a workspace member deleted its Git repository")
        let overlap = try RepositoryChoices.discover(in: backend)
        library.addWorkspace(overlap, selected: [overlap.folder])
        try await finish(library)
        let restored = Library(defaults: defaults)
        try check(restored.workspaces.count == 3 && restored.selection == backend.path, "Workspace selection was not restored: expected \(backend.path), actual \(String(describing: restored.selection)), original \(String(describing: library.selection)), groups \(restored.workspaces.map(\.id))")
        try check(restored.workspaces.first { $0.id == root.path }?.projects.count == 2, "Removed child was restored")
        try check(restored.refreshMinutes == 15, "Unexpected initial refresh cadence")
        restored.scanAll()
        try await finish(restored)
        guard let fleet = restored.overview else { throw CheckFailure("No fleet overview") }
        let registered = Set(restored.workspaces.flatMap { $0.projects.flatMap { $0.trees.map(\.path) } })
        let linkedSize = try WorkspaceStorage.measure(paths: Array(registered)).total
        try check(fleet.workspaces.count == 3 && registered.count == 3 && fleet.linkedCount == 3, "Duplicate repository counted twice")
        try check(fleet.cleanup.rows.count == 3 && fleet.linkedBytes == linkedSize, "Fleet included main checkouts or duplicated sizes")
        try check(fleet.workspaces.reduce(0) { $0 + $1.linkedBytes } > fleet.linkedBytes, "Fixture did not exercise overlapping memberships")
        try check(fleet.cleanableCount == 3 && fleet.cleanableBytes == linkedSize && !fleet.partial, "Fleet cleanup status incorrect")
        restored.refreshMinutes = 0
        let manual = Library(defaults: defaults)
        manual.startMonitoring()
        try await finish(manual)
        try check(manual.overview == nil && manual.selected?.projects.first?.trees.count == 1, "Off should restore registrations without a disk scan")
        manual.refreshMinutes = 5
        try await finish(manual)
        try check(manual.overview?.linkedCount == 3, "Enabling background monitoring did not refresh")
        manual.refreshMinutes = 0
        print("Verified fleet deduplication, restore, opt-out and background scanning.")
        print("Verified workspace discovery, selected members, standalone navigation, deduplication, routing and partial refresh.")
    }
}
