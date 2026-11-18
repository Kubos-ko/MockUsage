import AppKit
import SwiftUI
import Combine
#if SWIFT_PACKAGE
import UsageCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var menuBar: MenuBarController?
    private var fallbackWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        UsageStore.shared.start()
        menuBar = MenuBarController(store: UsageStore.shared)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard(); return true
    }
    func showDashboard() {
        if let window = NSApp.windows.first(where: { $0.title == "Mock Usage" && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            let controller = NSHostingController(rootView: MainView(compact: false).environmentObject(UsageStore.shared))
            let window = NSWindow(contentViewController: controller)
            window.title = "Mock Usage"
            window.setContentSize(NSSize(width: 620, height: 800))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            fallbackWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var tracking: NSTrackingArea?
    private var hoverTimer: Timer?
    private var keyMonitor: Any?
    private var outsideLocalMonitor: Any?
    private var outsideGlobalMonitor: Any?
    private var pinned = false
    private var shownAt = Date.distantPast

    init(store: UsageStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.contentViewController = NSHostingController(rootView: MainView(compact: true).environmentObject(store))
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if let button = item.button {
            button.target = self; button.action = #selector(clicked)
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Mock Usage")
            button.imagePosition = .imageLeading
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            button.addTrackingArea(area); tracking = area
        }
        update()
        observation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            self?.dismissIfOutside(point)
            return event
        }
        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.dismissIfOutside(NSEvent.mouseLocation)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command),
                  NSApp.keyWindow?.title == "Mock Usage" || self.popover.isShown else { return event }
            switch event.charactersIgnoringModifiers {
            case "+", "=": self.store.changeZoom(0.1); return nil
            case "-": self.store.changeZoom(-0.1); return nil
            case "0": self.store.resetZoom(); return nil
            default: return event
            }
        }
    }
    private func update() {
        let screen = item.button?.window?.screen ?? NSScreen.main
        let limit = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        // Reserve at most 22% of the display; the OS still owns overall menu bar placement.
        let capacity = max(1, min(DisplaySelection.menuMaximum, Int(limit.width * 0.22 / 72)))
        let accounts = store.menuAccounts(limit: capacity)
        let title = store.menuTitle(for: accounts)
        item.button?.title = " " + (title.isEmpty ? "Mock Usage" : title)
        let meters = accounts.map { account -> (Double?, NSColor) in
            let fresh = account.state.isLive && (account.state.snapshot.map { Date().timeIntervalSince($0.capturedDate) < 900 } ?? false)
            return (account.state.snapshot?.mostUsed, fresh ? (account.provider == .gptmock ? .systemMint : .systemOrange) : .systemGray)
        }
        if !meters.isEmpty {
            // A drawing-handler image is rendered at the screen's native scale.
            // Non-template rendering preserves provider colors in the menu bar.
            let image = NSImage(size: NSSize(width: meters.count * 11, height: 18), flipped: false) { _ in
                for (index, meter) in meters.enumerated() {
                    let rect = NSRect(x: index * 11 + 1, y: 1, width: 7, height: 16)
                    NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                    if let value = meter.0 {
                        let height = 16 * min(100, max(0, value)) / 100
                        meter.1.setFill()
                        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height), xRadius: min(2, height / 2), yRadius: min(2, height / 2)).fill()
                    }
                }
                return true
            }
            image.isTemplate = false
            item.button?.image = image
        } else {
            item.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Mock Usage")
        }
        item.button?.toolTip = accounts.map(\.name).joined(separator: " · ") + " — Mint: GPTMock; orange: Claude; gray or a dot after the percentage: last known reading (refresh failed or older than 15 minutes). Choose accounts in Settings."
        item.button?.setAccessibilityLabel("Mock Usage " + title)
        // Text is laid out at its actual point size, never scaled as a bitmap.
        popover.contentSize = NSSize(width: min(430 + max(0, store.configuration.zoom - 1) * 150, limit.width - 40),
                                     height: min(680, limit.height - 50))
    }
    private func dismissIfOutside(_ point: NSPoint) {
        guard popover.isShown else { return }
        if let window = popover.contentViewController?.view.window, window.frame.contains(point) { return }
        if let button = item.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
        popover.performClose(nil)
    }

    @objc private func clicked() {
        if popover.isShown && pinned { popover.performClose(nil) }
        else { pinned = true; show() }
    }
    @objc func mouseEntered(with event: NSEvent) {
        guard store.configuration.hoverPreview, !popover.isShown else { return }
        pinned = false; show()
    }
    @objc func mouseExited(with event: NSEvent) {}

    private func show() {
        guard let button = item.button else { return }
        update()
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        shownAt = Date()
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
    }
    private func checkPointer() {
        guard popover.isShown, !pinned, Date().timeIntervalSince(shownAt) > 0.6 else { return }
        let point = NSEvent.mouseLocation
        if let window = item.button?.window, window.frame.insetBy(dx: -8, dy: -8).contains(point) { return }
        if let window = popover.contentViewController?.view.window, window.frame.insetBy(dx: -12, dy: -12).contains(point) { return }
        popover.performClose(nil)
    }
    func popoverDidClose(_ notification: Notification) {
        pinned = false; hoverTimer?.invalidate(); hoverTimer = nil
    }
}
