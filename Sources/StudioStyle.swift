import SwiftUI

func diskSize(_ bytes: Int64) -> String {
    bytes == 0 ? "0 B" : bytes.formatted(.byteCount(style: .file))
}

enum Studio {
    static let navigationHeaderHeight: CGFloat = 40

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.59, blue: 0.29, alpha: 1)
            : NSColor(red: 0.69, green: 0.24, blue: 0.035, alpha: 1)
    })
    static let rail = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let rule = Color(nsColor: .separatorColor).opacity(0.68)
}

struct AnalyzeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Studio.accent, in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

struct StudioCaption: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label.uppercased()).font(.system(size: 10, weight: .semibold))
            .tracking(1.4).foregroundStyle(.secondary)
    }
}

struct StudioMasthead<Action: View>: View {
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 36, height: 36)
                .accessibilityHidden(true)
            Text("Dude, Where’s My \(Text("Disk?").foregroundColor(Studio.accent))")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.9)
            Spacer()
            action()
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Studio.canvas)
    }
}

private struct DiskStack: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Studio.accent.opacity(0.10)).frame(width: 132, height: 132)
            Circle().strokeBorder(Studio.accent.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                .frame(width: 108, height: 108)
            VStack(spacing: 4) {
                ForEach(0..<3) { row in
                    HStack(spacing: 4) {
                        Circle().fill(Studio.accent).frame(width: 4, height: 4)
                        Capsule().fill(Studio.accent.opacity(0.32)).frame(width: 15, height: 3)
                        Spacer()
                        ForEach(0..<3) { _ in
                            Capsule().fill(Studio.accent.opacity(0.45)).frame(width: 2, height: 7)
                        }
                    }
                    .padding(.horizontal, 8).frame(width: 71, height: 16)
                    .background(Studio.accent.opacity(0.09 + Double(row) * 0.035), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Studio.accent.opacity(0.75), lineWidth: 1.2))
                }
            }
        }.accessibilityHidden(true)
    }
}

struct StudioWelcome: View {
    let add: () -> Void
    let busy: Bool
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            DiskStack()
            Text("Choose a workspace").font(.system(size: 32, weight: .bold)).tracking(-1.3)
                .padding(.top, 14)
            Text("Open a project folder to see which Git worktrees use your disk.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 9)
            Button(action: add) { Label("Add Workspace…", systemImage: "folder.badge.plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(busy).padding(.top, 20)
            Spacer(minLength: 22)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Studio.accent.opacity(0.11), Studio.canvas, Studio.accent.opacity(0.035)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Studio.rule))
        .padding(24)
    }
}

struct SidebarTokenCard: View {
    @ObservedObject var usage: TokenUsage

    var body: some View {
        TimelineView(.everyMinute) { context in
            let today = usage.daily(context.date)
            let total = today.input + today.output
            let lifetime = usage.total
            VStack(alignment: .leading, spacing: 6) {
                StudioCaption("Token usage")
                Text((today.estimated ? "≈ " : "") + total.formatted() + " today")
                    .font(.headline.monospacedDigit())
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(total == 0 ? Studio.rule : Color.secondary.opacity(0.45))
                        if total > 0 {
                            Rectangle().fill(Studio.accent)
                                .frame(width: proxy.size.width * CGFloat(today.input) / CGFloat(total))
                        }
                    }.clipShape(Capsule())
                }.frame(height: 5).accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { legend(today.input, "in", Studio.accent); legend(today.output, "out", .secondary) }
                    VStack(alignment: .leading, spacing: 2) { legend(today.input, "in", Studio.accent); legend(today.output, "out", .secondary) }
                }
                Text("All time · " + (lifetime.estimated ? "≈ " : "") + (lifetime.input + lifetime.output).formatted())
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .help("Today’s input and output as a share of today’s tokens. ≈ marks estimated usage.")
        }
    }

    private func legend(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(count.formatted() + " " + label).font(.caption.monospacedDigit()).fixedSize()
        }
    }
}

struct CleanStatus: View {
    let category: CleanupCategory?
    let reason: String?
    let merge: MergeEvidence

    var body: some View {
        let ready = category == .cleanable
        VStack(alignment: .leading, spacing: 3) {
            Label(ready ? "Ready to clean" : (category == nil ? "Awaiting scan" : "Cannot clean yet"),
                  systemImage: ready ? "checkmark.circle.fill" : "info.circle")
                .font(.callout.weight(.semibold)).foregroundStyle(ready ? Studio.accent : .primary)
            Text(verbatim: [merge.label, reason].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct WorktreeChangeCard: View {
    let description: TaskDescription
    let nextStep: String?
    let removal: Removal?
    let clean: (Removal) -> Void
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Task description").font(.callout.weight(.semibold))
            Text(verbatim: description.text).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let nextStep {
                Text("Model suggestion").font(.caption.weight(.semibold)).padding(.top, 3)
                Text(verbatim: nextStep).font(.callout).textSelection(.enabled)
            }
            Text(verbatim: description.source).font(.caption).foregroundStyle(.secondary)
            if let removal {
                Divider().padding(.vertical, 3)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Reclaim about " + diskSize(removal.reclaimableBytes)).font(.callout.weight(.semibold))
                        Text(verbatim: "Keep local branch " + confirmationName(removal.branch)).font(.callout).textSelection(.enabled)
                    }
                    Spacer(minLength: 6)
                    Button("Clean…") { clean(removal) }.buttonStyle(.borderedProminent).disabled(busy)
                }
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
