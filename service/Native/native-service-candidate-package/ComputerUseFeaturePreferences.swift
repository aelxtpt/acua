import Foundation

// Feature flag store: the empty app-group constant selects
// standardUserDefaults. The uncached reader uses Foundation's Bool bridge.
enum ComputerUseFeaturePreferences {
    static var overrideFogTexture: Bool { read("feature/overrideFogSamplingTexture", default: false) }
    static var cursorEnabled: Bool { read("feature/computerUseCursor", default: true) }
    static var alwaysSimulateClick: Bool { read("feature/computerUseAlwaysSimulateClick", default: false) }

    private static func read(_ key: String, default fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? fallback
    }
}
