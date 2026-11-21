import Foundation

// Feature preferences live in standardUserDefaults. The uncached reader uses
// Foundation's Bool bridge.
enum ComputerUseFeaturePreferences {
    static var cursorEnabled: Bool { read("feature/computerUseCursor", default: true) }
    static var alwaysSimulateClick: Bool { read("feature/computerUseAlwaysSimulateClick", default: false) }

    private static func read(_ key: String, default fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? fallback
    }
}
