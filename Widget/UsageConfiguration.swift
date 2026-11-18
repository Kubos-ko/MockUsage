import AppIntents

/// Store stable scalar IDs rather than AppEntity references. Some local ad-hoc
/// installations cannot resolve the entity registry while generating timelines.
struct UsageAccountOptions: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> {
        let items = [IntentItem("__automatic__", title: "Automatic / not selected")] + WidgetSnapshotFile.read().map {
            IntentItem($0.id, title: "\($0.name)")
        }
        return IntentItemCollection(sections: [IntentItemSection(items: items)])
    }
}

struct UsageConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage accounts"
    static let description = IntentDescription("Choose accounts from Mock Usage. Small: one, medium: up to two, large: up to three. Leave all fields empty for automatic selection.")

    @Parameter(title: "Primary account", optionsProvider: UsageAccountOptions()) var primaryAccountID: String?
    @Parameter(title: "Second account (optional)", optionsProvider: UsageAccountOptions()) var secondAccountID: String?
    @Parameter(title: "Third account (optional)", optionsProvider: UsageAccountOptions()) var thirdAccountID: String?

    static var parameterSummary: some ParameterSummary {
        Switch(.widgetFamily) {
            Case(.systemSmall) { Summary { \.$primaryAccountID } }
            Case(.systemMedium) { Summary { \.$primaryAccountID; \.$secondAccountID } }
            DefaultCase { Summary { \.$primaryAccountID; \.$secondAccountID; \.$thirdAccountID } }
        }
    }

    func accounts(limit: Int) -> [WidgetAccount] {
        let available = WidgetSnapshotFile.read()
        // Ignore slots hidden by the current size, including after resizing a widget.
        let slots = Array([primaryAccountID, secondAccountID, thirdAccountID].prefix(limit))
        let selected = slots.compactMap { $0 }.filter { $0 != "__automatic__" }
        let ids = DisplaySelection.identifiers(available: available.map(\.id),
            selected: selected.isEmpty ? nil : selected, limit: limit)
        return ids.compactMap { id in available.first { $0.id == id } }
    }
}
