import SwiftUI
#if SWIFT_PACKAGE
import UsageCore
#endif

struct MainView: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    let compact: Bool
    @State private var tab = "overview"

    var body: some View {
        content
        .usageFont(.body)
        .environment(\.usageTextScale, store.configuration.zoom)
        .alert("Reset result", isPresented: Binding(get: { store.resetResult != nil }, set: { if !$0 { store.resetResult = nil } })) {
            Button("OK") { store.resetResult = nil }
        } message: { Text(store.resetResult ?? "") }
        .preferredColorScheme(store.colorScheme)
        .frame(minWidth: compact ? nil : 520, minHeight: compact ? nil : 480)
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(.mint)
                    Text("Mock Usage").usageFont(.title2, weight: .semibold)
                    Spacer()
                    if store.resetInProgress {
                        ProgressView().controlSize(.small).help("Verifying reset availability. A provider rate limit may require a 60-second wait. The reset request is never retried.")
                    } else if store.states.values.contains(where: \.isLoading) { ProgressView().controlSize(.small) }
                    Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh all sources")
                    if compact {
                        Button { AppDelegate.shared?.showDashboard() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }.help("Open dashboard")
                    }
                }
                Text("\(store.configuration.sources.count) sources · \(store.accounts.count) account groups")
                    .usageFont(.caption).foregroundStyle(.secondary)
                Picker("View", selection: $tab) {
                    Text("Overview").tag("overview")
                    Text("Sources").tag("sources")
                    Text("Settings").tag("settings")
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    if let error = store.storageError { Text(error).usageFont(.caption).foregroundStyle(.red) }
                    switch tab {
                    case "sources": SourcesView()
                    case "settings": PreferencesView()
                    default:
                        if store.accounts.isEmpty {
                            ContentUnavailableView("No active sources", systemImage: "shippingbox", description: Text("Add or enable a container in Sources."))
                        }
                        ForEach(store.accounts) { AccountCard(account: $0) }
                    }
                }.padding(14)
            }
            Divider()
            HStack {
                Label("Local Docker connections", systemImage: "lock.shield").usageFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.changeZoom(-0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘−)").disabled(store.configuration.zoom <= 0.8)
                Button("\(Int((store.configuration.zoom * 100).rounded()))%") { store.resetZoom() }
                    .usageFont(.caption).monospacedDigit().help("Reset zoom (⌘0)")
                Button { store.changeZoom(0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+)").disabled(store.configuration.zoom >= 1.6)
                if compact { Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).usageFont(.caption) }
            }.padding(12)
        }
        .background(.background)
        .onOpenURL { url in
            if url.scheme == "mockusage" { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

struct AccountCard: View {
    @EnvironmentObject private var store: UsageStore
    let account: AccountGroup
    @State private var showResetReview = false
    @State private var showResets = false
    @State private var selectedReset: ResetGrant?
    @State private var selectedAccount: AccountGroup?
    private var accent: Color { account.provider == .gptmock ? .mint : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).usageFont(.headline)
                    Text(account.state.snapshot?.plan.replacingOccurrences(of: "_", with: " ").capitalized ?? account.provider.title)
                        .usageFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(account.state.isLive ? "Connected" : account.state.nextRefresh != nil ? "Cached / retrying" : "Offline / cached",
                      systemImage: account.state.isLive ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .usageFont(.caption).foregroundStyle(account.state.isLive ? accent : .secondary)
            }
            if account.sources.count > 1 {
                Text("Shared account quota · \(account.sources.count) containers").usageFont(.caption).foregroundStyle(.secondary)
            }
            if let error = account.state.error { Text(error).usageFont(.caption).foregroundStyle(.orange) }
            if !account.state.isLive, let next = account.state.nextRefresh {
                Text("Next automatic check: \(next.formatted(date: .omitted, time: .shortened))")
                    .usageFont(.caption).foregroundStyle(.secondary)
            }
            if let snapshot = account.state.snapshot {
                if snapshot.windows.isEmpty { Text("Quota windows not supplied by this account.").usageFont(.callout).foregroundStyle(.secondary) }
                ForEach(snapshot.windows) { window in WindowRow(window: window, accent: accent) }
                if snapshot.extra != nil || !snapshot.offers.isEmpty { Divider() }
                if let extra = snapshot.extra { ExtraUsageRow(extra: extra, accent: accent) }
                ForEach(snapshot.offers) { offer in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(offer.detail).usageFont(.caption).foregroundStyle(.secondary)
                            if let expiry = offer.expiresAt {
                                Text("Expires \(Date(timeIntervalSince1970: expiry).formatted())").usageFont(.caption)
                            }
                        }.padding(.top, 3)
                    } label: {
                        Text(offer.title).usageFont(.caption, weight: .medium)
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let fresh = account.state.isLive && context.date.timeIntervalSince(snapshot.capturedDate) < 900
                    let count = fresh ? snapshot.resets.count(at: context.date) : 0
                    DisclosureGroup(isExpanded: $showResets) {
                        VStack(alignment: .leading, spacing: 8) {
                            if fresh {
                                ForEach(snapshot.resets.items.filter { $0.isCurrent(at: context.date) }) { grant in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(grant.actionTitle ?? grant.title).usageFont(.subheadline, weight: .semibold)
                                            Spacer(minLength: 8)
                                            Button("Use \(grant.actionTitle ?? grant.title)…") {
                                                selectedReset = grant
                                                selectedAccount = account
                                                showResetReview = true
                                            }
                                            .disabled(snapshot.runtime?.resetSupported != true || store.resetInProgress || grant.canReview == false || grant.usableNow == false || (grant.providerGrantID == nil || grant.confirmationBinding == nil || grant.usableNow != true || !(grant.availabilityMessage?.hasPrefix("Ready to use") ?? false)))
                                            .help("Review and confirm this specific reset before sending it to the provider.")
                                            .tint(accent)
                                            .controlSize(.small)
                                        }
                                        Text(grant.detail ?? grant.scope).usageFont(.caption).foregroundStyle(.secondary)
                                        if let expiry = grant.expiresAt {
                                            Text("Expires \(Date(timeIntervalSince1970: expiry).formatted(date: .abbreviated, time: .shortened)) · \(grant.count) left")
                                                .usageFont(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(grant.availabilityMessage ?? (grant.usableNow == false ? "Not usable now — blocked by the provider." : "Verify current usability on the provider’s dashboard."))
                                            .usageFont(.caption).foregroundStyle(grant.canReview == false || grant.usableNow == false ? .orange : .secondary)
                                    }.padding(8).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            if count == 0 { Text(fresh ? snapshot.resets.message : "Refresh to read current reset availability.").usageFont(.caption).foregroundStyle(.secondary) }
                        }.padding(.top, 6)
                    } label: {
                        HStack {
                            Text("Limit resets").usageFont(.caption, weight: .medium)
                            Spacer()
                            Text(fresh && ["available", "partial"].contains(snapshot.resets.state) ? "\(count) available" : "Unavailable")
                                .usageFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(snapshot.warnings, id: \.self) { Text($0).usageFont(.caption).foregroundStyle(.orange) }
                HStack {
                    Text("Measured \(snapshot.capturedDate.formatted(date: .omitted, time: .shortened))")
                        .help(snapshot.capturedDate.formatted(date: .complete, time: .standard))
                    Spacer()
                    Link("Usage dashboard ↗", destination: account.provider.dashboard)
                }.usageFont(.caption).foregroundStyle(.secondary)
            } else if account.state.isLoading {
                Text("Reading usage inside the container…").usageFont(.callout).foregroundStyle(.secondary)
            } else {
                Text("No measured usage yet.").foregroundStyle(.secondary)
            }
        }
        .padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .alert("Confirm \(selectedReset?.actionTitle ?? selectedReset?.title ?? "reset")", isPresented: $showResetReview) {
            Group {
                Button("Use reset", role: .destructive) {
                    if let captured = selectedAccount, let grant = selectedReset {
                        Task { await store.redeem(account: captured, grant: grant) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Account: \(selectedAccount?.name ?? account.name)\nContainer: \(selectedAccount?.sources.first?.container ?? "Unknown")\nExpires: \(selectedReset?.expiresAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")\n\n\(selectedReset?.detail ?? selectedReset?.scope ?? "")\n\nThis consumes one saved reset and cannot be undone. The app will verify the account and current usage again before sending. It will not enable paid usage.")
        }
    }
}

struct QuotaBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.15))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }.frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityValue("\(Int(min(1, max(0, fraction)) * 100)) percent")
    }
}

struct ExtraUsageRow: View {
    let extra: ExtraUsage
    let accent: Color
    private var summary: String {
        if let balance = extra.balance { return extra.formatted(balance) + " left" }
        if let used = extra.used, let limit = extra.limit { return extra.formatted(used) + " / " + extra.formatted(limit) }
        if let used = extra.used { return extra.formatted(used) + " used" }
        return extra.enabled.map { $0 ? "Enabled" : "Disabled" } ?? "Status unknown"
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                if let enabled = extra.enabled { Text(enabled ? "Enabled" : "Disabled") }
                if let balance = extra.balance { Text(extra.formatted(balance) + " remaining") }
                if let used = extra.used { Text(extra.formatted(used) + " used") }
                if let limit = extra.limit { Text("Limit: " + extra.formatted(limit)) }
                if let limit = extra.limit, limit > 0, let used = extra.used {
                    QuotaBar(fraction: used / limit, color: accent)
                }
                if extra.limit == 0 { Text("Provider reports a zero spending limit; no percentage is inferred.") }
            }.usageFont(.caption).foregroundStyle(.secondary).padding(.top, 3)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(extra.title).usageFont(.caption, weight: .medium)
                Spacer(minLength: 8)
                Text(summary).usageFont(.caption).monospacedDigit().foregroundStyle(.secondary)
            }.help(extra.enabled.map { $0 ? "Enabled" : "Disabled" } ?? "Status unknown")
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.scope == "All models" ? window.title : "\(window.scope) · \(window.title)").usageFont(.subheadline)
                Spacer()
                Text("\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used").usageFont(.subheadline, weight: .semibold).monospacedDigit()
            }
            QuotaBar(fraction: window.usedPercent / 100,
                     color: window.usedPercent >= 95 ? .red : window.usedPercent >= 80 ? .orange : accent)
                .accessibilityLabel("\(window.scope) \(window.title)")
            HStack(alignment: .top) {
                Text("\(window.remaining.formatted(.number.precision(.fractionLength(0...1))))% left")
                Spacer()
                if let reset = window.resetDate {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(reset > context.date ? "Resets in \(Self.duration(reset.timeIntervalSince(context.date)))" : "Reset due · awaiting data")
                            .help(reset.formatted(date: .complete, time: .standard))
                            .accessibilityHint(reset.formatted(date: .complete, time: .standard))
                    }
                } else { Text("Reset time unavailable") }
            }.usageFont(.caption).foregroundStyle(.secondary)
        }
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

struct ModelAvailabilityView: View {
    @EnvironmentObject var store: UsageStore
    let source: Source
    var allowsManualCheck = false
    var body: some View {
        DisclosureGroup("Model availability") {
            VStack(alignment: .leading, spacing: 8) {
                if let record = store.modelCatalogs[source.id] {
                    if let error = record.error { Text(error).foregroundStyle(.orange) }
                    if let catalog = record.catalog {
                        Text("\(record.error == nil ? "Checked" : "Last known") \(Date(timeIntervalSince1970: catalog.checkedAt).formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                        ForEach(catalog.entries) { model in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .top) {
                                    Text(model.name).textSelection(.enabled)
                                    Spacer()
                                    Text(model.containerSupported == false && model.available == true ? "Account only" : model.available == true ? "Available" : model.available == false ? "Unavailable" : "Unverified")
                                        .foregroundStyle(model.available == true ? Color.green : Color.secondary)
                                }
                                Text(model.note).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else { Text("No model catalog checked yet.").foregroundStyle(.secondary) }
                if store.checkingModels.contains(source.id) { ProgressView("Checking models…") }
                if allowsManualCheck {
                    Button("Check models now") { Task { await store.refreshModels(source, force: true) } }
                        .disabled(!source.enabled || store.checkingModels.contains(source.id) || store.resetInProgress || (store.states[source.id]?.isLoading ?? false))
                }
                Text("Checked automatically once per connection; then only with Check models now in Sources (one-minute retry cooldown). No model inference is run.").foregroundStyle(.secondary)
                if source.provider == .claude {
                    Text("Unverified means listed by the API without confirmed Claude Code access for this account; it does not mean unavailable.").foregroundStyle(.secondary)
                }
            }.padding(.top, 6).usageFont(.caption)
        }.usageFont(.caption)
    }
}

struct SourcesView: View {
    @EnvironmentObject var store: UsageStore
    @State private var editing: Source?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(store.configuration.sources) { source in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(source.name).usageFont(.headline); Spacer()
                        Button("Edit") { editing = source }
                    }
                    if let runtime = store.states[source.id]?.runtime ?? store.states[source.id]?.snapshot?.runtime {
                        Text("\(source.provider.title) \(runtime.providerVersion) · \(runtime.adapterID) · protocol \(runtime.protocolVersion)")
                            .usageFont(.caption).foregroundStyle(.secondary)
                        Text(runtime.status.title).usageFont(.caption, weight: .semibold)
                            .foregroundStyle(runtime.status == .verified ? Color.green : runtime.status == .unsupported ? Color.red : Color.orange)
                        Text(runtime.compatibility).usageFont(.caption).foregroundStyle(.secondary)
                    } else { Text("Runtime version unknown · refresh this source.").usageFont(.caption).foregroundStyle(.secondary) }
                    ModelAvailabilityView(source: source, allowsManualCheck: true)
                    Text(source.container).usageFont(.caption, design: .monospaced).textSelection(.enabled)
                    Text("\(source.provider.title) · \(source.enabled ? "Enabled" : "Paused") · \(intervalLabel(source.interval))").usageFont(.caption).foregroundStyle(.secondary)
                    if let state = store.states[source.id] {
                        if let error = state.error { Text(error).usageFont(.caption).foregroundStyle(.orange) }
                        if let next = state.nextRefresh, store.effectiveInterval(source) > 0 { Text("Next check: \(next.formatted(date: .omitted, time: .shortened))").usageFont(.caption).foregroundStyle(.secondary) }
                        Button("Refresh source") { Task { await store.refresh(source) } }.disabled(state.isLoading || !source.enabled)
                    }
                }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            Button { editing = Source(name: "", container: "", provider: .gptmock) } label: { Label("Add container", systemImage: "plus") }
            Text("Containers with the same verified account share one quota card. Adding a source does not create or restart a container.")
                .usageFont(.caption).foregroundStyle(.secondary)
        }.sheet(item: $editing) { source in SourceEditor(source: source).environmentObject(store).usageFont(.body).environment(\.usageTextScale, store.configuration.zoom) }
    }
    func intervalLabel(_ value: Int) -> String { value < 0 ? "App default" : value == 0 ? "Manual" : "Every \(value / 60) min" }
}

struct SourceEditor: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State var source: Source
    @State private var containers: [String] = []
    @State private var discoveryError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Container connection").usageFont(.title2)
            Form {
                TextField("Display name", text: $source.name)
                Picker("Provider", selection: $source.provider) { ForEach(Provider.allCases) { Text($0.title).tag($0) } }
                TextField("Container name", text: $source.container)
                if !containers.isEmpty {
                    Picker("Detected containers", selection: $source.container) {
                        Text("Choose…").tag("")
                        if !source.container.isEmpty && !containers.contains(source.container) { Text(source.container).tag(source.container) }
                        ForEach(containers, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Refresh", selection: $source.interval) {
                    Text("App default").tag(-1); IntervalOptions()
                }
                Toggle("Enabled", isOn: $source.enabled)
            }
            if let error = discoveryError { Text(error).usageFont(.caption).foregroundStyle(.secondary) }
            HStack {
                if store.configuration.sources.contains(where: { $0.id == source.id }) {
                    Button("Remove source", role: .destructive) { store.removeSource(source); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.saveSource(source); dismiss() }.keyboardShortcut(.defaultAction).disabled(!source.isValid)
            }
        }.padding(24).frame(width: 470)
            .task {
                do { containers = try await DockerBridge.containers(configuration: store.configuration) }
                catch { discoveryError = error.localizedDescription }
            }
    }
}

struct IntervalOptions: View {
    var body: some View {
        Text("Every minute").tag(60); Text("Every 5 minutes").tag(300)
        Text("Every 15 minutes").tag(900); Text("Every 30 minutes").tag(1800)
        Text("Manual only").tag(0)
    }
}

struct MenuBarPreferences: View {
    @EnvironmentObject var store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar accounts").usageFont(.subheadline, weight: .semibold)
            Picker("Maximum accounts", selection: $store.configuration.menuMaximum) {
                ForEach(1...DisplaySelection.menuMaximum, id: \.self) { Text("\($0)").tag($0) }
            }.onChange(of: store.configuration.menuMaximum) {
                if let selected = store.configuration.menuAccountIDs {
                    store.configuration.menuAccountIDs = Array(selected.prefix(store.configuration.menuMaximum))
                }
                store.saveConfiguration()
            }
            Toggle("Choose specific accounts", isOn: Binding(
                get: { store.configuration.menuAccountIDs != nil },
                set: { enabled in
                    store.configuration.menuAccountIDs = enabled ? store.menuAccounts().map(\.id) : nil
                    store.saveConfiguration()
                }))
            if let selected = store.configuration.menuAccountIDs {
                ForEach(store.accounts) { account in
                    Toggle(account.name, isOn: Binding(
                        get: { store.configuration.menuAccountIDs?.contains(account.id) ?? false },
                        set: { included in
                            var ids = store.configuration.menuAccountIDs ?? []
                            if included && !ids.contains(account.id) && ids.count < store.configuration.menuMaximum { ids.append(account.id) }
                            if !included && ids.count > 1 { ids.removeAll { $0 == account.id } }
                            store.configuration.menuAccountIDs = ids
                            store.saveConfiguration()
                        }))
                        .disabled(selected.contains(account.id) ? selected.count == 1 : selected.count >= store.configuration.menuMaximum)
                }
                if selected.contains(where: { id in !store.accounts.contains { $0.id == id } }) {
                    Text("Some selected accounts are unavailable. Use automatic selection or choose again.").foregroundStyle(.orange)
                    Button("Choose available accounts") {
                        store.configuration.menuAccountIDs = Array(store.accounts.prefix(store.configuration.menuMaximum).map(\.id))
                        store.saveConfiguration()
                    }
                }
            }
            Text("One bar and percentage per account, in selection order. Up to four accounts; narrow displays may show fewer. Accounts sharing the same verified identity appear once.")
                .usageFont(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PreferencesView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "Mock Usage \(version) (build \(build))"
    }
    @EnvironmentObject var store: UsageStore
    @State private var dockerPath = ""
    @State private var dockerContext = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(appVersion).usageFont(.headline)
            Text("Collector protocol 1 · runtime compatibility is checked per source.").usageFont(.caption).foregroundStyle(.secondary)
            MenuBarPreferences()
            Form {
                Picker("Appearance", selection: $store.configuration.appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }.onChange(of: store.configuration.appearance) { store.saveConfiguration() }
                Picker("Default refresh", selection: $store.configuration.interval) { IntervalOptions() }
                    .onChange(of: store.configuration.interval) { store.saveConfiguration() }
                Toggle("Refresh after wake", isOn: $store.configuration.refreshAfterWake)
                    .onChange(of: store.configuration.refreshAfterWake) { store.saveConfiguration() }
                Toggle("Show preview on menu bar hover", isOn: $store.configuration.hoverPreview)
                    .onChange(of: store.configuration.hoverPreview) { store.saveConfiguration() }
                HStack {
                    Text("UI zoom")
                    Spacer()
                    Button("−") { store.changeZoom(-0.1) }.disabled(store.configuration.zoom <= 0.8)
                    Text("\(Int((store.configuration.zoom * 100).rounded()))%").monospacedDigit()
                    Button("+") { store.changeZoom(0.1) }.disabled(store.configuration.zoom >= 1.6)
                    Button("Reset") { store.resetZoom() }
                }
                Toggle("Notify at 80% and 95%", isOn: $store.configuration.notifications)
                    .onChange(of: store.configuration.notifications) {
                        store.saveConfiguration()
                        if store.configuration.notifications { store.requestNotifications() }
                    }
            }
            Text("Polling runs while this app is open and your Mac is awake. Failed reads retry at the refresh interval; provider-requested delays take priority. Percentages are never inferred from token counts.")
                .usageFont(.caption).foregroundStyle(.secondary)
            #if !WIDGET_SUPPORT
            Text("Desktop widget: use the packaged Xcode build. The Swift Package build includes the menu bar app and dashboard only.")
                .usageFont(.caption).foregroundStyle(.secondary)
            #endif
            #if WIDGET_SUPPORT
            Text("Desktop widget: add Mock Usage from the macOS widget gallery. It reads a local snapshot; macOS controls its refresh timing.")
                .usageFont(.caption).foregroundStyle(.secondary)
            #endif
            Divider()
            Form {
                TextField("Docker CLI", text: $dockerPath)
                TextField("Docker context", text: $dockerContext)
            }
            Button("Apply Docker connection") {
                store.configuration.dockerPath = dockerPath.trimmingCharacters(in: .whitespaces)
                store.configuration.dockerContext = dockerContext.trimmingCharacters(in: .whitespaces)
                store.connectionChanged()
            }.disabled(dockerPath.isEmpty || dockerContext.isEmpty)
            Text("Credentials remain inside containers. Claude and Codex resets require explicit confirmation and are sent from the container. Paid usage is never enabled by this app.")
                .usageFont(.caption).foregroundStyle(.secondary)
        }.onAppear { dockerPath = store.configuration.dockerPath; dockerContext = store.configuration.dockerContext }
    }
}
