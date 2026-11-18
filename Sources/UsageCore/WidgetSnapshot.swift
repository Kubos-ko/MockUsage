import Foundation

public struct WidgetAccount: Codable, Identifiable {
    public var id: String
    public var name: String
    public var snapshot: UsageSnapshot
    public var isLive: Bool
    public init(id: String, name: String, snapshot: UsageSnapshot, isLive: Bool) {
        self.id = id; self.name = name; self.snapshot = snapshot.withoutLiveResets(); self.isLive = isLive
    }
}

public enum WidgetSnapshotFile {
    public static let extensionIdentifier = "local.mockusage.app.widget"
    public static var url: URL {
        #if WIDGET_EXTENSION
        // NSHomeDirectory resolves to this extension's sandbox container.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #else
        // The host is not sandboxed. Only a sanitized snapshot enters the
        // widget's own container; no App Group or credential access is needed.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(extensionIdentifier)/Data", isDirectory: true)
        #endif
        return home.appendingPathComponent("Library/Application Support/MockUsage/widget-usage.json")
    }
    public static func read() -> [WidgetAccount] {
        let accounts = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([WidgetAccount].self, from: $0) } ?? []
        #if WIDGET_EXTENSION
        // A diagnostic receipt proves that the sandboxed extension, rather than
        // only its host, read the snapshot. It contains no identity or usage data.
        let receipt = WidgetReadReceipt(readAt: Date().timeIntervalSince1970, accountCount: accounts.count)
        if let data = try? JSONEncoder().encode(receipt) {
            try? data.write(to: url.deletingLastPathComponent().appendingPathComponent("widget-read-receipt.json"), options: .atomic)
        }
        #endif
        return accounts
    }
    /// Diagnostic counters only: never record account IDs, names, or usage values.
    public static func recordTimeline(capacity: Int, selectedSlots: Int, accountCount: Int) {
        let path = url.deletingLastPathComponent().appendingPathComponent("widget-timeline-receipt.json")
        let receipt: [String: Double] = ["readAt": Date().timeIntervalSince1970, "capacity": Double(capacity),
                                      "selectedSlots": Double(selectedSlots), "accountCount": Double(accountCount)]
        if let data = try? JSONSerialization.data(withJSONObject: receipt) { try? data.write(to: path, options: .atomic) }
    }
    public static func write(_ accounts: [WidgetAccount]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(accounts).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct WidgetReadReceipt: Codable {
    public var readAt: Double
    public var accountCount: Int
}
