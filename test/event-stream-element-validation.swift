import Foundation

@main enum ElementValidationTests {
    static func main() {
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            precondition(condition, name); checks += 1; print("PASS \(name)")
        }
        var original = EventStreamTransformedNode(element: 1)
        original.role = "AXTextArea"; original.subrole = "AXSearchField"
        original.roleDescription = "editor"; original.title = "Document"
        original.description = "Contents"; original.value = "before"
        original.valueDescription = "editable"; original.placeholderValue = "Type here"
        original.help = "Help"; original.identifier = "editor"
        original.url = URL(string: "https://example.test/document")
        var fresh = original
        fresh = EventStreamTransformedNode(element: 2, role: original.role, subrole: original.subrole,
            roleDescription: original.roleDescription, title: original.title, description: original.description,
            value: original.value, valueDescription: original.valueDescription, placeholderValue: original.placeholderValue,
            help: original.help, identifier: original.identifier, url: original.url)
        check("replacement identity alone does not invalidate a matching control",
              EventStreamElementValidation.matches(original, fresh, ignoreValueChange: false))
        fresh.isEnabled = false; fresh.actionDescriptions = [.init(name: "AXPress", description: "Press")]
        check("enabled state and action enumeration are excluded by the predicate",
              EventStreamElementValidation.matches(original, fresh, ignoreValueChange: false))
        fresh.subrole = nil
        check("missing subrole differs from the original subrole",
              !EventStreamElementValidation.matches(original, fresh, ignoreValueChange: true))
        fresh = original; fresh.roleDescription = "different editor"
        check("role description remains part of validation even when values may change",
              !EventStreamElementValidation.matches(original, fresh, ignoreValueChange: true))
        fresh = original; fresh.value = "after"
        check("ordinary action detects a changed value",
              !EventStreamElementValidation.matches(original, fresh, ignoreValueChange: false))
        check("selection may explicitly ignore the changed value",
              EventStreamElementValidation.matches(original, fresh, ignoreValueChange: true))
        fresh.placeholderValue = nil
        check("ignore-value does not also ignore the placeholder",
              !EventStreamElementValidation.matches(original, fresh, ignoreValueChange: true))
        fresh = original; fresh.value = nil
        check("ignore-value also accepts a missing optional value",
              EventStreamElementValidation.matches(original, fresh, ignoreValueChange: true))
        fresh = original; fresh.title = "cafe\u{301}"; original.title = "café"
        check("validation preserves Swift canonical string equality",
              EventStreamElementValidation.matches(original, fresh, ignoreValueChange: false))
        fresh.url = URL(string: "https://example.test/other")
        check("different source URLs cannot recover the control",
              !EventStreamElementValidation.matches(original, fresh, ignoreValueChange: false))
        print("\(checks) reference-derived element validation checks passed")
    }
}
