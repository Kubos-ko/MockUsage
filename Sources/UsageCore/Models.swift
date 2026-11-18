import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable {
    case gptmock, claude
    public var id: String { rawValue }
    public var title: String { self == .gptmock ? "GPTMock" : "Claude Code" }
    public var dashboard: URL {
        URL(string: self == .gptmock ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage")!
    }
}

public struct Source: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var container: String
    public var provider: Provider
    public var interval: Int // -1: app default; 0: manual
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String, container: String, provider: Provider, interval: Int = -1, enabled: Bool = true) {
        self.id = id; self.name = name; self.container = container
        self.provider = provider; self.interval = interval; self.enabled = enabled
    }
    public static let defaults: [Source] = []
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        container.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil
    }
}

public struct UsageWindow: Codable, Identifiable {
    public var id: String
    public var title: String
    public var scope: String
    public var usedPercent: Double
    public var resetsAt: Double?
    public var durationSeconds: Double?
    public var remaining: Double { max(0, 100 - usedPercent) }
    public var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

public struct ExtraUsage: Codable {
    public var title: String
    public var enabled: Bool?
    public var used: Double?
    public var limit: Double?
    public var balance: Double?
    public var unit: String
    public var usedPercent: Double?
    public func formatted(_ amount: Double) -> String {
        if unit == "credits" { return "\(amount.formatted(.number.precision(.fractionLength(0...2)))) credits" }
        return amount.formatted(.currency(code: unit))
    }
}

public struct ResetGrant: Codable, Identifiable {
    public var id: String
    public var title: String
    public var scope: String
    public var count: Int
    public var expiresAt: Double?
    public var usableNow: Bool?
    public var providerGrantID: String?
    public var confirmationBinding: String?
    public var actionTitle: String?
    public var detail: String?
    public var availabilityMessage: String?
    public var canReview: Bool?
    public func isCurrent(at date: Date) -> Bool {
        count > 0 && (expiresAt.map { $0 > date.timeIntervalSince1970 } ?? false)
    }
}

public struct ResetInventory: Codable {
    public var state: String
    public var message: String
    public var items: [ResetGrant]
    public func count(at date: Date) -> Int { items.filter { $0.isCurrent(at: date) }.reduce(0) { $0 + $1.count } }
}

public struct Offer: Codable, Identifiable {
    public var title: String
    public var detail: String
    public var expiresAt: Double?
    public var id: String { title }
}

public struct ModelAvailability: Codable, Identifiable {
    public var name: String
    public var available: Bool?
    public var availableAt: Double?
    public var id: String { name }
}

public enum CompatibilityStatus: String {
    case verified, unverified, unsupported
    public var title: String {
        switch self {
        case .verified: return "Verified compatibility"
        case .unverified: return "Unverified compatibility"
        case .unsupported: return "Unsupported compatibility"
        }
    }
}

public struct ProviderRuntime: Codable {
    public var providerVersion: String
    public var adapterID: String
    public var protocolVersion: Int
    public var resetSupported: Bool
    public var compatibility: String
    public var compatibilityStatus: String?
    public var status: CompatibilityStatus {
        // Old caches and future status values cannot prove current compatibility.
        compatibilityStatus.flatMap(CompatibilityStatus.init(rawValue:)) ?? .unverified
    }
}

public struct UsageSnapshot: Codable {
    public var runtime: ProviderRuntime?
    public var provider: Provider
    public var accountKey: String?
    public var plan: String
    public var capturedAt: Double
    public var windows: [UsageWindow]
    public var extra: ExtraUsage?
    public var resets: ResetInventory
    public var offers: [Offer]
    public var models: [ModelAvailability]
    public var warnings: [String]
    public var capturedDate: Date { Date(timeIntervalSince1970: capturedAt) }
    public var mostUsed: Double? { windows.map(\.usedPercent).max() }
    public func withoutLiveResets() -> UsageSnapshot {
        var copy = self
        copy.resets = .init(state: "unavailable", message: "Refresh to read available resets", items: [])
        return copy
    }
}

public struct CollectorResponse: Codable {
    public var runtime: ProviderRuntime?
    public var snapshot: UsageSnapshot?
    public var error: String?
    public var retryAfter: Int?
}

public struct Configuration: Codable {
    public var sources: [Source] = Source.defaults
    public var interval = 300
    public var appearance = "system"
    public var refreshAfterWake = true
    public var notifications = false
    public var dockerPath = "/usr/local/bin/docker"
    public var dockerContext = "desktop-linux"
    public var zoom = 1.0
    public var hoverPreview = true
    public var menuAccountIDs: [String]? = nil
    public var menuMaximum = 3
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case sources, interval, appearance, refreshAfterWake, notifications, dockerPath, dockerContext, zoom, hoverPreview, menuAccountIDs, menuMaximum
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? Source.defaults
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 300
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        refreshAfterWake = try c.decodeIfPresent(Bool.self, forKey: .refreshAfterWake) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? false
        dockerPath = try c.decodeIfPresent(String.self, forKey: .dockerPath) ?? "/usr/local/bin/docker"
        dockerContext = try c.decodeIfPresent(String.self, forKey: .dockerContext) ?? "desktop-linux"
        zoom = min(1.6, max(0.8, try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1))
        hoverPreview = try c.decodeIfPresent(Bool.self, forKey: .hoverPreview) ?? true
        menuAccountIDs = try c.decodeIfPresent([String].self, forKey: .menuAccountIDs)
        menuMaximum = min(DisplaySelection.menuMaximum, max(1, try c.decodeIfPresent(Int.self, forKey: .menuMaximum) ?? 3))
    }
}

public enum UsagePolicy {
    public static func retryDelay(interval: Int, failures: Int, retryAfter: Int?) -> TimeInterval {
        let base = max(60, interval)
        return max(Double(retryAfter ?? 0), Double(base))
    }
    public static func groupKey(source: Source, snapshot: UsageSnapshot?) -> String {
        if let identity = snapshot?.accountKey { return source.provider.rawValue + ":" + identity }
        return source.id.uuidString
    }
}


public struct CatalogModel: Codable, Identifiable {
    public var containerSupported: Bool?
    public var name: String
    public var available: Bool?
    public var note: String
    public var id: String { name }
}

public struct ModelCatalog: Codable {
    public var accountKey: String
    public var entries: [CatalogModel]
    public var checkedAt: Double
}

public struct ModelCatalogRecord: Codable {
    public var connectionKey: String
    public var attemptedAt: Double
    public var catalog: ModelCatalog?
    public var error: String?
    public init(connectionKey: String, attemptedAt: Double, catalog: ModelCatalog?, error: String?) {
        self.connectionKey = connectionKey; self.attemptedAt = attemptedAt
        self.catalog = catalog; self.error = error
    }
    public static func needsInitialCheck(_ record: ModelCatalogRecord?, connectionKey: String) -> Bool {
        record?.connectionKey != connectionKey
    }

    public mutating func invalidate(accountChanged: Bool, runtimeChanged: Bool) {
        if accountChanged {
            catalog = nil
            error = "Account changed. Check models in Sources to load this account's catalog."
        } else if runtimeChanged {
            error = "Container version changed. Last-known models may be outdated; check models in Sources."
        }
    }
}

public struct ModelCatalogResponse: Decodable {
    public var catalog: ModelCatalog?
    public var error: String?
}
