import SwiftUI

enum Studio {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.59, blue: 0.29, alpha: 1)
            : NSColor(red: 0.69, green: 0.24, blue: 0.035, alpha: 1)
    })
    static let rail = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let rule = Color(nsColor: .separatorColor).opacity(0.68)
}

struct StudioCaption: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label.uppercased()).font(.system(size: 10, weight: .semibold))
            .tracking(1.4).foregroundStyle(.secondary)
    }
}

struct StudioMasthead: View {
    let settings: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 36, height: 36)
                .accessibilityHidden(true)
            Text("Dude, Where’s My \(Text("Disk?").foregroundColor(Studio.accent))")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.9)
            Spacer()
            Button(action: settings) { Label("AI Settings…", systemImage: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .font(.callout.weight(.medium))
                .help("Configure an optional AI provider")
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
