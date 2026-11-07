import SwiftUI

private typealias AIState<Value> = State<Value>

@MainActor
final class AIOptions: ObservableObject {
    @Published private var selectedProvider: AIProvider
    @Published var allowSingleWorktreeCloud: Bool {
        didSet { defaults.set(allowSingleWorktreeCloud, forKey: "ai.allowSingleWorktreeCloud") }
    }
    var provider: AIProvider { allowSingleWorktreeCloud ? selectedProvider : .ollama }
    @Published private var models: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        allowSingleWorktreeCloud = defaults.bool(forKey: "ai.allowSingleWorktreeCloud")
        selectedProvider = defaults.string(forKey: "ai.provider").flatMap(AIProvider.init(rawValue:)) ?? .ollama
        models = defaults.dictionary(forKey: "ai.models") as? [String: String] ?? [:]
    }

    func model(for provider: AIProvider) -> String {
        models[provider.rawValue] ?? provider.defaultModel
    }

    func save(provider: AIProvider, model: String) {
        models[provider.rawValue] = model
        defaults.set(models, forKey: "ai.models")
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: "ai.provider")
    }
}

struct AISettingsView: View {
    @ObservedObject var options: AIOptions
    @Environment(\.dismiss) private var dismiss
    @AIState private var provider: AIProvider

    init(options: AIOptions) {
        self.options = options
        _provider = State(initialValue: options.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Analysis models").font(.title2.bold())
            if options.allowSingleWorktreeCloud {
                Picker("Single-worktree provider", selection: $provider) {
                    ForEach(AIProvider.allCases) { item in Text(item.title).tag(item) }
                }
            }
            AIConnectionForm(options: options, provider: provider, close: { dismiss() }).id(provider)
        }
        .padding(22).frame(width: 490).tint(Studio.accent)
    }
}

private struct AIConnectionForm: View {
    @ObservedObject var options: AIOptions
    let provider: AIProvider
    let close: () -> Void
    @AIState private var model: String
    @AIState private var names: [String]?
    @AIState private var keyDraft = ""
    @AIState private var hasKey = false
    @AIState private var custom = false
    @AIState private var message: String?
    @AIState private var connection: Task<Void, Never>?

    init(options: AIOptions, provider: AIProvider, close: @escaping () -> Void) {
        self.options = options
        self.provider = provider
        self.close = close
        _model = State(initialValue: options.model(for: provider))
    }

    private var local: Bool { provider == .ollama }
    private var token: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modelID: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        if connection != nil || modelID.isEmpty { return false }
        if local { return names?.contains(modelID) == true }
        return hasKey || !token.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label(local ? "On this Mac" : "Cloud provider", systemImage: local ? "lock.shield" : "cloud")
                    .font(.headline).foregroundStyle(Studio.accent)
                if local {
                    Text("http://127.0.0.1:11434").font(.callout.monospaced()).textSelection(.enabled)
                    Text("Connect to discover installed chat models. Analysis runs through Ollama on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Connect to list models on your account. You can preview the cleanup facts before sending them to this provider.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            if !local {
                Text("API key").font(.headline)
                SecureField(hasKey ? "Enter replacement key" : "Enter API key", text: $keyDraft)
                    .accessibilityLabel("API key for " + provider.title).disabled(connection != nil)
                    .onChange(of: keyDraft) { _, _ in names = nil; message = nil }
                HStack {
                    Text(hasKey ? "Key saved in macOS Keychain." : "Save stores this key in macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if hasKey {
                        Button("Remove Key", role: .destructive) { removeKey() }
                            .disabled(connection != nil)
                    }
                }
            }

            HStack {
                Button(names == nil ? "Connect" : "Reconnect", action: connect)
                    .disabled(connection != nil || (!local && !hasKey && token.isEmpty))
                if connection != nil { ProgressView().controlSize(.small) }
                else if let names {
                    Text("Connected · " + String(names.count) + (names.count == 1 ? " model" : " models"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let names, !names.isEmpty {
                if !custom {
                    Picker("Model", selection: $model) {
                        ForEach(names, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                }
                if !local {
                    Toggle("Enter a model ID manually", isOn: $custom)
                        .onChange(of: custom) { _, manual in
                            if !manual && !names.contains(model) { model = names[0] }
                        }
                }
            } else if names?.isEmpty == true {
                Text(local ? "Ollama returned no installed local chat models. Install one in Ollama and reconnect."
                           : "This provider returned no models for this key.").font(.callout).foregroundStyle(.secondary)
            } else if local && !modelID.isEmpty {
                LabeledContent("Saved model") { Text(verbatim: model).font(.callout.monospaced()) }
            }
            if !local && (names?.isEmpty != false || custom) {
                TextField("Model ID", text: $model, prompt: Text(provider.defaultModel))
            }
            if let message { Text(verbatim: message).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.borderedProminent)
                    .disabled(!canSave).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard !local else { return }
            do { hasKey = try ProviderKeys.exists(provider) }
            catch { message = error.localizedDescription }
        }
        .onDisappear { connection?.cancel() }
    }

    @MainActor private func connect() {
        guard connection == nil else { return }
        message = nil
        connection = Task {
            defer { connection = nil }
            do {
                var key = ""
                if !local {
                    if token.isEmpty { key = try ProviderKeys.read(provider) ?? "" }
                    else { key = token }
                }
                let list = try await AIClient.listModels(provider: provider, key: key)
                try Task.checkCancellation()
                names = list
                custom = false
                if !list.contains(model) { model = list.first ?? (local ? "" : provider.defaultModel) }
            } catch {
                guard !Task.isCancelled else { return }
                names = nil
                message = local ? "Check that Ollama is running on this Mac. " + error.localizedDescription
                                : error.localizedDescription
            }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            if !local && !token.isEmpty { try ProviderKeys.save(token, for: provider) }
            options.save(provider: provider, model: modelID)
            keyDraft = ""
            close()
        } catch { message = error.localizedDescription }
    }

    private func removeKey() {
        do {
            try ProviderKeys.remove(provider)
            keyDraft = ""
            hasKey = false
            names = nil
            message = nil
        } catch { message = error.localizedDescription }
    }
}

struct AnalysisTarget: Identifiable {
    let repo: String
    let tree: Checkout
    let id = UUID()
}

struct AIAnalysisView: View {
    let target: AnalysisTarget
    @ObservedObject var options: AIOptions
    let close: () -> Void
    @AIState private var evidence: CleanupEvidence?
    @AIState private var errorMessage: String?
    @AIState private var reply: String?
    @AIState private var request: Task<Void, Never>?
    @AIState private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analyze worktree").font(.title2.bold())
            Text(verbatim: target.tree.path).font(.caption.monospaced()).textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let evidence {
                        Text("Local assessment").font(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: evidence.verdict).font(.title3.bold())
                        Text(verbatim: evidence.localExplanation).textSelection(.enabled)
                        Divider()
                        Text(options.provider == .ollama ? "Evidence for local model" : "Evidence to send").font(.headline)
                        Text(verbatim: evidence.payload).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    } else if errorMessage == nil {
                        ProgressView("Checking Git and process activity…").controlSize(.small)
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let reply {
                        Divider()
                        Text(options.provider == .ollama ? "Local model explanation" : "Provider explanation").font(.headline)
                        Text(verbatim: reply).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if options.provider == .ollama && options.model(for: .ollama).isEmpty {
                Text("Connect to Ollama in Settings and save a model to get a local explanation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text(verbatim: [options.provider.title, options.model(for: options.provider)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            HStack {
                Button("Recheck") { clearReview() }.disabled(request != nil || (evidence == nil && errorMessage == nil))
                Spacer()
                Button("Back", action: close).keyboardShortcut(.cancelAction)
                if request != nil { ProgressView().controlSize(.small) }
                Button(options.provider == .ollama ? "Analyze locally" : "Send to " + options.provider.title) { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(request != nil || evidence == nil || options.model(for: options.provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: options.provider) { _, _ in
            request?.cancel()
            reply = nil
        }
        .task(id: generation) { await check() }
        .onDisappear { request?.cancel() }
    }

    private func clearReview() {
        evidence = nil
        reply = nil
        errorMessage = nil
        generation += 1
    }

    @MainActor private func check() async {
        let worker = Task.detached(priority: .userInitiated) { [target] in
            try Inventory.analysis(repo: target.repo, checkout: target.tree)
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                               onCancel: { worker.cancel() })
            try Task.checkCancellation()
            evidence = result
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    @MainActor private func send() {
        guard let evidence, request == nil else { return }
        let provider = options.provider
        let model = options.model(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        reply = nil
        errorMessage = nil
        request = Task {
            defer { request = nil }
            do {
                var key = ""
                if provider != .ollama {
                    guard let saved = try ProviderKeys.read(provider), !saved.isEmpty else {
                        errorMessage = "Open Settings to add a key for " + provider.title + "."
                        return
                    }
                    key = saved
                }
                try Task.checkCancellation()
                let run = TokenUsage.shared.begin(provider.title + " · Worktree report")
                let answer = try await AIClient.analyze(provider: provider, model: model, key: key, evidence: evidence.payload, usageID: run)
                try Task.checkCancellation()
                reply = answer
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}
