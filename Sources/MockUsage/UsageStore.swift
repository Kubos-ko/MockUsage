import AppKit
import SwiftUI
import UserNotifications
import WidgetKit
#if SWIFT_PACKAGE
import UsageCore
#endif

struct SourceState {
    var runtime: ProviderRuntime?
    var snapshot: UsageSnapshot?
    var error: String?
    var isLoading = false
    var isLive = false
    var failures = 0
    var nextRefresh: Date?
    var retryNotBefore: Date?
    var lastAttempt: Date?
}

struct AccountGroup: Identifiable {
    var id: String
    var sources: [Source]
    var state: SourceState
    var name: String { sources.first?.name ?? "Account" }
    var provider: Provider { sources.first?.provider ?? .gptmock }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    @Published var modelCatalogs: [UUID: ModelCatalogRecord] = [:]
    @Published var checkingModels: Set<UUID> = []
    @Published var resetInProgress = false
    @Published var resetResult: String?
    @Published var configuration: Configuration
    @Published var states: [UUID: SourceState] = [:]
    @Published var storageError: String?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var notified: Set<String> = []
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MockUsage", isDirectory: true)
        let configURL = self.directory.appendingPathComponent("configuration.json")
        if let data = try? Data(contentsOf: configURL), let saved = try? JSONDecoder().decode(Configuration.self, from: data) {
            configuration = saved
        } else {
            configuration = Configuration()
            if !FileManager.default.isExecutableFile(atPath: configuration.dockerPath) {
                for path in ["/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
                    where FileManager.default.isExecutableFile(atPath: path) {
                    configuration.dockerPath = path; break
                }
            }
        }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("usage-cache.json")),
           let cache = try? JSONDecoder().decode([String: UsageSnapshot].self, from: data) {
            for source in configuration.sources {
                if let snapshot = cache[source.id.uuidString] {
                    states[source.id] = SourceState(snapshot: snapshot.withoutLiveResets(), error: "Cached reading · refresh pending")
                }
            }
        }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("model-catalogs.json")),
           let saved = try? JSONDecoder().decode([UUID: ModelCatalogRecord].self, from: data) {
            modelCatalogs = saved.filter { id, record in
                configuration.sources.contains { $0.id == id && record.connectionKey == modelConnectionKey($0) }
            }
        }

    }

    var accounts: [AccountGroup] {
        var result: [AccountGroup] = []
        for source in configuration.sources where source.enabled {
            let state = states[source.id] ?? SourceState()
            let key = UsagePolicy.groupKey(source: source, snapshot: state.snapshot)
            if let index = result.firstIndex(where: { $0.id == key }) {
                result[index].sources.append(source)
                let old = result[index].state
                if (state.isLive && !old.isLive) || (state.isLive == old.isLive &&
                    (state.snapshot?.capturedAt ?? 0) > (old.snapshot?.capturedAt ?? 0)) {
                    result[index].state = state
                }
            } else { result.append(AccountGroup(id: key, sources: [source], state: state)) }
        }
        return result
    }

    func menuAccounts(limit: Int? = nil) -> [AccountGroup] {
        let ids = DisplaySelection.identifiers(available: accounts.map(\.id), selected: configuration.menuAccountIDs,
            limit: min(configuration.menuMaximum, limit ?? DisplaySelection.menuMaximum))
        return ids.compactMap { id in accounts.first { $0.id == id } }
    }

    var menuTitle: String { menuTitle(for: menuAccounts()) }

    func menuTitle(for selected: [AccountGroup]) -> String {

        selected.map { account in
            let letter = account.provider == .gptmock ? "G" : "C"
            guard let snapshot = account.state.snapshot, let value = snapshot.mostUsed else { return "\(letter) —" }
            let stale = !account.state.isLive || Date().timeIntervalSince(snapshot.capturedDate) > 900
            return "\(letter) \(Int(value.rounded()))%\(stale ? "·" : "")"
        }.joined(separator: "  ")
    }

    var colorScheme: ColorScheme? {
        configuration.appearance == "dark" ? .dark : configuration.appearance == "light" ? .light : nil
    }

    func changeZoom(_ delta: Double) {
        configuration.zoom = min(1.6, max(0.8, (configuration.zoom * 10 + delta * 10).rounded() / 10))
        saveConfiguration()
    }
    func resetZoom() { configuration.zoom = 1; saveConfiguration() }

    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshDue() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.configuration.refreshAfterWake else { return }
                await self.refreshAll()
            }
        }
        Task { await refreshAll() }
    }

    func refreshDue() async {
        await withTaskGroup(of: Void.self) { group in
            for source in configuration.sources where source.enabled {
                let state = states[source.id] ?? SourceState()
                guard effectiveInterval(source) > 0, !state.isLoading,
                      state.nextRefresh.map({ $0 <= Date() }) ?? true else { continue }
                group.addTask { await self.refresh(source) }
            }
        }
        await checkInitialModelCatalogs()
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for source in configuration.sources where source.enabled {
                group.addTask { await self.refresh(source) }
            }
        }
        await checkInitialModelCatalogs()
    }

    private func modelConnectionKey(_ source: Source) -> String {
        [configuration.dockerPath, configuration.dockerContext, source.container, source.provider.rawValue].joined(separator: "|")
    }

    private func persistModelCatalogs() {
        do { try write(modelCatalogs, name: "model-catalogs.json") }
        catch { storageError = "Could not save the model catalog cache." }
    }

    private func checkInitialModelCatalogs() async {
        await withTaskGroup(of: Void.self) { group in
            for source in configuration.sources where source.enabled {
                group.addTask { await self.refreshModels(source) }
            }
        }
    }

    func refreshModels(_ source: Source, force: Bool = false) async {
        guard source.enabled, !resetInProgress, !checkingModels.contains(source.id),
              !(states[source.id]?.isLoading ?? false) else { return }
        let connection = modelConnectionKey(source)
        let previous = modelCatalogs[source.id].flatMap { $0.connectionKey == connection ? $0 : nil }
        if !force && !ModelCatalogRecord.needsInitialCheck(previous, connectionKey: connection) { return }
        if let previous {
            if force && Date().timeIntervalSince1970 - previous.attemptedAt < 60 { return }
        }
        checkingModels.insert(source.id)
        defer { checkingModels.remove(source.id) }
        let config = configuration
        let attemptedAt = Date().timeIntervalSince1970
        var record = ModelCatalogRecord(connectionKey: connection, attemptedAt: attemptedAt,
                                        catalog: previous?.catalog, error: nil)
        // Persist the attempt before I/O so restarts do not silently retry a failed check.
        record.error = "Model check did not complete. Check models in Sources to retry."
        modelCatalogs[source.id] = record
        persistModelCatalogs()
        record.error = nil
        let checkedRuntime = states[source.id]?.snapshot?.runtime?.providerVersion
        do {
            let response = try await DockerBridge.models(source: source, configuration: config)
            if let catalog = response.catalog {
                if let activeKey = states[source.id]?.snapshot?.accountKey, activeKey != catalog.accountKey {
                    record.catalog = nil
                    record.error = "Account changed during the check. Refresh usage and check models again."
                } else { record.catalog = catalog }
            } else {
                record.error = "Model check unavailable (\(response.error ?? "invalid_response"))."
                if ["http_401", "http_403", "credentials_expired", "missing_credentials"].contains(response.error ?? "") { record.catalog = nil }
            }
        } catch { record.error = "Model check failed. Last successful catalog may be outdated." }
        guard configuration.sources.contains(source), modelConnectionKey(source) == connection else { return }
        if states[source.id]?.snapshot?.runtime?.providerVersion != checkedRuntime {
            record.invalidate(accountChanged: false, runtimeChanged: true)
        }
        modelCatalogs[source.id] = record
        persistModelCatalogs()
    }

    func effectiveInterval(_ source: Source) -> Int { source.interval < 0 ? configuration.interval : source.interval }

    func refresh(_ source: Source) async {
        guard !resetInProgress, !(states[source.id]?.isLoading ?? false), source.enabled else { return }
        // Provider Retry-After applies to automatic and manual refresh alike.
        if let deadline = states[source.id]?.retryNotBefore, deadline > Date() { return }
        // Manual clicks also respect a short cooldown; never create overlapping probes.
        if let last = states[source.id]?.lastAttempt, Date().timeIntervalSince(last) < 20 { return }
        states[source.id, default: SourceState()].isLoading = true
        states[source.id, default: SourceState()].lastAttempt = Date()
        let capturedConfig = configuration
        do {
            let response = try await DockerBridge.collect(source: source, configuration: capturedConfig)
            guard configuration.sources.contains(source), configuration.dockerContext == capturedConfig.dockerContext,
                  configuration.dockerPath == capturedConfig.dockerPath else { states[source.id]?.isLoading = false; return }
            let detectedRuntime = response.snapshot?.runtime ?? response.runtime
            let oldRuntime = states[source.id]?.runtime ?? states[source.id]?.snapshot?.runtime
            if let detectedRuntime {
                if oldRuntime?.providerVersion != detectedRuntime.providerVersion || oldRuntime?.adapterID != detectedRuntime.adapterID {
                    modelCatalogs[source.id]?.invalidate(accountChanged: false, runtimeChanged: true)
                    persistModelCatalogs()
                }
                states[source.id, default: SourceState()].runtime = detectedRuntime
            }
            if let snapshot = response.snapshot {
                let previousSnapshot = states[source.id]?.snapshot
                let accountChanged = (modelCatalogs[source.id]?.catalog.map { $0.accountKey != snapshot.accountKey } ?? false)
                    || (previousSnapshot.map { $0.accountKey != snapshot.accountKey } ?? false)
                let runtimeChanged = previousSnapshot.map { $0.runtime?.providerVersion != snapshot.runtime?.providerVersion } ?? false
                if accountChanged || runtimeChanged {
                    modelCatalogs[source.id]?.invalidate(accountChanged: accountChanged, runtimeChanged: runtimeChanged)
                    persistModelCatalogs()
                }
                states[source.id] = SourceState(runtime: snapshot.runtime, snapshot: snapshot, isLive: true,
                    nextRefresh: effectiveInterval(source) > 0 ? Date().addingTimeInterval(Double(effectiveInterval(source))) : nil,
                    lastAttempt: Date())
                notifyIfNeeded(snapshot, source: source)
            } else {
                fail(source, message: Self.message(for: response.error), retryAfter: response.retryAfter,
                     clear: ["http_401", "http_403", "missing_credentials", "credentials_expired"].contains(response.error ?? ""))
            }
        } catch { fail(source, message: error.localizedDescription, retryAfter: nil, clear: false) }
        persistCache()
    }

    func redeem(account: AccountGroup, grant: ResetGrant) async {
        guard !resetInProgress else { return }
        guard let snapshot = account.state.snapshot,
              account.state.isLive, snapshot.runtime?.resetSupported == true, Date().timeIntervalSince(snapshot.capturedDate) < 900,
              grant.isCurrent(at: Date()), grant.usableNow == true, grant.canReview == true,
              let source = account.sources.first(where: {
                  configuration.sources.contains($0) && $0.enabled &&
                  states[$0.id]?.isLive == true && states[$0.id]?.isLoading == false &&
                  states[$0.id]?.snapshot?.accountKey == snapshot.accountKey &&
                  states[$0.id]?.runtime?.resetSupported == true &&
                  states[$0.id]?.runtime?.providerVersion == snapshot.runtime?.providerVersion &&
                  states[$0.id]?.runtime?.adapterID == snapshot.runtime?.adapterID &&
                  states[$0.id]?.snapshot?.resets.items.contains(where: { current in
                      current.providerGrantID == grant.providerGrantID && current.confirmationBinding == grant.confirmationBinding &&
                      current.usableNow == true && current.canReview == true && current.isCurrent(at: Date())
                  }) == true
              }) else {
            resetResult = "The account or reset changed. Refresh usage and review it again."
            return
        }
        resetInProgress = true
        let config = configuration
        do {
            let response = try await DockerBridge.redeem(source: source, configuration: config, snapshot: snapshot, grant: grant)
            if let diagnostics = response.diagnostics {
                do { try write(diagnostics, name: "last-reset-diagnostic.json") }
                catch { storageError = "Could not save the sanitized reset diagnostic." }
            }
            switch response.result {
            case "reset": resetResult = "Reset completed. Refreshing account usage."
            case "already_used": resetResult = "This reset has already been used. Refreshing account usage."
            case "not_limited": resetResult = "Nothing to reset. The provider did not apply this reset."
            case "rate_limited": resetResult = "The provider rejected the reset request due to rate limiting. It was not retried. Refresh usage before reviewing it again."
            case "auth_error": resetResult = "The provider rejected reset authorization. Renew the container session and refresh usage."
            case "cooldown": resetResult = "The provider requires a cooldown before this reset can be used."
            case "ineligible", "unavailable": resetResult = "The provider declined this reset. Refresh usage to check its availability."
            case "uncertain": resetResult = "The result could not be confirmed. The request will not be repeated. Check refreshed usage before taking any further action."
            default:
                if let error = response.error, error != "collector_error" {
                    resetResult = error == "http_429"
                        ? "Reset was not sent: the provider still limits the availability check after waiting. Try again later."
                        : "Reset was not sent: \(error). Refresh usage and review the reset again."
                } else {
                    resetResult = "The result could not be confirmed. No automatic retry will occur. Check refreshed usage."
                }
            }
        } catch {
            resetResult = "The result could not be confirmed. No automatic retry will occur. Refresh usage before taking any further action."
        }
        // Remove all cached copies of this account's inventory before reloading.
        for candidate in configuration.sources where states[candidate.id]?.snapshot?.accountKey == snapshot.accountKey {
            states[candidate.id]?.snapshot = states[candidate.id]?.snapshot?.withoutLiveResets()
            states[candidate.id]?.lastAttempt = nil
        }
        resetInProgress = false
        persistCache()
        await refreshAll()
    }

    private func fail(_ source: Source, message: String, retryAfter: Int?, clear: Bool) {
        guard configuration.sources.contains(source) else { return }
        var state = states[source.id] ?? SourceState()
        if clear { modelCatalogs[source.id]?.catalog = nil; modelCatalogs[source.id]?.error = "Account authentication is unavailable."; persistModelCatalogs() }
        state.failures += 1; state.isLoading = false; state.isLive = false; state.error = message
        state.snapshot = clear ? nil : state.snapshot?.withoutLiveResets()
        state.retryNotBefore = retryAfter.flatMap { $0 > 0 ? Date().addingTimeInterval(Double($0)) : nil }
        state.nextRefresh = effectiveInterval(source) > 0 ? Date().addingTimeInterval(
            UsagePolicy.retryDelay(interval: effectiveInterval(source), failures: state.failures, retryAfter: retryAfter)) : nil
        states[source.id] = state
    }

    static func message(for code: String?) -> String {
        switch code {
        case "http_401", "credentials_expired": return "Sign-in expired. Renew the session in this container, then refresh."
        case "http_403": return "Usage access denied for this account or credential scope."
        case "http_429": return "Provider rate limit reached. Cached data is shown; the next scheduled check will retry."
        case "missing_credentials", "missing_credentials_or_runtime": return "Sign in inside this container and ensure Python 3 is installed."
        case "unsupported_runtime": return "This runtime is not supported by this app. Install an app release with a compatible adapter."
        case "network_error": return "Provider unavailable. Last successful reading is retained."
        default: return "Usage unavailable (\(code ?? "invalid_response")). Check the container session."
        }
    }

    func saveConfiguration() {
        do { try write(configuration, name: "configuration.json"); storageError = nil }
        catch { storageError = "Could not save settings: \(error.localizedDescription)" }
        for source in configuration.sources {
            states[source.id]?.nextRefresh = effectiveInterval(source) > 0
                ? max(Date().addingTimeInterval(Double(max(60, effectiveInterval(source)))), states[source.id]?.retryNotBefore ?? .distantPast)
                : nil
        }
    }

    func saveSource(_ source: Source) {
        guard source.isValid else { return }
        if let index = configuration.sources.firstIndex(where: { $0.id == source.id }) {
            let old = configuration.sources[index]
            if old.container != source.container || old.provider != source.provider { states[source.id] = nil; modelCatalogs[source.id] = nil; persistModelCatalogs() }
            configuration.sources[index] = source
        } else { configuration.sources.append(source) }
        saveConfiguration()
        Task { await refresh(source); await refreshModels(source) }
    }

    func removeSource(_ source: Source) {
        configuration.sources.removeAll { $0.id == source.id }; states[source.id] = nil
        modelCatalogs[source.id] = nil; persistModelCatalogs()
        saveConfiguration(); persistCache()
    }

    func connectionChanged() {
        states = [:]; modelCatalogs = [:]; persistModelCatalogs(); saveConfiguration(); persistCache()
        Task { await refreshAll() }
    }

    private func persistCache() {
        let values = states.reduce(into: [String: UsageSnapshot]()) { result, entry in
            if let snapshot = entry.value.snapshot { result[entry.key.uuidString] = snapshot.withoutLiveResets() }
        }
        do { try write(values, name: "usage-cache.json") }
        catch { storageError = "Could not save the local usage cache." }
        #if WIDGET_SUPPORT
        do {
            try WidgetSnapshotFile.write(accounts.compactMap { account in
                guard let snapshot = account.state.snapshot else { return nil }
                return WidgetAccount(id: account.id, name: account.name, snapshot: snapshot, isLive: account.state.isLive)
            })
            WidgetCenter.shared.reloadTimelines(ofKind: "MockUsageWidget")
        } catch { storageError = "The desktop widget snapshot could not be updated." }
        #endif
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyIfNeeded(_ snapshot: UsageSnapshot, source: Source) {
        guard configuration.notifications else { return }
        for window in snapshot.windows {
            for threshold in [80, 95] where window.usedPercent >= Double(threshold) {
                let key = "\(snapshot.accountKey ?? source.id.uuidString):\(window.id):\(window.resetsAt ?? 0):\(threshold)"
                guard notified.insert(key).inserted else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(source.name): \(threshold)% used"
                content.body = "\(window.scope) · \(window.title)"
                UNUserNotificationCenter.current().add(.init(identifier: key, content: content, trigger: nil))
            }
        }
    }
}
