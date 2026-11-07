import AppKit
import Combine
import ImageIO
import SwiftUI

private struct MascotFrame {
    let image: NSImage
    let delay: TimeInterval

    static func load(_ name: String) -> [MascotFrame] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            guard let bitmap = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 1.0
            let image = NSImage(cgImage: bitmap, size: NSSize(width: 19, height: 18))
            image.isTemplate = true
            return MascotFrame(image: image, delay: min(30, max(0.12, delay)))
        }
    }
}

@MainActor
final class StatusMonitor: NSObject, ObservableObject {
    @Published var showAllAnalysis = true
    @Published var analysisRequested = false
    private let library: Library
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let idleFrames = MascotFrame.load("MenuBuddy")
    private let busyFrames = MascotFrame.load("MenuBuddyScan")
    private var subscriptions: Set<AnyCancellable> = []
    private var openLibrary: (() -> Void)?
    private var openPreferences: (() -> Void)?
    private var busy = false
    private var frameIndex = 0
    private var timer: Timer?

    init(library: Library) {
        self.library = library
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
        }
        let dashboard = MenuBarDashboard(library: library,
                                         showLibrary: { [weak self] in self?.routeToLibrary(analyze: false) },
                                         analyze: { [weak self] in self?.routeToLibrary(analyze: true) },
                                         settings: { [weak self] in self?.routeToSettings() })
        let host = NSHostingController(rootView: dashboard)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        library.$overview.sink { [weak self] snapshot in
            guard let button = self?.item.button else { return }
            let bytes = snapshot.map { ($0.partial ? "≥" : "") + diskSize($0.linkedBytes) } ?? "—"
            button.title = " " + bytes
            button.toolTip = "Linked worktree storage: " + bytes
            button.setAccessibilityLabel("Linked worktree storage: " + bytes)
        }.store(in: &subscriptions)
        library.$activity.map { $0 != nil }.removeDuplicates().sink { [weak self] working in
            self?.busy = working
            self?.resetAnimation()
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(resetAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    func registerRoutes(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        openLibrary = { openWindow(id: "library") }
        openPreferences = { openSettings() }
    }

    private func routeToLibrary(analyze: Bool) {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let openLibrary {
            openLibrary()
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        }
        if analyze { showAllAnalysis = true; analysisRequested = true }
    }

    private func routeToSettings() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let openPreferences { openPreferences(); return }
        // The system's app menu already owns the Settings scene, including before the first window has appeared.
        if let settings = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        }), let action = settings.action {
            NSApp.sendAction(action, to: settings.target, from: settings)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else { showOverview() }
    }

    func showOverview() {
        guard !popover.isShown else { return }
        if let button = item.button, let window = button.window, window.isVisible, window.screen != nil {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let content = NSApp.keyWindow?.contentView {
            let anchor = NSRect(x: content.bounds.maxX - 26, y: content.bounds.maxY - 12, width: 1, height: 1)
            popover.show(relativeTo: anchor, of: content, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func resetAnimation() {
        timer?.invalidate()
        frameIndex = 0
        drawFrame()
    }

    private func drawFrame() {
        let frames = busy && !busyFrames.isEmpty ? busyFrames : idleFrames
        guard !frames.isEmpty else {
            item.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
            return
        }
        let frame = frames[frameIndex]
        item.button?.image = frame.image
        guard frames.count > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let next = Timer(timeInterval: frame.delay, target: self, selector: #selector(advanceFrame), userInfo: nil, repeats: false)
        next.tolerance = min(frame.delay * 0.15, 0.1)
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    @objc private func advanceFrame() {
        let count = busy && !busyFrames.isEmpty ? busyFrames.count : idleFrames.count
        guard count > 0 else { return }
        frameIndex = (frameIndex + 1) % count
        drawFrame()
    }
}
