import XCTest
import UsageCore
@testable import MockUsage

final class RuntimeTransitionTests: XCTestCase {
    @MainActor
    func testOfflineSourceAutomaticallyReconnectsAndHonorsProviderWait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("simulated-docker.py")
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle.module.url(forResource: "simulated-docker", withExtension: "py")), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let store = UsageStore(directory: root.appendingPathComponent("store"))
        let source = Source(name: "Offline retry", container: "simulation-only", provider: .claude)
        store.configuration.sources = [source]
        store.configuration.interval = 60
        store.configuration.dockerPath = executable.path
        store.configuration.dockerContext = "offline-simulation"
        let connection = [executable.path, "offline-simulation", source.container, source.provider.rawValue].joined(separator: "|")
        store.modelCatalogs[source.id] = ModelCatalogRecord(connectionKey: connection, attemptedAt: 100, catalog: nil, error: nil)
        func scenario(_ error: String? = nil, retryAfter: Int? = nil) throws {
            var value: [String: Any] = ["version": "2.1.325", "status": "verified"]
            if let error { value["error"] = error }
            if let retryAfter { value["retryAfter"] = retryAfter }
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("scenario.json"))
        }
        try scenario("network_error")
        for _ in 0..<3 {
            store.states[source.id]?.lastAttempt = nil
            store.states[source.id]?.nextRefresh = .distantPast
            await store.refreshDue()
            XCTAssertFalse(store.states[source.id]?.isLive ?? true)
            let remaining = try XCTUnwrap(store.states[source.id]?.nextRefresh).timeIntervalSinceNow
            XCTAssertGreaterThan(remaining, 55)
            XCTAssertLessThanOrEqual(remaining, 60)
        }
        try scenario()
        store.states[source.id]?.lastAttempt = nil
        store.states[source.id]?.nextRefresh = .distantPast
        await store.refreshDue()
        XCTAssertEqual(store.states[source.id]?.isLive, true)
        XCTAssertNil(store.states[source.id]?.error)
        XCTAssertEqual(store.states[source.id]?.failures, 0)
        XCTAssertEqual(store.modelCatalogs[source.id]?.attemptedAt, 100)

        try scenario("http_429", retryAfter: 600)
        store.states[source.id]?.lastAttempt = nil
        await store.refresh(source)
        XCTAssertGreaterThan(try XCTUnwrap(store.states[source.id]?.nextRefresh).timeIntervalSinceNow, 595)
        let calls = try Data(contentsOf: root.appendingPathComponent("calls.jsonl"))
        store.states[source.id]?.lastAttempt = nil
        store.states[source.id]?.nextRefresh = .distantPast
        await store.refreshDue()
        await store.refresh(source)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("calls.jsonl")), calls, "Neither timer nor manual refresh may bypass Retry-After")
        store.states[source.id]?.retryNotBefore = .distantPast
        try scenario()
        await store.refreshDue()
        XCTAssertEqual(store.states[source.id]?.isLive, true)
        XCTAssertNil(store.states[source.id]?.retryNotBefore)

        var manual = source
        manual.interval = 0
        store.configuration.sources = [manual]
        store.states[source.id]?.lastAttempt = nil
        try scenario("network_error")
        await store.refresh(manual)
        XCTAssertNil(store.states[source.id]?.nextRefresh)
        let manualCalls = try Data(contentsOf: root.appendingPathComponent("calls.jsonl"))
        await store.refreshDue()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("calls.jsonl")), manualCalls)
    }

    @MainActor
    func testOfflineUpgradeAndRollbackForBothProviders() async throws {
        for provider in Provider.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("simulated-docker.py")
            try FileManager.default.copyItem(at: XCTUnwrap(Bundle.module.url(forResource: "simulated-docker", withExtension: "py")), to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let store = UsageStore(directory: root.appendingPathComponent("store"))
            let source = Source(name: "Offline simulation", container: "simulation-only", provider: provider, interval: 0)
            store.configuration.sources = [source]
            store.configuration.dockerPath = executable.path
            store.configuration.dockerContext = "offline-simulation"
            store.configuration.notifications = false
            let connection = [executable.path, "offline-simulation", source.container, provider.rawValue].joined(separator: "|")
            store.modelCatalogs[source.id] = ModelCatalogRecord(connectionKey: connection, attemptedAt: 100, catalog: nil, error: nil)
            let knownVersion = provider == .gptmock ? "2026.11.16" : "2.1.325"
            var originalAccount: AccountGroup?
            var originalGrant: ResetGrant?
            for (version, status) in [(knownVersion, "verified"), ("2099.1.1", "unverified"), ("2099.1.2", "unsupported"), (knownVersion, "verified")] {
                try JSONSerialization.data(withJSONObject: ["version": version, "status": status]).write(to: root.appendingPathComponent("scenario.json"))
                store.states[source.id]?.lastAttempt = nil
                await store.refresh(source)
                let state = try XCTUnwrap(store.states[source.id])
                XCTAssertEqual(state.runtime?.providerVersion, version)
                XCTAssertEqual(state.runtime?.status.rawValue, status)
                XCTAssertEqual(state.runtime?.resetSupported, status == "verified")
                XCTAssertEqual(store.modelCatalogs[source.id]?.attemptedAt, 100, "An upgrade must not automatically check models")
                if status == "verified" {
                    XCTAssertTrue(state.isLive)
                    XCTAssertEqual(state.snapshot?.resets.items.first?.usableNow, true)
                    if originalAccount == nil {
                        originalAccount = store.accounts.first
                        originalGrant = state.snapshot?.resets.items.first
                    }
                } else {
                    if status == "unsupported" {
                        XCTAssertFalse(state.isLive)
                        XCTAssertEqual(state.snapshot?.resets.items.count, 0, "Cached inventory must be stripped")
                    } else {
                        XCTAssertTrue(state.isLive)
                        XCTAssertEqual(state.snapshot?.resets.items.first?.canReview, false)
                        XCTAssertEqual(state.snapshot?.resets.items.first?.usableNow, false)
                    }
                    // Simulate confirming an OLD review after the next refresh detects an upgrade.
                    // This must stop in the app, before the bridge can start any reset command.
                    let before = try Data(contentsOf: root.appendingPathComponent("calls.jsonl"))
                    await store.redeem(account: try XCTUnwrap(originalAccount), grant: try XCTUnwrap(originalGrant))
                    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("calls.jsonl")), before)
                    XCTAssertEqual(store.resetResult, "The account or reset changed. Refresh usage and review it again.")
                }
                print("SIMULATION \(provider.rawValue) \(version): \(status), resetSupported=\(state.runtime?.resetSupported ?? false)")
            }
            let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            XCTAssertFalse(calls.contains("--confirmed-reset"))
            XCTAssertFalse(calls.contains("--models"))
            XCTAssertEqual(calls.split(separator: "\n").count, 4)
            XCTAssertNil(store.storageError)
        }
    }
}
