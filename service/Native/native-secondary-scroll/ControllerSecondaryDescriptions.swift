import Foundation

/// Re-enumerate action names. The wrapper's published list may
/// be stale; failure returns empty before evaluating synthetic disclosure.
@MainActor struct ControllerSecondaryDescriptions {
    let actions: () throws -> [String]
    let isDisclosable: () -> Bool
    let isDisclosing: () -> Bool
    let predefined: (String) -> String?
    let description: (String) throws -> String?
    let log: (Error) -> Void
    func read() -> [ControllerSecondaryActionDescription] {
        var names: [String]
        do { names = try actions() }
        catch { log(error); return [] }
        if isDisclosable() { names.append(isDisclosing() ? "SAICollapse" : "SAIExpand") }
        return names.map { name in
            let text: String?
            if let preset = predefined(name) { text = preset }
            else {
                do { text = try description(name) }
                catch { log(error); text = nil }
            }
            return .init(name: name, description: text ?? name)
        }
    }
}
