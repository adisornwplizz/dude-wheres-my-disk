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

struct AllWorkspacesAnalysisView: View {
    @ObservedObject var library: Library
    @ObservedObject var options: AIOptions
    @Environment(\.dismiss) private var dismiss
    @BatchState private var assessment: BatchAssessment?
    @BatchState private var didAppear = false
    @BatchState private var didStart = false
    @BatchState private var pendingLocalModel: String?
    @BatchState private var showSettings = false
    @BatchState private var showEvidence = false
    @BatchState private var reply: String?
    @BatchState private var problem: String?
    @BatchState private var request: Task<Void, Never>?
    @BatchState private var requestID: UUID?
    @BatchState private var pendingRemoval: Removal?
    @BatchState private var cleaning: Removal?
    @BatchState private var cleanupStartedAt: Date?
    @BatchState private var priorFailure: UUID?
    @BatchState private var cleanupMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Analyze All Workspaces").font(.title2.bold())
                Spacer()
                Button("Refresh all") { library.scanAll() }
                    .disabled(library.activity != nil || request != nil || library.workspaces.isEmpty)
            }
            if let snapshot = library.overview, let assessment {
                Text("\(snapshot.workspaces.count) workspaces · \(assessment.items.count) linked worktrees · \(snapshot.measuredAt.formatted(date: .omitted, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
                if snapshot.partial || !snapshot.activityAvailable {
                    Label("Incomplete scan or process visibility. Check uncertain worktrees before cleanup.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 22) {
                    ForEach(["Can remove", "Review required", "Keep"], id: \.self) { verdict in
                        VStack(alignment: .leading) {
                            StudioCaption(verdict)
                            Text(String(assessment.verdictCounts[verdict] ?? 0)).font(.title2.bold().monospacedDigit())
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        StudioCaption("Cleanable estimate")
                        Text(snapshot.activityAvailable ? snapshot.cleanableBytes.formatted(.byteCount(style: .file)) : "Unknown").font(.title2.bold().monospacedDigit())
                    }
                }.padding(12).background(Studio.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let reply {
                            Text(options.provider == .ollama ? "Local model explanation" : "Provider explanation").font(.headline)
                            Text(verbatim: reply).textSelection(.enabled)
                            Divider()
                        }
                        DisclosureGroup(isExpanded: $showEvidence) {
                            Text(verbatim: assessment.payload).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text("Preview evidence · \(assessment.shownToModel) of \(assessment.items.count) worktrees")
                        }
                        if assessment.shownToModel < assessment.items.count {
                            Text("Totals cover all worktrees. The model receives details for the first \(assessment.shownToModel) below.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if assessment.items.isEmpty {
                            Text("No linked worktrees found in the scanned repositories.").foregroundStyle(.secondary)
                        }
                        ForEach(assessment.items) { item in itemRow(item) }
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
                    if library.canStop { Button("Stop scan") { pendingLocalModel = nil; library.stop() } }
                }
            }
            if let cleanupMessage { Text(verbatim: cleanupMessage).font(.callout).textSelection(.enabled) }
            if let message = problem ?? (assessment == nil ? library.failure?.text : nil) {
                Text(verbatim: message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            HStack {
                Text(verbatim: [options.provider.title, options.model(for: options.provider)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).lineLimit(1)
                Button("AI Settings…") { pendingLocalModel = nil; showSettings = true }.disabled(request != nil)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if request != nil {
                    ProgressView().controlSize(.small)
                    Text("Analyzing all workspaces…").font(.callout)
                    Button("Cancel") { resetRequest() }
                } else {
                    Button(options.provider == .ollama ? "Analyze locally" : "Send to " + options.provider.title) { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(assessment?.items.isEmpty != false || library.activity != nil || options.model(for: options.provider).isEmpty)
                }
            }
        }
        .padding(20).frame(minWidth: 620, idealWidth: 690, minHeight: 440, idealHeight: 585)
        .tint(Studio.accent)
        .sheet(isPresented: $showSettings, onDismiss: resetRequest) { AISettingsView(options: options) }
        .sheet(item: $pendingRemoval) { removal in
            VStack(alignment: .leading, spacing: 12) {
                Text("Permanently remove worktree?").font(.title2.bold())
                Text(verbatim: removal.tree.path).font(.callout.monospaced()).textSelection(.enabled)
                Text(verbatim: "Keep branch " + (removal.tree.branch ?? "") + ". Close sessions using this checkout first.")
                if !removal.generatedFolders.isEmpty {
                    Text("Included generated items").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(removal.generatedFolders, id: \.self) { Text(verbatim: $0).font(.caption.monospaced()) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { pendingRemoval = nil }.keyboardShortcut(.cancelAction)
                    Button("Remove Worktree", role: .destructive) {
                        pendingRemoval = nil
                        guard library.activity == nil else { return }
                        cleaning = removal
                        cleanupStartedAt = library.overview?.measuredAt
                        priorFailure = library.failure?.id
                        cleanupMessage = nil
                        pendingLocalModel = nil
                        library.remove(removal)
                    }.disabled(library.activity != nil)
                }
            }.padding(22).frame(width: 480)
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            let model = options.model(for: .ollama)
            if options.provider == .ollama && !model.isEmpty { pendingLocalModel = model }
            rebuild()
            continueOnOpen()
        }
        .onChange(of: library.overview?.measuredAt) { _, _ in rebuild(); continueOnOpen() }
        .onChange(of: library.activity) { _, activity in
            if activity == nil { finishCleanup(); continueOnOpen() }
        }
        .onDisappear { pendingLocalModel = nil; resetRequest() }
    }

    private func continueOnOpen() {
        guard didAppear, !showSettings, library.activity == nil, !library.workspaces.isEmpty else { return }
        let fresh = library.overview.map { Date().timeIntervalSince($0.measuredAt) < 300 } ?? false
        if !didStart {
            didStart = true
            if !fresh {
                library.scanAll()
                return
            }
        }
        guard fresh, let model = pendingLocalModel, assessment?.items.isEmpty == false,
              options.provider == .ollama, options.model(for: .ollama) == model else { return }
        pendingLocalModel = nil
        send()
    }

    private func itemRow(_ item: BatchAssessment.Item) -> some View {
        let row = item.row
        return VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text(item.id).font(.caption.monospaced()).foregroundStyle(Studio.accent)
                Text(verbatim: row.tree.branch ?? URL(fileURLWithPath: row.tree.path).lastPathComponent)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(row.bytes?.formatted(.byteCount(style: .file)) ?? "Size unknown").font(.callout.monospacedDigit())
                if row.category == .cleanable {
                    Button("Clean…") { prepareCleanup(row) }
                        .disabled(library.activity != nil || request != nil || cleaning != nil)
                }
            }
            Text(verbatim: URL(fileURLWithPath: row.projectID).lastPathComponent + " · " + row.tree.path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(verbatim: row.category.assessmentVerdict + " · " + (row.detail ?? row.category.title)).font(.callout.weight(.medium))
            Text(verbatim: row.category.guidance).font(.callout)
            if let advice = library.advice(for: row.id) {
                Text(verbatim: "Model suggestion · " + advice).font(.callout).foregroundStyle(.secondary)
            }
            if row.nestedCount > 0 || row.parentPath != nil {
                Text("Nested checkout sizes can overlap. Review child folders first.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func prepareCleanup(_ row: CleanupRow) {
        let project = library.workspaces.lazy.flatMap(\.projects).first { $0.id == row.projectID }
        guard let project, project.trees.contains(row.tree), let current = project.inspections[row.tree.id],
              current.reason == nil else {
            cleanupMessage = "The local inspection changed. Refresh all workspaces before removing this checkout."
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
        resetRequest()
        do { assessment = try library.overview.map(BatchAssessment.init) }
        catch { assessment = nil; problem = error.localizedDescription }
    }

    private func resetRequest() {
        request?.cancel()
        request = nil
        requestID = nil
        reply = nil
        problem = nil
    }

    @MainActor private func send() {
        guard request == nil, let assessment, let timestamp = library.overview?.measuredAt else { return }
        let provider = options.provider
        let model = options.model(for: provider)
        let id = UUID()
        requestID = id
        reply = nil
        problem = nil
        request = Task {
            defer { if requestID == id { request = nil } }
            do {
                var key = ""
                if provider.requiresKey {
                    guard let saved = try ProviderKeys.read(provider), !saved.isEmpty else {
                        problem = "Add a key for " + provider.title + " in AI Settings."
                        return
                    }
                    key = saved
                }
                let answer = try await AIClient.analyze(provider: provider, model: model, key: key, evidence: assessment.payload)
                try Task.checkCancellation()
                guard requestID == id, library.overview?.measuredAt == timestamp else { return }
                do {
                    let suggestions = try BatchSuggestions.read(answer, matching: assessment)
                    reply = suggestions.summary
                    library.saveAdvice(suggestions.advice, measuredAt: timestamp)
                } catch {
                    problem = "The model returned an unreadable batch report. Local recommendations remain available. Retry to request the report again."
                }
            } catch {
                if !Task.isCancelled && requestID == id { problem = error.localizedDescription }
            }
        }
    }
}
