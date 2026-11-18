import Foundation
import CryptoKit

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
    private static let receiptLock = NSLock()

    /// Bounded local diagnostics: hashes preserve selection/order comparisons without identities.
    public static func recordTimeline(capacity: Int, selection: [String?], accounts: [WidgetAccount]) {
        receiptLock.lock()
        defer { receiptLock.unlock() }
        let selected = selection.prefix(capacity).compactMap { $0 }.filter { $0 != "__automatic__" }
        let encoded = (try? JSONEncoder().encode(selected)) ?? Data()
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let receipt: [String: Double] = ["readAt": Date().timeIntervalSince1970, "capacity": Double(capacity),
            "selectedSlots": Double(selected.count), "accountCount": Double(accounts.count),
            "latestCapturedAt": accounts.map { $0.snapshot.capturedAt }.max() ?? 0,
            "liveAccounts": Double(accounts.filter { $0.isLive }.count)]
        let folder = url.deletingLastPathComponent()
        let path = folder.appendingPathComponent("widget-timeline-history.json")
        var history = (try? Data(contentsOf: path)).flatMap {
            try? JSONDecoder().decode([String: [String: Double]].self, from: $0)
        } ?? [:]
        history["\(capacity):\(digest)"] = receipt
        if history.count > 64 {
            history = Dictionary(uniqueKeysWithValues: history.sorted {
                ($0.value["readAt"] ?? 0) > ($1.value["readAt"] ?? 0)
            }.prefix(64).map { ($0.key, $0.value) })
        }
        for (destination, value) in [(path, history as Any),
            (folder.appendingPathComponent("widget-timeline-receipt.json"), receipt as Any)] {
            if let data = try? JSONSerialization.data(withJSONObject: value) {
                try? data.write(to: destination, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
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
