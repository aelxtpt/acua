import Foundation

/// Finds the first rendered button whose label matches one of the given labels.
enum AccessibilityButtonSearch {
    struct Fields {
        var role: String
        var title: String? = nil
        var description: String? = nil
        var value: String? = nil
        var valueDescription: String? = nil
        var help: String? = nil
    }

    static func matches(_ fields: Fields, labels: Set<String>) -> Bool {
        guard fields.role == "AXButton" else { return false }
        return [fields.title, fields.description, fields.value, fields.valueDescription, fields.help]
            .compactMap { $0 }
            .contains { labels.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func find<IDs: Sequence>(in ids: IDs, labels: Set<String>,
                                   item: (Int) -> Fields?) -> Int? where IDs.Element == Int? {
        for case let id? in ids {
            if let fields = item(id), matches(fields, labels: labels) { return id }
        }
        return nil
    }
}
