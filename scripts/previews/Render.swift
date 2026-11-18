import AppKit
import SwiftUI
import WidgetKit

/// Render the actual SwiftUI views with synthetic data; never start polling.
@main
struct PreviewExport {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = UsageStore(directory: directory)
        store.configuration.appearance = "dark"
        let now = Date().timeIntervalSince1970
        for (index, provider) in [Provider.gptmock, .claude, .claude].enumerated() {
            let source = Source(name: ["GPTMock · Personal", "Claude · Workspace A", "Claude · Workspace B"][index],
                                container: "demo-source-\(index + 1)", provider: provider)
            store.configuration.sources.append(source)
            let json: [String: Any] = ["provider": provider.rawValue, "accountKey": "demo-\(index)",
                "plan": "Demo plan", "capturedAt": now,
                "windows": [["id": "weekly", "title": "Weekly window", "scope": "All models", "usedPercent": [42, 67, 23][index], "resetsAt": now + 7200]],
                "resets": ["state": "unavailable", "message": "Demo data — resets are disabled", "items": []],
                "offers": [], "models": [], "warnings": []]
            let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            store.states[source.id] = SourceState(snapshot: snapshot, isLive: true)
        }
        try render(MainView(compact: false, tab: "overview").environmentObject(store), size: .init(width: 620, height: 800), name: "overview", output: output)
        store.configuration.menuAccountIDs = store.accounts.map(\.id)
        try render(MainView(compact: false, tab: "settings").environmentObject(store), size: .init(width: 680, height: 900), name: "settings", output: output)
        let accounts = store.accounts.map { WidgetAccount(id: $0.id, name: $0.name, snapshot: $0.state.snapshot!, isLive: true) }
        for (name, family, size, count) in [("widget-small", WidgetFamily.systemSmall, NSSize(width: 180, height: 180), 1),
            ("widget-medium", .systemMedium, NSSize(width: 380, height: 180), 2),
            ("widget-large", .systemLarge, NSSize(width: 380, height: 380), 3)] {
            let view = UsageWidgetView(family: family, entry: UsageEntry(date: .now, accounts: Array(accounts.prefix(count))))
                .padding(16)
            try render(view, size: size, name: name, output: output)
        }
        let menu = HStack(spacing: 6) {
            Image(nsImage: previewMeters([(42, .systemMint), (67, .systemOrange), (23, .systemOrange)]))
            Text(store.menuTitle).font(.system(size: 13)).monospacedDigit()
        }.padding(12)
        try render(menu, size: .init(width: 280, height: 48), name: "menu-bar", output: output)
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, name: String, output: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Keep the native backing resolution; do not enlarge a rasterized view.
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
    }
}
