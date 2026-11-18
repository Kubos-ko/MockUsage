import XCTest
@testable import UsageCore

final class UsageCoreTests: XCTestCase {
    func testDisplaySelectionPreservesOrderCapacityAndMissingExplicitAccounts() {
        let available = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(DisplaySelection.identifiers(available: available, selected: nil, limit: 3), ["a", "b", "c"])
        XCTAssertEqual(DisplaySelection.identifiers(available: available, selected: ["c", "a", "c", "b"], limit: 2), ["c", "a"])
        XCTAssertEqual(DisplaySelection.identifiers(available: available, selected: ["missing"], limit: 3), [])
        XCTAssertEqual(DisplaySelection.identifiers(available: available, selected: ["d"], limit: 3), ["d"])
        XCTAssertEqual(DisplaySelection.identifiers(available: available, selected: ["d", "b", "a"], limit: 1), ["d"])
        XCTAssertEqual(DisplaySelection.identifiers(available: [], selected: nil, limit: 3), [])
    }

    func testMenuSettingsMigrateAndClampWithoutAddingPrivateDefaults() throws {
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"interval":60}"#.utf8))
        XCTAssertNil(old.menuAccountIDs)
        XCTAssertEqual(old.menuMaximum, 3)
        XCTAssertTrue(old.sources.isEmpty)
        let selected = try JSONDecoder().decode(Configuration.self, from: Data(#"{"menuAccountIDs":["c","a"],"menuMaximum":99}"#.utf8))
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(restored.menuAccountIDs, ["c", "a"])
        XCTAssertEqual(restored.menuMaximum, 4)
    }

    func testCompatibilityStatusesDecodeAndOldCachesRemainUnverified() throws {
        for (raw, expected) in [("verified", CompatibilityStatus.verified), ("unverified", .unverified), ("unsupported", .unsupported), ("future-status", .unverified)] {
            let data = Data("{\"providerVersion\":\"1.0.0\",\"adapterID\":\"test\",\"protocolVersion\":1,\"resetSupported\":false,\"compatibility\":\"test\",\"compatibilityStatus\":\"\(raw)\"}".utf8)
            let runtime = try JSONDecoder().decode(ProviderRuntime.self, from: data)
            XCTAssertEqual(runtime.status, expected)
        }
        let old = Data(#"{"providerVersion":"1.0.0","adapterID":"test","protocolVersion":1,"resetSupported":true,"compatibility":"Legacy reading"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ProviderRuntime.self, from: old).status, .unverified)
        let failure = Data(#"{"error":"unsupported_runtime","runtime":{"providerVersion":"2.0.0","adapterID":"none","protocolVersion":1,"resetSupported":false,"compatibility":"No adapter","compatibilityStatus":"unsupported"}}"#.utf8)
        let response = try JSONDecoder().decode(CollectorResponse.self, from: failure)
        XCTAssertNil(response.snapshot)
        XCTAssertEqual(response.runtime?.status, .unsupported)
    }

    func testInitialCatalogAttemptSurvivesRestartIncludingFailures() throws {
        let record = ModelCatalogRecord(connectionKey: "container", attemptedAt: 100, catalog: nil, error: "offline")
        let restored = try JSONDecoder().decode(ModelCatalogRecord.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(ModelCatalogRecord.needsInitialCheck(restored, connectionKey: "container"))
        XCTAssertTrue(ModelCatalogRecord.needsInitialCheck(restored, connectionKey: "other-container"))
        XCTAssertTrue(ModelCatalogRecord.needsInitialCheck(nil, connectionKey: "container"))
    }

    func testRuntimeChangeKeepsLastKnownCatalogWithoutAutomaticCheck() throws {
        let catalog = ModelCatalog(accountKey: "account-a", entries: [], checkedAt: 100)
        var record = ModelCatalogRecord(connectionKey: "container", attemptedAt: 100, catalog: catalog, error: nil)
        record.invalidate(accountChanged: false, runtimeChanged: true)
        let restored = try JSONDecoder().decode(ModelCatalogRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.catalog?.accountKey, "account-a")
        XCTAssertNotNil(restored.error)
        XCTAssertFalse(ModelCatalogRecord.needsInitialCheck(restored, connectionKey: "container"))
    }

    func testAccountChangeClearsCatalogWithoutAutomaticCheck() {
        var record = ModelCatalogRecord(connectionKey: "container", attemptedAt: 100,
            catalog: ModelCatalog(accountKey: "account-a", entries: [], checkedAt: 100), error: nil)
        record.invalidate(accountChanged: true, runtimeChanged: true)
        XCTAssertNil(record.catalog)
        XCTAssertNotNil(record.error)
        XCTAssertFalse(ModelCatalogRecord.needsInitialCheck(record, connectionKey: "container"))
    }

    func testOlderSettingsGainZoomAndHoverDefaults() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(#"{"interval":900,"appearance":"dark"}"#.utf8))
        XCTAssertEqual(config.zoom, 1)
        XCTAssertTrue(config.hoverPreview)
        XCTAssertEqual(config.interval, 900)
        XCTAssertEqual(config.appearance, "dark")
    }
    func testContainerNamesCannotBecomeOptionsOrShellCommands() {
        for name in ["--privileged", "a; echo secret", "$(whoami)", "a/b", ""] {
            XCTAssertFalse(Source(name: "Test", container: name, provider: .gptmock).isValid)
        }
        XCTAssertTrue(Source(name: "Test", container: "gptmock-serve-1", provider: .gptmock).isValid)
    }
    func testRetriesFollowRefreshIntervalUnlessProviderRequiresLongerWait() {
        XCTAssertEqual(UsagePolicy.retryDelay(interval: 60, failures: 1, retryAfter: 600), 600)
        XCTAssertEqual(UsagePolicy.retryDelay(interval: 60, failures: 10, retryAfter: nil), 60)
        XCTAssertEqual(UsagePolicy.retryDelay(interval: 300, failures: 10, retryAfter: nil), 300)
    }
    func testUnknownIdentitiesAreNotMerged() {
        let first = Source(name: "A", container: "a", provider: .claude)
        let second = Source(name: "B", container: "b", provider: .claude)
        XCTAssertNotEqual(UsagePolicy.groupKey(source: first, snapshot: nil), UsagePolicy.groupKey(source: second, snapshot: nil))
    }
    func testExpiredGrantDoesNotCountAndCacheDropsInventory() throws {
        let json = #"{"provider":"claude","accountKey":"safe-hash","plan":"team","capturedAt":100,"windows":[],"extra":null,"resets":{"state":"available","message":"","items":[{"id":"1","title":"Reset","scope":"Weekly","count":2,"expiresAt":200,"usableNow":true}]},"offers":[],"models":[],"warnings":[]}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.resets.count(at: Date(timeIntervalSince1970: 150)), 2)
        XCTAssertEqual(snapshot.resets.count(at: Date(timeIntervalSince1970: 200)), 0)
        XCTAssertTrue(snapshot.withoutLiveResets().resets.items.isEmpty)
        let widget = WidgetAccount(id: "test", name: "Test", snapshot: snapshot, isLive: true)
        let restored = try JSONDecoder().decode(WidgetAccount.self, from: JSONEncoder().encode(widget))
        XCTAssertTrue(restored.snapshot.resets.items.isEmpty)
        XCTAssertEqual(restored.snapshot.accountKey, snapshot.accountKey)
        let a = Source(name: "A", container: "a", provider: .claude)
        let b = Source(name: "B", container: "b", provider: .claude)
        XCTAssertEqual(UsagePolicy.groupKey(source: a, snapshot: snapshot), UsagePolicy.groupKey(source: b, snapshot: snapshot))
    }
}
