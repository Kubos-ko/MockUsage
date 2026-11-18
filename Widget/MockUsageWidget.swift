import SwiftUI
import WidgetKit
import AppIntents

struct UsageEntry: TimelineEntry {
    let date: Date
    let accounts: [WidgetAccount]
}

struct UsageTimeline: AppIntentTimelineProvider {
    typealias Intent = UsageConfiguration
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: .now, accounts: []) }
    func snapshot(for configuration: UsageConfiguration, in context: Context) async -> UsageEntry {
        let limit = capacity(context.family)
        let accounts = configuration.accounts(limit: limit)
        WidgetSnapshotFile.recordTimeline(capacity: limit, selectedSlots: [configuration.primary, configuration.second, configuration.third].compactMap { $0 }.count,
                                          accountCount: accounts.count)
        return UsageEntry(date: .now, accounts: accounts)
    }
    func timeline(for configuration: UsageConfiguration, in context: Context) async -> Timeline<UsageEntry> {
        let entry = await snapshot(for: configuration, in: context)
        let staleDates = Set(entry.accounts.map { $0.snapshot.capturedDate.addingTimeInterval(900) })
            .filter { $0 > entry.date }.sorted()
        return Timeline(entries: [entry] + staleDates.map { UsageEntry(date: $0, accounts: entry.accounts) },
                        policy: .after(Date().addingTimeInterval(900)))
    }
    private func capacity(_ family: WidgetFamily) -> Int {
        family == .systemSmall ? 1 : family == .systemMedium ? 2 : 3
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UsageEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Mock Usage", systemImage: "chart.bar.xaxis").font(.system(size: family == .systemLarge ? 16 : 14, weight: .semibold))
            if entry.accounts.isEmpty {
                Text("Open Mock Usage to refresh accounts, then choose them in Edit Widget.").font(.caption).foregroundStyle(.secondary)
            } else {
                let layout = family == .systemMedium ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                layout {
                  ForEach(entry.accounts.prefix(family == .systemSmall ? 1 : family == .systemLarge ? 3 : 2)) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        let dense = family == .systemLarge && entry.accounts.count == 3
                        HStack(alignment: .firstTextBaseline) {
                        Text(account.name).font(.system(size: family == .systemLarge ? 14 : 13, weight: .semibold)).lineLimit(1)
                        if dense { Spacer(minLength: 4) }
                        if dense, let used = account.snapshot.mostUsed { Text("\(Int(used))%").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit() }
                        }
                        if !(family == .systemLarge && entry.accounts.count == 3), let used = account.snapshot.mostUsed { Text("\(Int(used))% used").font(.system(size: family == .systemLarge ? 26 : 22, weight: .semibold, design: .rounded)).monospacedDigit() }
                        if let window = account.snapshot.windows.max(by: { $0.usedPercent < $1.usedPercent }) {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.secondary.opacity(0.2))
                                    Capsule().fill(account.snapshot.provider == .gptmock ? Color.mint : Color.orange)
                                        .frame(width: geometry.size.width * min(100, max(0, window.usedPercent)) / 100)
                                }
                            }.frame(height: 7)
                                .accessibilityLabel("Usage")
                                .accessibilityValue("\(Int(window.usedPercent)) percent")
                            if family != .systemSmall {
                                Text(window.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if !dense, let date = window.resetDate {
                                HStack { Text("Reset"); Text(date, style: .relative) }.font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        } else { Text("Quota unavailable").font(.system(size: 11)).foregroundStyle(.secondary) }
                        HStack(spacing: 3) {
                            Text(account.isLive && entry.date.timeIntervalSince(account.snapshot.capturedDate) < 900 ? "Measured" : "Last known")
                            Text(account.snapshot.capturedDate, style: .time)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                      .accessibilityElement(children: .combine)
                  }
                }

            }
            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "mockusage://overview"))
    }
}

@main
struct MockUsageWidget: Widget {
    let kind = "MockUsageWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: UsageConfiguration.self, provider: UsageTimeline()) { UsageWidgetView(entry: $0) }
            .configurationDisplayName("Mock Usage")
            .description("Account usage from your local GPTMock and Claude containers.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
