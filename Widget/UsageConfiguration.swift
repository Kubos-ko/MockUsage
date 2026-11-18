import AppIntents

/// Only sanitized snapshot metadata is exposed to the widget editor.
struct UsageAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Usage account")
    static let defaultQuery = UsageAccountQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct UsageAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [UsageAccountEntity] {
        let accounts = WidgetSnapshotFile.read()
        return identifiers.map { id in
            UsageAccountEntity(id: id, name: accounts.first { $0.id == id }?.name ?? "Unavailable account")
        }
    }
    func suggestedEntities() async throws -> [UsageAccountEntity] {
        WidgetSnapshotFile.read().map { UsageAccountEntity(id: $0.id, name: $0.name) }
    }
}

struct UsageConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage accounts"
    static let description = IntentDescription("Choose accounts from Mock Usage. Small: one, medium: up to two, large: up to three. Leave all fields empty for automatic selection.")

    @Parameter(title: "Primary account") var primary: UsageAccountEntity?
    @Parameter(title: "Second account (optional)") var second: UsageAccountEntity?
    @Parameter(title: "Third account (optional)") var third: UsageAccountEntity?

    static var parameterSummary: some ParameterSummary {
        Switch(.widgetFamily) {
            Case(.systemSmall) { Summary { \.$primary } }
            Case(.systemMedium) { Summary { \.$primary; \.$second } }
            DefaultCase { Summary { \.$primary; \.$second; \.$third } }
        }
    }

    func accounts(limit: Int) -> [WidgetAccount] {
        let available = WidgetSnapshotFile.read()
        // Ignore slots hidden by the current size, including after resizing a widget.
        let slots = Array([primary, second, third].prefix(limit))
        let selected = slots.compactMap { $0?.id }
        let ids = DisplaySelection.identifiers(available: available.map(\.id),
            selected: selected.isEmpty ? nil : selected, limit: limit)
        return ids.compactMap { id in available.first { $0.id == id } }
    }
}
