import SwiftUI

private typealias BatchState<Value> = State<Value>

struct BatchAssessment {
    struct Item: Identifiable {
        let id: String
        let row: CleanupRow
    }

    private struct Facts: Encodable {
        let scope = "all_registered_workspaces"
        let workspaces: Int
        let linkedWorktrees: Int
        let onDiskBytes: Int64
        let reclaimableEstimateBytes: Int64?
        let partial: Bool
        let processActivityAvailable: Bool
        let verdictCounts: [String: Int]
        let firstReasonCounts: [String: Int]
        let omittedWorktrees: Int
        let worktrees: [ItemFacts]
    }

    private struct ItemFacts: Encodable {
        let id: String
        let verdict: String
        let firstReason: String
        let onDiskBytes: Int64?
        let mergeProof: String
        let commitsOutsideLocalDefault: Int?
        let generatedItemsRequiringApproval: Int?
        let nestedCheckouts: Int
        let insideAnotherCheckout: Bool

        init(_ item: Item) {
            let row = item.row
            id = item.id
            verdict = row.category.assessmentVerdict
            firstReason = row.category.rawValue
            onDiskBytes = row.bytes
            mergeProof = row.mergeEvidence.code
            commitsOutsideLocalDefault = row.mergeEvidence.outsideCommits
            generatedItemsRequiringApproval = row.generatedItemCount
            nestedCheckouts = row.nestedCount
            insideAnotherCheckout = row.parentPath != nil
        }
    }

    let items: [Item]
    let shownToModel: Int
    let verdictCounts: [String: Int]
    let payload: String

    init(_ snapshot: FleetOverview) throws {
        try self.init(ranked: snapshot.cleanup.rows, workspaces: snapshot.workspaces.count,
                      onDisk: snapshot.linkedBytes, cleanable: snapshot.activityAvailable ? snapshot.cleanableBytes : nil,
                      partial: snapshot.partial)
    }

    init(ranked rows: [CleanupRow], workspaces: Int, onDisk: Int64, cleanable: Int64?, partial: Bool) throws {
        let sortedIDs: [CleanupRow.ID] = rows.map(\.id).sorted { (lhs: CleanupRow.ID, rhs: CleanupRow.ID) -> Bool in
            if lhs.repo != rhs.repo { return lhs.repo < rhs.repo }
            return lhs.path < rhs.path
        }
        var labels: [CleanupRow.ID: String] = [:]
        for (index, id) in sortedIDs.enumerated() { labels[id] = "W\(index + 1)" }
        // The scan already ranks measured size within each verdict. Keep actionable groups first.
        let verdictOrder = ["Can remove", "Review required", "Keep"]
        let ordered = verdictOrder.flatMap { verdict in
            rows.filter { $0.category.assessmentVerdict == verdict }
        }
        items = ordered.map { Item(id: labels[$0.id]!, row: $0) }
        verdictCounts = rows.reduce(into: [:]) { $0[$1.category.assessmentVerdict, default: 0] += 1 }
        let reasonCounts = rows.reduce(into: [String: Int]()) { $0[$1.category.rawValue, default: 0] += 1 }
        shownToModel = min(items.count, 48)
        let facts = Facts(workspaces: workspaces, linkedWorktrees: rows.count,
                          onDiskBytes: onDisk, reclaimableEstimateBytes: cleanable,
                          partial: partial, processActivityAvailable: cleanable != nil,
                          verdictCounts: verdictCounts, firstReasonCounts: reasonCounts,
                          omittedWorktrees: items.count - shownToModel, worktrees: items.prefix(shownToModel).map(ItemFacts.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        payload = String(decoding: try encoder.encode(facts), as: UTF8.self)
    }
}

struct BatchSuggestions: Decodable {
    let summary: String
    let byReason: [String: String]
    let byWorktree: [String: String]

    static func read(_ text: String, matching assessment: BatchAssessment) throws -> (summary: String, advice: [CleanupRow.ID: String]) {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("```json\n"), source.hasSuffix("\n```") {
            source = String(source.dropFirst(8).dropLast(4))
        }
        let response = try JSONDecoder().decode(Self.self, from: Data(source.utf8))
        func plain(_ value: String?, limit: Int) -> String? {
            guard let value, !value.isEmpty else { return nil }
            let words = value.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            let clean = String(words.joined(separator: " ").prefix(limit))
            return clean.isEmpty ? nil : clean
        }
        guard let summary = plain(response.summary, limit: 2_000) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var advice: [CleanupRow.ID: String] = [:]
        for (index, item) in assessment.items.enumerated() {
            let specific = index < assessment.shownToModel ? response.byWorktree[item.id] : nil
            advice[item.row.id] = plain(specific, limit: 450) ?? plain(response.byReason[item.row.category.rawValue], limit: 450)
        }
        return (summary, advice)
    }
}

@MainActor
final class WorkspaceAnalysisSession: ObservableObject {
    @Published private(set) var summaries: [CleanupRow.ID: String] = [:]
    @Published private(set) var progress: String?
    @Published private(set) var reply: String?
    @Published private(set) var problem: String?
    private(set) var runID: UUID?
    private var task: Task<Void, Never>?
    private var snapshot: Date?

    func invalidate(unless timestamp: Date?) {
        guard snapshot != timestamp else { return }
        cancel()
        summaries.removeAll()
        reply = nil
        problem = nil
        snapshot = timestamp
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    func analyze(_ assessment: BatchAssessment, library: Library, model: String, timestamp: Date, usageID: UUID) {
        cancel()
        snapshot = timestamp
        runID = usageID
        problem = nil
        reply = nil
        summaries.removeAll()
        progress = "Reading local changes…"
        task = Task {
            defer { if !Task.isCancelled { progress = nil; task = nil } }
            let session = OllamaLocal.makeSession()
            defer { session.invalidateAndCancel() }
            var useModel = !model.isEmpty
            for (index, item) in assessment.items.enumerated() {
                guard !Task.isCancelled, library.overview?.measuredAt == timestamp else { return }
                let row = item.row
                progress = "Summarizing worktree \(index + 1) of \(assessment.items.count)…"
                let worker = Task.detached(priority: .utility) {
                    try Inventory.changeEvidence(repo: row.projectID, checkout: row.tree)
                }
                do {
                    let evidence = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                         onCancel: { worker.cancel() })
                    try Task.checkCancellation()
                    summaries[row.id] = evidence.gitSummary
                    if useModel && evidence.hasChanges {
                        do {
                            let payload = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
                            let summary = try await OllamaLocal.summarizeChanges(evidence: payload, model: model, session: session, usageID: usageID)
                            try Task.checkCancellation()
                            summaries[row.id] = summary
                        } catch {
                            if Task.isCancelled { return }
                            problem = "Local model explanation unavailable. Showing Git change details. " + error.localizedDescription
                            useModel = false
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    summaries[row.id] = "Change summary unavailable. " + error.localizedDescription
                }
            }
            guard useModel, !Task.isCancelled, library.overview?.measuredAt == timestamp else { return }
            progress = "Analyzing cleanup with Ollama…"
            do {
                let answer = try await AIClient.analyze(provider: .ollama, model: model, key: "", evidence: assessment.payload, usageID: usageID)
                try Task.checkCancellation()
                guard library.overview?.measuredAt == timestamp else { return }
                let suggestions = try BatchSuggestions.read(answer, matching: assessment)
                reply = suggestions.summary
                library.saveAdvice(suggestions.advice, measuredAt: timestamp)
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
        }
    }
}

struct AllWorkspacesAnalysisView: View {
    @ObservedObject var library: Library
    @ObservedObject var options: AIOptions
    @ObservedObject var analysis: WorkspaceAnalysisSession
    @ObservedObject private var usage = TokenUsage.shared
    @BatchState private var assessment: BatchAssessment?
    @BatchState private var showEvidence = false
    @BatchState private var problem: String?
    @BatchState private var pendingRemoval: Removal?
    @BatchState private var cleaning: Removal?
    @BatchState private var cleanupStartedAt: Date?
    @BatchState private var priorFailure: UUID?
    @BatchState private var cleanupMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("All workspaces").font(.title2.bold())
                Label("Only on this Mac", systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
            }
            if let snapshot = library.overview, let assessment {
                Text(verbatim: "\(snapshot.workspaces.count) " + (snapshot.workspaces.count == 1 ? "workspace" : "workspaces") + " · \(assessment.items.count) linked " + (assessment.items.count == 1 ? "worktree" : "worktrees") + " · " + snapshot.measuredAt.formatted(date: .omitted, time: .shortened))
                    .font(.callout).foregroundStyle(.secondary)
                if snapshot.partial || !snapshot.activityAvailable {
                    Label("Incomplete scan or process visibility. Check uncertain worktrees before cleanup.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        StudioCaption("Worktree storage")
                        Text((snapshot.partial ? "≥ " : "") + diskSize(snapshot.linkedBytes)).font(.title2.bold().monospacedDigit())
                    }
                    ForEach(["Can remove", "Review required", "Keep"], id: \.self) { verdict in
                        VStack(alignment: .leading) {
                            StudioCaption(verdict)
                            Text(String(assessment.verdictCounts[verdict] ?? 0)).font(.title2.bold().monospacedDigit())
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        StudioCaption("Cleanable estimate")
                        Text(snapshot.activityAvailable ? diskSize(snapshot.cleanableBytes) : "Unknown").font(.title2.bold().monospacedDigit())
                    }
                }.padding(12).background(Studio.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let reply = analysis.reply {
                            Text("Local model explanation").font(.headline)
                            Text(verbatim: reply).textSelection(.enabled)
                            Divider()
                        }
                        if assessment.items.isEmpty {
                            Text("No linked worktrees found in the scanned repositories.").foregroundStyle(.secondary)
                        }
                        ForEach(assessment.items) { item in itemRow(item) }
                        DisclosureGroup(isExpanded: $showEvidence) {
                            Text(verbatim: assessment.payload).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text("Local evidence · \(assessment.shownToModel) of \(assessment.items.count) worktrees")
                        }
                        if assessment.shownToModel < assessment.items.count {
                            Text("Totals cover all worktrees. The model receives details for the first \(assessment.shownToModel) below.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 3).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView(library.workspaces.isEmpty ? "Add a workspace to analyze" : "Waiting for a local scan",
                                       systemImage: "externaldrive")
            }
            if let activity = library.activity {
                HStack {
                    if let progress = library.scanProgress, let completed = progress.completed,
                       let total = progress.total, total > 0 {
                        ProgressView(progress.label, value: Double(completed), total: Double(total))
                    } else {
                        ProgressView().controlSize(.small)
                        Text(library.scanProgress?.label ?? activity).font(.callout)
                    }
                    Spacer()
                    if library.canStop { Button("Stop scan") { library.stop() } }
                }
            }
            if let cleanupMessage { Text(verbatim: cleanupMessage).font(.callout).textSelection(.enabled) }
            if let message = problem ?? analysis.problem ?? (assessment == nil ? library.failure?.text : nil) {
                Text(verbatim: message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            HStack {
                let model = options.model(for: .ollama)
                Text(verbatim: model.isEmpty ? "Local Git checks" : "Ollama · " + model)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let run = usage.runs.last(where: { $0.label == "All workspaces" }) {
                    Text("Last analysis · " + run.total.label)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Studio.accent)
        .onAppear { rebuild() }
        .onChange(of: library.overview?.measuredAt) { _, _ in rebuild() }
        .onChange(of: library.activity) { _, activity in if activity == nil { finishCleanup() } }
    }

    private func itemRow(_ item: BatchAssessment.Item) -> some View {
        let row = item.row
        return VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: row.tree.branch ?? URL(fileURLWithPath: row.tree.path).lastPathComponent)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: URL(fileURLWithPath: row.projectID).lastPathComponent + " · " + (row.detail ?? row.category.title))
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).help(row.tree.path)
                Text(row.bytes.map(diskSize) ?? "Size unknown").font(.callout.monospacedDigit())
            }
            WorktreeChangeCard(summary: analysis.summaries[row.id],
                               clean: row.category == .cleanable ? { prepareCleanup(row) } : nil,
                               busy: library.activity != nil || cleaning != nil)
            Text(verbatim: library.advice(for: row.id) ?? row.category.guidance).font(.callout).textSelection(.enabled)
            if let removal = pendingRemoval, removal.repo == row.projectID, removal.tree.id == row.tree.id {
                RemovalConfirmation(removal: removal, busy: library.activity != nil,
                                    cancel: { pendingRemoval = nil }, confirm: {
                    pendingRemoval = nil
                    cleaning = removal
                    cleanupStartedAt = library.overview?.measuredAt
                    priorFailure = library.failure?.id
                    cleanupMessage = nil
                    library.remove(removal)
                })
            }
        }
    }

    private func prepareCleanup(_ row: CleanupRow) {
        let project = library.workspaces.lazy.flatMap(\.projects).first { $0.id == row.projectID }
        guard let project, project.trees.contains(row.tree), let current = project.inspections[row.tree.id],
              current.reason == nil else {
            cleanupMessage = "The local inspection changed. Analyze again before removing this checkout."
            return
        }
        pendingRemoval = Removal(repo: row.projectID, tree: row.tree, generatedFolders: current.generatedFolders)
    }

    private func finishCleanup() {
        guard let removal = cleaning else { return }
        cleaning = nil
        let newFailure = library.failure.flatMap { $0.id != priorFailure ? $0.text : nil }
        if let newFailure {
            cleanupMessage = newFailure
        } else if library.workspaces.lazy.flatMap(\.projects).first(where: { $0.id == removal.repo })?.trees.contains(where: { $0.id == removal.tree.id }) == false {
            cleanupMessage = "Removed " + removal.tree.path + ". Its branch was kept."
        } else {
            cleanupMessage = "Removal could not be confirmed. Check the refreshed repository status."
        }
        if library.overview == nil || library.overview?.measuredAt == cleanupStartedAt { library.scanAll() }
    }

    private func rebuild() {
        problem = nil
        do { assessment = try library.overview.map(BatchAssessment.init) }
        catch { assessment = nil; problem = error.localizedDescription }
    }


}

struct RemovalConfirmation: View {
    let removal: Removal
    let busy: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Permanently remove this checkout?").font(.headline)
            Text(verbatim: removal.tree.path).font(.callout.monospaced()).textSelection(.enabled)
            Text("Keep branch " + (removal.tree.branch ?? "") + ". Close sessions using this folder first.").font(.callout)
            if !removal.generatedFolders.isEmpty {
                Text("Also removes").font(.callout.bold())
                ForEach(removal.generatedFolders, id: \.self) { Text(verbatim: $0).font(.caption.monospaced()) }
            }
            HStack {
                Button("Cancel", action: cancel)
                Button("Remove Worktree", role: .destructive, action: confirm).disabled(busy)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
