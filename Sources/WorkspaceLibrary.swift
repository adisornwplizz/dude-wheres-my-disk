import Darwin
import AppKit
import SwiftUI

struct Project: Identifiable {
    let id: String
    var name: String { URL(fileURLWithPath: id).lastPathComponent }
    var trees: [Checkout] = []
    var error: String?
    var inspections: [Checkout.ID: Inspection] = [:]
    fileprivate var inspectedFiles: [Checkout.ID: FileIdentity] = [:]
}

struct Workspace: Identifiable {
    let id: String
    let projects: [Project]
    var name: String { URL(fileURLWithPath: id).lastPathComponent }
}

struct ScanProgress: Sendable {
    let label: String
    var completed: Int?
    var total: Int?
}

struct StorageReport {
    let total: Int64
    let cleanableBytes: Int64
    let cleanup: CleanupReview
    let cleanableCount: Int
    let inUseCount: Int
    let measuredAt: Date
    let partial: Bool
    let byRepo: [String: Int64]
    let users: [String]
    let activityAvailable: Bool
}

struct FleetWorkspace: Identifiable {
    let id: String
    var name: String { URL(fileURLWithPath: id).lastPathComponent }
    let linkedCount: Int
    let linkedBytes: Int64
    let cleanableCount: Int
    let inUseCount: Int
    let partial: Bool
}

struct FleetOverview {
    let workspaces: [FleetWorkspace]
    let linkedBytes: Int64
    let cleanableBytes: Int64
    let linkedCount: Int
    let cleanableCount: Int
    let inUseCount: Int
    let activityAvailable: Bool
    let measuredAt: Date
    let partial: Bool
    let cleanup: CleanupReview
}

private struct StorageScope: Hashable {
    let workspace: String
    let member: String?
}

struct Failure: Identifiable {
    let id = UUID()
    let text: String
}

struct RepositoryChoices: Identifiable {
    let folder: URL
    let repositories: [URL]
    var id: URL { folder }

    static func discover(in url: URL) throws -> RepositoryChoices {
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        func hasGit(_ url: URL) -> Bool {
            manager.fileExists(atPath: url.appendingPathComponent(".git").path)
        }
        let children = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                       options: .skipsHiddenFiles)
        let repositories = children.filter { child in
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink == false, values.isDirectory == true, values.isPackage != true
            else { return false }
            return hasGit(child)
        }.map { $0.resolvingSymlinksInPath().standardizedFileURL }
         .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return RepositoryChoices(folder: folder, repositories: (hasGit(folder) ? [folder] : []) + repositories)
    }
}

struct Removal: Identifiable {
    let repo: String
    let tree: Checkout
    let generatedFolders: [String]
    var id: String { tree.path }
}

// A recreated checkout can reuse the same path, branch, and commit.
fileprivate struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(for tree: Checkout) {
        let marker = URL(fileURLWithPath: tree.path).appendingPathComponent(".git")
        var info = stat()
        guard lstat(marker.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

@MainActor
final class Library: ObservableObject {
    private struct Membership: Codable {
        let folder: String
        var repos: [String]
    }

    @Published private var memberships: [Membership] = []
    @Published private var projects: [String: Project] = [:]
    @Published private var reports: [StorageScope: StorageReport] = [:]
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var overview: FleetOverview? {
        didSet { suggestions.removeAll() }
    }
    @Published private var suggestions: [CleanupRow.ID: String] = [:]

    func saveAdvice(_ byID: [CleanupRow.ID: String], measuredAt: Date) {
        guard let overview, overview.measuredAt == measuredAt else { return }
        let eligibleIDs = Set(overview.cleanup.rows.map(\.id))
        suggestions = byID.filter { eligibleIDs.contains($0.key) }
    }

    func advice(for rowID: CleanupRow.ID) -> String? { suggestions[rowID] }

    @Published var selection: String? {
        didSet { defaults.set(selection, forKey: "library.selection") }
    }
    @Published var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: "library.refreshMinutes")
            if monitoring {
                resetTimer()
                if oldValue == 0 && refreshMinutes > 0 { requestAutomaticScan() }
            }
        }
    }
    @Published var activity: String?
    @Published var repositoryChoices: RepositoryChoices?
    @Published var pendingRemoval: Removal?
    @Published var failure: Failure?
    @Published var canStop = false
    private let defaults: UserDefaults
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var monitoring = false
    private var automaticScanPending = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedInterval = defaults.object(forKey: "library.refreshMinutes") as? Int
        refreshMinutes = savedInterval.flatMap { [0, 5, 15, 30, 60].contains($0) ? $0 : nil } ?? 15
        guard let data = defaults.data(forKey: "library.workspaces"),
              let stored = try? JSONDecoder().decode([Membership].self, from: data) else { return }
        var seenFolders = Set<String>()
        for entry in stored where entry.folder.hasPrefix("/") && seenFolders.insert(entry.folder).inserted {
            var seenRepos = Set<String>()
            let repos = entry.repos.filter { path in
                (path == entry.folder || (path as NSString).deletingLastPathComponent == entry.folder) &&
                    seenRepos.insert(path).inserted
            }
            guard !repos.isEmpty else { continue }
            memberships.append(Membership(folder: entry.folder, repos: repos))
            for path in repos { projects[path] = Project(id: path, error: "Refresh to read this repository.") }
        }
        selection = memberships.first { $0.folder == defaults.string(forKey: "library.selection") }?.folder ?? memberships.first?.folder
    }

    deinit { timer?.cancel() }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        resetTimer()
        if refreshMinutes > 0 {
            requestAutomaticScan()
        } else if !projects.isEmpty {
            refresh(Array(projects.values))
        }
    }

    private func resetTimer() {
        timer?.cancel()
        timer = nil
        automaticScanPending = false
        guard refreshMinutes > 0 else { return }
        let delay = Duration.seconds(refreshMinutes * 60)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                self?.requestAutomaticScan()
            }
        }
    }

    private func requestAutomaticScan() {
        guard monitoring, refreshMinutes > 0, !memberships.isEmpty else { return }
        if activity == nil { scanAll() }
        else { automaticScanPending = true }
    }

    private func saveMemberships() {
        if let data = try? JSONEncoder().encode(memberships) {
            defaults.set(data, forKey: "library.workspaces")
        }
        overview = nil
        requestAutomaticScan()
    }

    var workspaces: [Workspace] {
        memberships.map { membership in
            Workspace(id: membership.folder, projects: membership.repos.compactMap { projects[$0] })
        }
    }
    var selected: Workspace? { workspaces.first { $0.id == selection } }

    func chooseRepository() {
        guard activity == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "Add a workspace"
        picker.message = "Choose a project folder. The app finds Git repositories here and directly inside this folder. Added workspaces are remembered and scanned locally on the background refresh schedule."
        picker.prompt = "Choose Folder"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        guard picker.runModal() == .OK, let url = picker.url else { return }
        run("Looking for repositories…") {
            let choices = try await Task.detached { try RepositoryChoices.discover(in: url) }.value
            try Task.checkCancellation()
            if choices.repositories.isEmpty {
                self.failure = Failure(text: "Choose a main checkout or a folder with repositories directly inside it.")
            } else if choices.repositories == [choices.folder] {
                try await self.add(choices, members: [choices.folder])
            } else {
                self.repositoryChoices = choices
            }
        }
    }

    func addWorkspace(_ choices: RepositoryChoices, selected: Set<URL>) {
        let members = choices.repositories.filter(selected.contains)
        guard activity == nil, !members.isEmpty else { return }
        repositoryChoices = nil
        run("Reading repositories…") { try await self.add(choices, members: members) }
    }

    private func add(_ choices: RepositoryChoices, members: [URL]) async throws {
        let root = choices.folder.path
        let paths = members.map(\.path)
        var loaded: [Project] = []
        for path in paths where projects[path] == nil || projects[path]?.error != nil {
            try Task.checkCancellation()
            loaded.append(await Self.loadProject(path))
        }
        try Task.checkCancellation()
        for project in loaded { projects[project.id] = project }
        if let i = memberships.firstIndex(where: { $0.folder == root }) {
            let all = Set(memberships[i].repos + paths)
            let order = choices.repositories.map(\.path)
            memberships[i].repos = order.filter(all.contains) + memberships[i].repos.filter { !order.contains($0) }
        } else {
            memberships.append(Membership(folder: root, repos: paths))
        }
        reports = reports.filter { $0.key.workspace != root }
        selection = root
        saveMemberships()
    }

    func forget(_ workspace: Workspace) {
        guard activity == nil else { return }
        reports = reports.filter { $0.key.workspace != workspace.id }
        memberships.removeAll { $0.folder == workspace.id }
        discardUnreferencedProjects()
        if selection == workspace.id { selection = memberships.first?.folder }
        saveMemberships()
    }

    func forget(_ project: Project, in workspace: Workspace) {
        guard activity == nil, let index = memberships.firstIndex(where: { $0.folder == workspace.id }) else { return }
        reports = reports.filter { $0.key.workspace != workspace.id }
        memberships[index].repos.removeAll { $0 == project.id }
        if memberships[index].repos.isEmpty {
            forget(workspace)
        } else {
            discardUnreferencedProjects()
            saveMemberships()
        }
    }

    private func discardUnreferencedProjects() {
        let retained = Set(memberships.flatMap(\.repos))
        projects = projects.filter { retained.contains($0.key) }
    }

    private static func loadProject(_ path: String) async -> Project {
        await Task.detached {
            do { return Project(id: path, trees: try Inventory.list(repo: path)) }
            catch { return Project(id: path, error: error.localizedDescription) }
        }.value
    }

    func refresh(_ members: [Project]) {
        run("Refreshing repositories…") {
            self.invalidateReports(for: members.map(\.id))
            for old in members {
                try Task.checkCancellation()
                let refreshed = await Self.loadProject(old.id)
                try Task.checkCancellation()
                self.projects[old.id] = refreshed
                let approved = Set(old.trees.filter { old.inspections[$0.id] != nil })
                for tree in refreshed.trees where approved.contains(tree) {
                    try Task.checkCancellation()
                    guard let previous = old.inspectedFiles[tree.id], previous == FileIdentity(for: tree) else { continue }
                    do { try await self.read(tree, in: old.id) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        self.projects[old.id]?.inspections[tree.id] =
                            Inspection(bytes: nil, blocker: CleanupBlocker(.uncertain, error.localizedDescription), generatedFolders: [])
                    }
                }
            }
        }
    }

    func inspect(_ tree: Checkout, in project: Project) {
        run("Inspecting \(tree.branch ?? "worktree")…") {
            self.invalidateReports(for: [project.id])
            try await self.read(tree, in: project.id)
        }
    }

    private func read(_ tree: Checkout, in repo: String) async throws {
        let marker = FileIdentity(for: tree)
        let result = try await Task.detached { try Inventory.inspect(repo: repo, checkout: tree) }.value
        try Task.checkCancellation()
        projects[repo]?.inspections[tree.id] = result
        projects[repo]?.inspectedFiles[tree.id] = marker
    }

    func remove(_ removal: Removal) {
        let tree = removal.tree
        let repo = removal.repo
        run("Removing worktree…", stoppable: false) {
            self.reports.removeAll()
            guard let approval = self.projects[repo]?.inspections[tree.id], approval.reason == nil,
                  let previous = self.projects[repo]?.inspectedFiles[tree.id], previous == FileIdentity(for: tree) else {
                self.projects[repo]?.inspections.removeValue(forKey: tree.id)
                self.failure = Failure(text: "The checkout changed. Inspect it again before removing it.")
                return
            }
            self.projects[repo]?.inspections.removeValue(forKey: tree.id)
            self.projects[repo]?.inspectedFiles.removeValue(forKey: tree.id)
            try await Task.detached {
                try Inventory.remove(repo: repo, checkout: tree, approvedGeneratedFolders: removal.generatedFolders)
            }.value
            self.projects[repo]?.trees.removeAll { $0.id == tree.id }
            self.overview = nil
            self.requestAutomaticScan()
        }
    }

    func report(for workspace: Workspace, child: Project?) -> StorageReport? {
        reports[StorageScope(workspace: workspace.id, member: child?.id)]
    }

    private func invalidateReports(for repos: [String]) {
        let affectedRepos = Set(repos)
        suggestions = suggestions.filter { !affectedRepos.contains($0.key.repo) }
        let affected = Set(memberships.filter { !Set($0.repos).isDisjoint(with: repos) }.map(\.folder))
        reports = reports.filter { !affected.contains($0.key.workspace) }
    }

    func scanStorage(for workspace: Workspace, child: Project?) {
        let scope = child.map { Workspace(id: $0.id, projects: [$0]) } ?? workspace
        let coversFleet = memberships.count == 1 && scope.id == workspace.id &&
            scope.projects.count == workspace.projects.count
        scan([scope], publishOverview: coversFleet, parent: workspace.id)
    }

    func scanAll() {
        guard !workspaces.isEmpty else { return }
        scan(workspaces, publishOverview: true, parent: nil)
    }

    private func scan(_ scopes: [Workspace], publishOverview: Bool, parent: String?) {
        run("Reading worktree registrations…") {
            let paths = Set(scopes.flatMap { $0.projects.map(\.id) }).sorted()
            var loaded: [String: Project] = [:]
            for (index, path) in paths.enumerated() {
                try Task.checkCancellation()
                self.scanProgress = ScanProgress(label: "Reading repository " + String(index + 1) + " of " + String(paths.count), completed: index, total: paths.count)
                loaded[path] = await Self.loadProject(path)
            }
            let latest = scopes.map { workspace in
                Workspace(id: workspace.id, projects: workspace.projects.compactMap { loaded[$0.id] })
            }
            let scan = Task.detached(priority: .utility) {
                try await StorageScan.run(workspaces: latest) { progress in
                    await MainActor.run {
                        if self.canStop {
                            self.activity = progress.label
                            self.scanProgress = progress
                        }
                    }
                }
            }
            let result = try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
            try Task.checkCancellation()
            self.invalidateReports(for: paths)
            for project in result.projects { self.projects[project.id] = project }
            for scope in scopes {
                let root = parent ?? scope.id
                for project in scope.projects {
                    self.reports[StorageScope(workspace: root, member: project.id)] = result.memberReports[project.id]
                }
                if root == scope.id {
                    self.reports[StorageScope(workspace: root, member: nil)] = result.workspaceReports[scope.id]
                }
            }
            if publishOverview {
                self.overview = result.overview
                self.automaticScanPending = false
            }
        }
    }

    func stop() {
        automaticScanPending = false
        operation?.cancel()
        canStop = false
        activity = "Finishing current check…"
    }

    private func run(_ label: String, stoppable: Bool = true, action: @escaping @MainActor () async throws -> Void) {
        guard activity == nil else { return }
        activity = label
        canStop = stoppable
        operation = Task {
            defer {
                scanProgress = nil
                activity = nil
                canStop = false
                operation = nil
                if automaticScanPending {
                    automaticScanPending = false
                    requestAutomaticScan()
                }
            }
            do { try await action() }
            catch is CancellationError {}
            catch { failure = Failure(text: error.localizedDescription) }
        }
    }
}

private struct StorageScan {
    let projects: [Project]
    let overview: FleetOverview
    let workspaceReports: [String: StorageReport]
    let memberReports: [String: StorageReport]

    static func run(workspaces: [Workspace], progress: (ScanProgress) async -> Void) async throws -> StorageScan {
        var seen = Set<String>()
        let projects = workspaces.flatMap(\.projects).filter { seen.insert($0.id).inserted }
        var reviewed = projects
        var verifiedByRepo: [String: Set<String>] = [:]
        var incompleteRepos = Set(projects.filter { $0.error != nil }.map(\.id))
        let processes = WorktreeActivity.snapshot()
        let treeCount = projects.reduce(0) { $0 + $1.trees.count }
        var checked = 0
        for index in reviewed.indices {
            let repo = reviewed[index].id
            for tree in reviewed[index].trees {
                try Task.checkCancellation()
                checked += 1
                await progress(ScanProgress(label: "Checking worktree \(checked) of \(treeCount)…", completed: checked - 1, total: treeCount))
                let marker = tree.missing ? nil : FileIdentity(for: tree)
                do {
                    reviewed[index].inspections[tree.id] = try Inventory.review(repo: repo, checkout: tree, activity: processes)
                    if !tree.missing {
                        verifiedByRepo[repo, default: []].insert(tree.path)
                        reviewed[index].inspectedFiles[tree.id] = marker
                    } else {
                        incompleteRepos.insert(repo)
                    }
                } catch {
                    incompleteRepos.insert(repo)
                    reviewed[index].inspections[tree.id] = Inspection(bytes: nil, blocker: CleanupBlocker(.uncertain, error.localizedDescription), generatedFolders: [])
                }
            }
        }
        try Task.checkCancellation()
        await progress(ScanProgress(label: "Measuring folders on disk…"))
        let verifiedPaths = verifiedByRepo.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let roots = Set(workspaces.map(\.id) + reviewed.map(\.id)).union(verifiedPaths)
        let disk = try WorkspaceStorage.measure(paths: roots.sorted())
        try Task.checkCancellation()
        for index in reviewed.indices {
            for (path, item) in reviewed[index].inspections where verifiedByRepo[reviewed[index].id]?.contains(path) == true {
                let partial = disk.incomplete.contains(path)
                if partial { incompleteRepos.insert(reviewed[index].id) }
                let blocker = item.blocker ?? (partial ? CleanupBlocker(.uncertain, "Could not measure the whole checkout") : nil)
                reviewed[index].inspections[path] = Inspection(bytes: partial ? nil : disk.sizes[path], blocker: blocker,
                                                               generatedFolders: item.generatedFolders, mergeEvidence: item.mergeEvidence)
            }
        }
        let nesting = CheckoutNesting(projects: reviewed)
        let date = Date()
        func makeReport(folders: [String], members: [Project]) -> StorageReport {
            // Old registrations in one repo can point at a path now owned by another.
            var owners: [String: String] = [:]
            for member in members {
                for tree in member.trees where owners[tree.path] == nil || verifiedByRepo[member.id]?.contains(tree.path) == true {
                    owners[tree.path] = member.id
                }
            }
            let uniqueMembers = members.map { member in
                var unique = member
                unique.trees = member.trees.filter { owners[$0.path] == member.id }
                return unique
            }
            var paths = Set(folders)
            var candidates: Set<String> = []
            var active: Set<String> = []
            var byRepo: [String: Int64] = [:]
            for member in members {
                let linked = verifiedByRepo[member.id] ?? []
                let memberPaths = [member.id] + Array(linked)
                paths.formUnion(memberPaths)
                byRepo[member.id] = disk.allocated(paths: memberPaths)
                for path in linked {
                    if !processes.names(for: path).isEmpty { active.insert(path) }
                    if let result = member.inspections[path], result.reason == nil, result.bytes != nil {
                        candidates.insert(path)
                    }
                }
            }
            let partial = !disk.incomplete.isDisjoint(with: paths) || members.contains { incompleteRepos.contains($0.id) }
            let users = Set(paths.flatMap { processes.names(for: $0) }).sorted()
            return StorageReport(total: disk.allocated(paths: Array(paths)),
                                 cleanableBytes: disk.reclaimable(paths: Array(candidates)),
                                 cleanup: CleanupReview(projects: uniqueMembers, nesting: nesting, disk: disk),
                                 cleanableCount: candidates.count, inUseCount: active.count, measuredAt: date,
                                 partial: partial, byRepo: byRepo, users: users, activityAvailable: processes.isAvailable)
        }
        let byID = Dictionary(uniqueKeysWithValues: reviewed.map { ($0.id, $0) })
        let summaries = byID.mapValues { makeReport(folders: [$0.id], members: [$0]) }
        var workspaceReports: [String: StorageReport] = [:]
        var workspaceRows: [FleetWorkspace] = []
        for workspace in workspaces {
            let members = workspace.projects.compactMap { byID[$0.id] }
            let report = makeReport(folders: [workspace.id], members: members)
            workspaceReports[workspace.id] = report
            let paths = Set(report.cleanup.rows.map { $0.tree.path })
            workspaceRows.append(FleetWorkspace(id: workspace.id, linkedCount: paths.count,
                                                 linkedBytes: disk.allocated(paths: Array(paths.intersection(verifiedPaths))),
                                                 cleanableCount: report.cleanableCount, inUseCount: report.inUseCount,
                                                 partial: report.partial))
        }
        let overall = makeReport(folders: workspaces.map(\.id), members: reviewed)
        let overview = FleetOverview(workspaces: workspaceRows, linkedBytes: disk.allocated(paths: Array(verifiedPaths)),
                                    cleanableBytes: overall.cleanableBytes, linkedCount: Set(overall.cleanup.rows.map { $0.tree.path }).count,
                                    cleanableCount: overall.cleanableCount, inUseCount: overall.inUseCount,
                                    activityAvailable: overall.activityAvailable, measuredAt: date, partial: overall.partial,
                                    cleanup: overall.cleanup)
        return StorageScan(projects: reviewed, overview: overview, workspaceReports: workspaceReports, memberReports: summaries)
    }
}
