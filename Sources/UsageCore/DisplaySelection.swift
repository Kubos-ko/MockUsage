import Foundation

/// Shared deterministic selection rules for widgets and the menu bar.
public enum DisplaySelection {
    public static let menuMaximum = 4

    public static func identifiers(available: [String], selected: [String]?, limit: Int) -> [String] {
        let capacity = max(1, limit)
        let choices = selected ?? available
        var seen = Set<String>()
        return Array(choices.filter { available.contains($0) && seen.insert($0).inserted }.prefix(capacity))
    }
}
