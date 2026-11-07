import SwiftUI

private typealias BranchViewState<Value> = State<Value>

private struct BranchJob: Identifiable {
    let id = UUID()
    let repo: String
    let removal: BranchCandidate?
}

struct BranchReviewView: View {
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @BranchViewState private var repository: String
    @BranchViewState private var report: BranchReport?
    @BranchViewState private var job: BranchJob?
    @BranchViewState private var confirmation: BranchCandidate?
    @BranchViewState private var message: String?
    @BranchViewState private var error: String?

    init(library: Library) {
        self.library = library
        let first = library.selected?.projects.first?.id ?? library.workspaces.first?.projects.first?.id ?? ""
        _repository = State(initialValue: first)
    }

    private var repositories: [String] {
        Set(library.workspaces.flatMap { $0.projects.map(\.id) }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var removing: Bool { job?.removal != nil && message == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local branches").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(removing)
            }
            if repositories.isEmpty {
                ContentUnavailableView("Add a repository first", systemImage: "folder.badge.plus")
            } else {
                Picker("Repository", selection: $repository) {
                    ForEach(repositories, id: \.self) { path in
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath).tag(path)
                    }
                }
                .disabled(job != nil)
                .onChange(of: repository) { _, _ in
                    report = nil
                    confirmation = nil
                    message = nil
                    error = nil
                }
                HStack {
                    Button("Check upstreams") { start() }
                        .buttonStyle(.borderedProminent).disabled(job != nil || repository.isEmpty)
                    if job != nil {
                        ProgressView().controlSize(.small)
                        Text(removing ? "Rechecking before removal…" : "Checking remote branches…")
                            .font(.callout).foregroundStyle(.secondary)
                        if !removing {
                            Button("Stop") { self.job = nil; if message == nil { message = "Check stopped." } }
                        }
                    }
                }
                if let message { Text(verbatim: message).font(.callout).textSelection(.enabled) }
                if let error {
                    Label { Text(verbatim: error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                if let report {
                    results(report)
                } else if job == nil && error == nil {
                    Text("Check the selected repository’s remotes to find local branches whose upstream has been deleted.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(22).frame(width: 650, height: 500).tint(Studio.accent)
        .interactiveDismissDisabled(removing)
        .task(id: job?.id) {
            if let job { await perform(job) }
        }
        .sheet(item: $confirmation) { branch in
            VStack(alignment: .leading, spacing: 12) {
                Label("Remove local branch?", systemImage: "arrow.triangle.branch").font(.title2.bold())
                Text(verbatim: "refs/heads/" + branch.name).font(.headline.monospaced()).textSelection(.enabled)
                Text(verbatim: repository).font(.caption.monospaced()).textSelection(.enabled)
                Text(verbatim: "Last verified tip " + branch.tip).font(.callout.monospaced())
                if let remote = branch.remote, let upstream = branch.upstream {
                    Text(verbatim: "Upstream " + remote + " · " + upstream).font(.callout)
                }
                Text("The app will check the upstream, merge and checkout state again, then ask Git to delete this local branch.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmation = nil }.keyboardShortcut(.cancelAction)
                    Button("Remove Local Branch", role: .destructive) {
                        confirmation = nil
                        start(removing: branch)
                    }
                }
            }
            .padding(22).frame(width: 460)
        }
    }

    @ViewBuilder private func results(_ result: BranchReport) -> some View {
        if result.rows.isEmpty {
            ContentUnavailableView("No local branches", systemImage: "arrow.triangle.branch")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let base = result.defaultBranch {
                        Text(verbatim: "Local default branch · " + base).font(.caption).foregroundStyle(.secondary)
                    }
                    let suggested = result.rows.filter { $0.state == .suggested }
                    let uncertain = result.rows.filter { $0.state == .unknown }
                    let kept = result.rows.filter { $0.state == .keep }
                    StudioCaption("Suggested for removal · " + String(suggested.count))
                    ForEach(suggested) { branchRow($0) }
                    if !uncertain.isEmpty {
                        StudioCaption("Needs verification · " + String(uncertain.count))
                        ForEach(uncertain) { branchRow($0) }
                    }
                    if !kept.isEmpty {
                        DisclosureGroup {
                            ForEach(kept) { branchRow($0) }
                        } label: { StudioCaption("Keep · " + String(kept.count)) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func branchRow(_ branch: BranchCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: branch.name).font(.headline).textSelection(.enabled)
                if let remote = branch.remote, let upstream = branch.upstream {
                    Text(verbatim: remote + " · " + upstream).font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(verbatim: branch.reason).font(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if branch.state == .suggested {
                Button("Remove Local Branch…") { confirmation = branch }
                    .controlSize(.small).disabled(job != nil)
            }
        }
        .padding(.vertical, 6)
    }

    private func start(removing branch: BranchCandidate? = nil) {
        guard job == nil, repositories.contains(repository) else { return }
        report = nil
        error = nil
        message = nil
        job = BranchJob(repo: repository, removal: branch)
    }

    @MainActor private func perform(_ request: BranchJob) async {
        guard job?.id == request.id, !Task.isCancelled else { return }
        do {
            if let branch = request.removal {
                let removal = Task.detached { try BranchCleanup.remove(repo: request.repo, candidate: branch) }
                try await removal.value
                message = "Removed local branch " + branch.name + "."
            }
            let check = Task.detached { try BranchCleanup.review(repo: request.repo) }
            let result = try await withTaskCancellationHandler(operation: { try await check.value },
                                                               onCancel: { check.cancel() })
            try Task.checkCancellation()
            if job?.id == request.id { report = result }
        } catch {
            if !Task.isCancelled, job?.id == request.id { self.error = error.localizedDescription }
        }
        if job?.id == request.id { job = nil }
    }
}
