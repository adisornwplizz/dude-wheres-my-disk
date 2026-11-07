import AppKit
import SwiftUI

private typealias PanelState<Value> = State<Value>

struct MenuBarDashboard: View {
    @ObservedObject var library: Library
    let showLibrary: () -> Void
    let analyze: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    PopoverMascot(busy: library.activity != nil)
                        .frame(width: 26, height: 26).accessibilityHidden(true)
                    StudioCaption("Linked worktree storage")
                    Spacer()
                    Button { library.scanAll() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Scan all workspaces")
                        .accessibilityLabel("Scan all workspaces")
                        .disabled(library.workspaces.isEmpty || library.activity != nil)
                }
                if let snapshot = library.overview {
                    Text((snapshot.partial ? "≥ " : "") + diskSize(snapshot.linkedBytes))
                        .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    HStack {
                        Text("\(snapshot.linkedCount) worktrees")
                        Text("·")
                        Text("\(snapshot.cleanableCount) cleanable")
                        Text("·")
                        Text(snapshot.activityAvailable ? "\(snapshot.inUseCount) in use" : "Activity unknown")
                    }.font(.caption).foregroundStyle(.secondary)
                    Text((snapshot.partial ? "Partial scan · " : "Scanned ") +
                         snapshot.measuredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("—").font(.title.bold())
                    Text(library.workspaces.isEmpty ? "Add a workspace to measure linked worktrees." : "Waiting for a workspace scan.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let activity = library.activity {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(activity).lineLimit(2)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(15)
            if let snapshot = library.overview, !snapshot.workspaces.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.workspaces) { item in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(Studio.accent)
                                Text(item.name).lineLimit(1).truncationMode(.middle).help(item.id)
                                Spacer()
                                Text((item.partial ? "≥ " : "") + diskSize(item.linkedBytes)).monospacedDigit()
                            }.font(.callout)
                        }
                    }.padding(.horizontal, 15).padding(.vertical, 9)
                }
                .frame(height: min(170, CGFloat(snapshot.workspaces.count) * 24 + 18))
            }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                action("Analyze All Workspaces…", "square.stack.3d.up", analyze)
                    .disabled(library.workspaces.isEmpty)
                action("Open App", "macwindow", showLibrary)
                action("Settings…", "gearshape", settings)
                Divider().padding(.vertical, 3)
                action("Quit Dude, Where’s My Disk?", "power") { NSApp.terminate(nil) }
            }.padding(8)
        }
        .frame(width: 340)
        .tint(Studio.accent)
    }

    private func action(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct PopoverMascot: View {
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PanelState private var index = 0

    private static let size = NSSize(width: 26, height: 26)
    private static let idle = MascotFrame.load("DiskBuddy", size: size, template: false)
    private static let working = MascotFrame.load("DiskBuddyScan", size: size, template: false)

    var body: some View {
        let frames = busy ? Self.working : Self.idle
        let frame = frames.indices.contains(index) ? frames[index] : frames.first
        Image(nsImage: frame?.image ?? NSApp.applicationIconImage)
            .resizable().scaledToFit().frame(width: 26, height: 26).clipped()
            .task(id: [busy, reduceMotion]) {
                index = 0
                guard !reduceMotion, frames.count > 1 else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(frames[index].delay)) }
                    catch { return }
                    index = (index + 1) % frames.count
                }
            }
    }
}

struct MonitorSettings: View {
    @ObservedObject var library: Library
    @ObservedObject var options: AIOptions
    @PanelState private var showAI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background monitoring").font(.title2.bold())
            Picker("Refresh interval", selection: $library.refreshMinutes) {
                Text("Manual only").tag(0)
                Text("Every 5 minutes").tag(5)
                Text("Every 15 minutes").tag(15)
                Text("Every 30 minutes").tag(30)
                Text("Every hour").tag(60)
            }
            Text("Selected workspaces are remembered on this Mac. Background scans check their linked worktrees while the app is running.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Label("Workspace analysis runs on this Mac", systemImage: "lock.shield")
                .font(.headline)
            Toggle("Allow cloud for individual worktrees", isOn: $options.allowSingleWorktreeCloud)
            if options.allowSingleWorktreeCloud {
                Text("Individual worktrees can send a previewed report when you choose Send. Analyze All always stays local.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text(options.allowSingleWorktreeCloud ? "Single-worktree provider" : "Local model")
                Spacer()
                Text(options.allowSingleWorktreeCloud ? options.provider.title : options.model(for: .ollama)).lineLimit(1).foregroundStyle(.secondary)
                Button("Configure…") { showAI = true }
            }
        }
        .padding(20).frame(width: 420)
        .tint(Studio.accent)
        .sheet(isPresented: $showAI) { AISettingsView(options: options) }
    }
}
