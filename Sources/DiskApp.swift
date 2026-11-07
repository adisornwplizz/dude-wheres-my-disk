import AppKit
import SwiftUI

// Use the property wrapper on Command Line Tools installations without SwiftUIMacros.
private typealias ViewState<Value> = State<Value>


private enum SidebarItem: Hashable {
    case workspace(String)
    case repository(workspace: String, repo: String)
}

private struct DiskWindow: View {
    @ObservedObject var library: Library
    @ObservedObject var aiOptions: AIOptions
    @ObservedObject var status: StatusMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @StateObject private var analysis = WorkspaceAnalysisSession()
    @ObservedObject private var usage = TokenUsage.shared
    @ViewState private var analysisTarget: AnalysisTarget?
    @ViewState private var member: SidebarItem?
    @ViewState private var collapsedWorkspaces: Set<String> = []

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: {
            guard let workspace = library.selected else { return nil }
            if case let .repository(id, path) = member, id == workspace.id,
               workspace.projects.contains(where: { $0.id == path }) { return member }
            return .workspace(workspace.id)
        }, set: { item in
            status.showAllAnalysis = false
            analysisTarget = nil
            library.pendingRemoval = nil
            switch item {
            case .workspace(let id):
                member = nil
                library.selection = id
            case let .repository(id, _):
                member = item
                library.selection = id
            case nil:
                break
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioMasthead {
                Button("Analyze all") { analyzeAll() }
                .buttonStyle(.borderedProminent)
                .disabled(library.workspaces.isEmpty || library.activity != nil || analysis.progress != nil)
                .help("Analyze all workspaces on this Mac")
            }
            if let progress = analysis.progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: progress)
                    Spacer()
                    if let run = usage.runs.last(where: { $0.id == analysis.runID }) { Text(run.total.label).monospacedDigit() }
                    Button("Cancel") { analysis.cancel() }
                }.font(.callout).padding(.horizontal, 24).padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        StudioCaption("Workspaces")
                        Spacer()
                    }
                    .padding(.horizontal, 15).padding(.vertical, 14)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if !library.workspaces.isEmpty {
                                Button {
                                    analysisTarget = nil
                                    library.pendingRemoval = nil
                                    status.showAllAnalysis = true
                                } label: {
                                    Label("All workspaces", systemImage: "square.stack.3d.up")
                                        .font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .background(status.showAllAnalysis ? Studio.accent.opacity(0.13) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                                Divider()
                            }
                            ForEach(library.workspaces) { workspace in sidebarRows(workspace) }
                        }.padding(8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(library.activity != nil)
                    Divider()
                    Button(action: library.chooseRepository) {
                        Label("Add Workspace…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(15).keyboardShortcut("o").disabled(library.activity != nil)
                }.background(Studio.rail)
                .frame(minWidth: 160, idealWidth: 198, maxWidth: 300)

                VStack(spacing: 0) {
                    if status.showAllAnalysis && !library.workspaces.isEmpty {
                        AllWorkspacesAnalysisView(library: library, options: aiOptions,
                                                  analysis: analysis)
                    } else if let target = analysisTarget {
                        AIAnalysisView(target: target, options: aiOptions, close: { analysisTarget = nil }).id(target.id)
                    } else if let workspace = library.selected {
                        VStack(alignment: .leading, spacing: 0) {
                            workspaceView(workspace)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(sidebarSelection.wrappedValue)
                    } else {
                        StudioWelcome(add: library.chooseRepository, busy: library.activity != nil)
                    }
                    if !status.showAllAnalysis, let activity = library.activity {
                        Divider()
                        HStack {
                            if let progress = library.scanProgress, let done = progress.completed, let total = progress.total, total > 0 {
                                ProgressView(value: Double(done), total: Double(total))
                                    .tint(Studio.accent).frame(width: 104)
                            } else { ProgressView().controlSize(.small) }
                            Text(activity).foregroundStyle(.secondary)
                            Spacer()
                            if library.canStop { Button("Stop", action: library.stop) }
                        }.font(.callout).padding(.horizontal, 18).padding(.vertical, 9)
                    }
                }.background(Studio.canvas)
            }
        }
        .tint(Studio.accent)
        .frame(minWidth: 770, minHeight: 535)
        .alert(item: $library.failure) { failure in
            Alert(title: Text("Operation could not finish"), message: Text(failure.text), dismissButton: .default(Text("OK")))
        }
        .onChange(of: library.overview?.measuredAt) { _, time in analysis.invalidate(unless: time) }
        .onChange(of: status.analysisRequested, initial: true) { _, _ in handleMenuAnalysis() }
        .onChange(of: library.activity) { _, value in if value == nil { handleMenuAnalysis() } }
        .onAppear { status.registerRoutes(openWindow: openWindow, openSettings: openSettings) }
        .sheet(item: $library.repositoryChoices) { choices in
            WorkspacePicker(choices: choices) { selected in
                library.addWorkspace(choices, selected: selected)
            } cancel: {
                library.repositoryChoices = nil
            }
            .id(choices.id)
        }

    }

    private func handleMenuAnalysis() {
        guard status.analysisRequested, library.activity == nil else { return }
        status.analysisRequested = false
        if analysis.progress == nil { analyzeAll() }
    }

    private func analyzeAll() {
        guard library.activity == nil, analysis.progress == nil, !library.workspaces.isEmpty else { return }
        analysisTarget = nil
        library.pendingRemoval = nil
        let usageID = usage.begin("All workspaces")
        library.scanAll { snapshot in
            do {
                let assessment = try BatchAssessment(snapshot)
                analysis.analyze(assessment, library: library, model: aiOptions.model(for: .ollama),
                                 timestamp: snapshot.measuredAt, usageID: usageID)
            } catch { library.failure = Failure(text: error.localizedDescription) }
        }
    }

    private func sidebarButton(_ title: String, path: String, item: SidebarItem) -> some View {
        let selected = !status.showAllAnalysis && sidebarSelection.wrappedValue == item
        return Button {
            sidebarSelection.wrappedValue = item
        } label: {
            Label(title, systemImage: "folder")
                .font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(selected ? Studio.accent : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Studio.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(path)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func sidebarRows(_ workspace: Workspace) -> some View {
        let children = workspace.projects.filter { $0.id != workspace.id }
        let parent = sidebarButton(workspace.name, path: workspace.id, item: .workspace(workspace.id))
            .contextMenu { forgetButton(workspace) }
        if children.isEmpty {
            parent
        } else {
            DisclosureGroup(isExpanded: Binding(get: {
                !collapsedWorkspaces.contains(workspace.id)
            }, set: { expand in
                if expand {
                    collapsedWorkspaces.remove(workspace.id)
                } else {
                    collapsedWorkspaces.insert(workspace.id)
                    if library.selected?.id == workspace.id { member = nil }
                }
            })) {
                ForEach(children) { project in
                    sidebarButton(project.name, path: project.id,
                                  item: .repository(workspace: workspace.id, repo: project.id))
                        .contextMenu { forgetButton(project, in: workspace) }
                }
            } label: { parent }
        }
    }

    private func forgetButton(_ project: Project, in workspace: Workspace) -> some View {
        Button("Remove from Workspace") { library.forget(project, in: workspace) }
            .help("Remove this repository from \(workspace.name) in the sidebar. Its files stay on disk.")
            .disabled(library.activity != nil)
    }

    private func forgetButton(_ workspace: Workspace) -> some View {
        Button("Remove from Sidebar") { library.forget(workspace) }
            .help("Remove this workspace from the sidebar. Its files stay on disk.")
            .disabled(library.activity != nil)
    }

    @ViewBuilder private func workspaceView(_ workspace: Workspace) -> some View {
        let child: Project? = {
            guard case let .repository(id, path) = sidebarSelection.wrappedValue,
                  id == workspace.id else { return nil }
            return workspace.projects.first { $0.id == path }
        }()
        let standalone = workspace.projects.count == 1 && workspace.projects.first?.id == workspace.id
        let shownProjects = child.map { [$0] } ?? workspace.projects
        let title = child?.name ?? workspace.name
        let report = library.report(for: workspace, child: child)
        HStack(spacing: 10) {
            if child != nil {
                Button(workspace.name) { sidebarSelection.wrappedValue = .workspace(workspace.id) }
                    .buttonStyle(.link)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                Text(title).lineLimit(1)
            } else {
                Label("Workspace", systemImage: "folder")
            }
            Spacer()
            Menu {
                if let report {
                    Text("On disk: " + (report.partial ? "≥ " : "") + diskSize(report.total))
                }
                Button("Scan Storage") { library.scanStorage(for: workspace, child: child) }
                    .disabled(library.activity != nil)
                Button("Refresh repository list") { library.refresh(shownProjects) }
                    .disabled(library.activity != nil).keyboardShortcut("r")
                if let child { forgetButton(child, in: workspace) }
                else { forgetButton(workspace) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Workspace options")
        }
        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 9)
        .background(Studio.rail)
        Divider()
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 28, weight: .bold)).tracking(-1.0).lineLimit(1).help(title)
                Spacer()
                let linked = shownProjects.reduce(0) { $0 + $1.trees.count }
                if !standalone && child == nil {
                    Label("\(workspace.projects.count) repos", systemImage: "folder")
                }
                Label("\(linked) linked", systemImage: "arrow.triangle.branch")
                    .help(shownProjects.contains(where: { $0.error != nil }) ? "Count for available repositories" : "Linked worktrees")
            }.font(.callout).foregroundStyle(.primary)
            Text(child?.id ?? workspace.id).font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(.horizontal, 22).padding(.vertical, 15)
        Divider()
        reviewContent(workspace: workspace, child: child, standalone: standalone,
                      shownProjects: shownProjects, report: report)
    }

    @ViewBuilder private func reviewContent(workspace: Workspace, child: Project?, standalone: Bool,
                                            shownProjects: [Project], report: StorageReport?) -> some View {
        if let report {
            CleanupBrowser(review: report.cleanup, multipleRepos: shownProjects.count > 1, worktree: { row in
                if let project = shownProjects.first(where: { $0.id == row.projectID }) {
                    treeRow(row.tree, project: project, review: row)
                }
            }, repositories: {
                repositoryList(workspace: workspace, child: child, standalone: standalone, report: report)
            })
        } else {
            repositoryList(workspace: workspace, child: child, standalone: standalone, report: nil)
        }
    }

    @ViewBuilder private func repositoryList(workspace: Workspace, child: Project?, standalone: Bool,
                                             report: StorageReport?) -> some View {
        if let project = child ?? (standalone ? workspace.projects.first : nil) {
            if let error = project.error {
                ContentUnavailableView("Repository unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if project.trees.isEmpty {
                ContentUnavailableView("No linked worktrees", systemImage: "arrow.triangle.branch",
                                       description: Text("Git lists only the main checkout for this repository."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { rows(project) }
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(workspace.projects) { project in
                        DisclosureGroup {
                            if let error = project.error {
                                Text(error).font(.callout).foregroundStyle(.secondary)
                                    .textSelection(.enabled).padding(.vertical, 8)
                            } else if project.trees.isEmpty {
                                Text("No linked worktrees").font(.callout)
                                    .foregroundStyle(.secondary).padding(.vertical, 8)
                            } else {
                                rows(project)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(Studio.accent)
                                Text(project.name).font(.headline)
                                if project.id == workspace.id {
                                    Text("Workspace root").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if project.error != nil {
                                    Label("Unavailable", systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.secondary)
                                } else {
                                    if let bytes = report?.byRepo[project.id] {
                                        Text(diskSize(bytes))
                                            .monospacedDigit()
                                            .help("Measured disk usage for this repository.")
                                    }
                                    Text("\(project.trees.count) linked")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .padding(.vertical, 9)
                            .help(project.id)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder private func rows(_ project: Project) -> some View {
        let ordered = project.trees.sorted {
            (project.inspections[$0.id]?.bytes ?? -1) > (project.inspections[$1.id]?.bytes ?? -1)
        }
        ForEach(ordered) { tree in
            treeRow(tree, project: project)
            Divider().padding(.leading, 20)
        }
    }

    private func treeRow(_ tree: Checkout, project: Project, review: CleanupRow? = nil) -> some View {
        let result = project.inspections[tree.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.branch").font(.title3)
                    .foregroundStyle(Studio.accent).frame(width: 30, height: 30)
                    .background(Studio.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 5) {
                    if review != nil {
                        Text(project.name.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.0).foregroundStyle(Studio.accent)
                    }
                    Text(tree.branch ?? URL(fileURLWithPath: tree.path).lastPathComponent)
                        .font(.headline).textSelection(.enabled)
                    if let result {
                        if let reason = result.reason {
                            Label(reason, systemImage: reason.hasPrefix("In use by ") ? "waveform.path.ecg" : "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Label("Cleanable · verified by Git", systemImage: "checkmark.circle")
                                .font(.callout).foregroundStyle(Studio.accent)
                        }
                    } else {
                        Text(tree.locked ? "Locked" : tree.missing ? "Missing folder" : "Awaiting local scan")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(tree.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let review {
                        if review.nestedCount > 0 {
                            Label(review.nestedCount == 1 ? "Contains 1 linked worktree" : "Contains \(review.nestedCount) linked worktrees",
                                  systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let parent = review.parentPath {
                            Text("Inside " + URL(fileURLWithPath: parent).lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).help(parent)
                        }
                    }
                    if let suggestion = library.advice(for: CleanupRow.ID(repo: project.id, path: tree.path)) {
                        Text("Model suggestion").font(.caption.weight(.semibold)).foregroundStyle(Studio.accent)
                        Text(verbatim: suggestion).font(.callout).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 8) {
                    if let bytes = result?.bytes {
                        Text(diskSize(bytes)).font(.system(.headline, design: .rounded).monospacedDigit())
                    } else {
                        Text("Size unknown").font(.caption).foregroundStyle(.secondary)
                    }
                }.controlSize(.small).disabled(library.activity != nil)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button("View worktree report…") { analysisTarget = AnalysisTarget(repo: project.id, tree: tree) }
                    .disabled(library.activity != nil)
            }
            let clean: (() -> Void)? = result.flatMap { inspection in
                guard inspection.category == .cleanable else { return nil }
                return {
                    library.pendingRemoval = Removal(repo: project.id, tree: tree, generatedFolders: inspection.generatedFolders)
                }
            }
            WorktreeChangeCard(summary: analysis.summaries[CleanupRow.ID(repo: project.id, path: tree.path)],
                               clean: clean, busy: library.activity != nil)
            if let removal = library.pendingRemoval, removal.repo == project.id, removal.tree.id == tree.id {
                RemovalConfirmation(removal: removal, busy: library.activity != nil,
                                    cancel: { library.pendingRemoval = nil },
                                    confirm: { library.pendingRemoval = nil; library.remove(removal) })
            }
        }.padding(.horizontal, 20).padding(.vertical, 15)
    }
}

private struct CleanupBrowser<Row: View, Repositories: View>: View {
    private enum Layout { case reasons, largest, repositories }
    private enum Scope { case review, all }

    let review: CleanupReview
    let multipleRepos: Bool
    @ViewBuilder let worktree: (CleanupRow) -> Row
    @ViewBuilder let repositories: () -> Repositories
    @ViewState private var layout: Layout = .largest
    @ViewState private var scope: Scope = .all

    var body: some View {
        let candidates = review.rows.filter { $0.category.isReviewCandidate }
        let rows = scope == .all ? review.rows : candidates

        HStack(spacing: 12) {
            Picker("Worktree view", selection: $layout) {
                Text("By reason").tag(Layout.reasons)
                Text("Largest first").tag(Layout.largest)
                if multipleRepos { Text("By repository").tag(Layout.repositories) }
            }
            .labelsHidden().pickerStyle(.segmented)
            Spacer(minLength: 0)
            if layout != .repositories {
                Picker("Worktrees shown", selection: $scope) {
                    Text("Needs review (\(candidates.count))").tag(Scope.review)
                    Text("All (\(review.rows.count))").tag(Scope.all)
                }
                .labelsHidden().fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 18).padding(.vertical, 9)
        Divider()
        if layout == .repositories && multipleRepos {
            repositories()
        } else if rows.isEmpty {
            ContentUnavailableView(scope == .review ? "No worktrees need review" : "No linked worktrees",
                                   systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if layout == .reasons {
                        Text("Grouped by first reason. Nested worktree sizes can overlap.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                    }
                    if layout == .largest || (layout == .repositories && !multipleRepos) {
                        ForEach(rows) { row in
                            worktree(row)
                            Divider()
                        }
                    } else {
                        ForEach(review.groups.filter { scope == .all || $0.category.isReviewCandidate }) { group in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(group.category.guidance)
                                        .font(.callout).foregroundStyle(.secondary)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                    ForEach(group.rows) { row in
                                        worktree(row)
                                        Divider()
                                    }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Text(group.category.title).font(.headline)
                                    Text("\(group.rows.count)").font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Text(group.bytes.map(diskSize) ?? "Size unknown")
                                        .font(.callout.monospacedDigit())
                                }
                                .padding(.vertical, 9)
                            }
                            .help("Expand to review largest first. Rescan after addressing the first reason shown.")
                            .padding(.vertical, 4).padding(.horizontal, 20)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct WorkspacePicker: View {
    let choices: RepositoryChoices
    let add: (Set<URL>) -> Void
    let cancel: () -> Void
    @ViewState private var selected: Set<URL>

    init(choices: RepositoryChoices, add: @escaping (Set<URL>) -> Void, cancel: @escaping () -> Void) {
        self.choices = choices
        self.add = add
        self.cancel = cancel
        _selected = State(initialValue: Set(choices.repositories))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose repositories").font(.title2.bold())
            Text(choices.folder.path).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(choices.repositories, id: \.self) { repo in
                        Toggle(isOn: Binding(get: { selected.contains(repo) }, set: { include in
                            if include { selected.insert(repo) } else { selected.remove(repo) }
                        })) {
                            HStack {
                                Text(repo.lastPathComponent)
                                if repo.path == choices.folder.path {
                                    Text("Workspace root").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .help(repo.path)
                    }
                }
                .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add Workspace") { add(selected) }
                    .keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
        }.padding(22).frame(width: 430, height: 280)
    }
}

final class DiskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
@MainActor
struct DiskApp: App {
    @NSApplicationDelegateAdaptor(DiskAppDelegate.self) private var appDelegate
    @StateObject private var library: Library
    @StateObject private var aiOptions = AIOptions()
    @StateObject private var status: StatusMonitor

    init() {
        let shared = Library()
        shared.startMonitoring()
        _library = StateObject(wrappedValue: shared)
        _status = StateObject(wrappedValue: StatusMonitor(library: shared))
    }

    var body: some Scene {
        Window("Dude, Where’s My Disk?", id: "library") {
            DiskWindow(library: library, aiOptions: aiOptions, status: status)
        }
        .defaultSize(width: 1120, height: 720)

        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Show Menu Bar Overview") { status.showOverview() }
            }
        }

        Settings {
            MonitorSettings(library: library, options: aiOptions)
        }
    }
}
