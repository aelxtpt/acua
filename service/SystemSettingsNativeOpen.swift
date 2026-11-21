import AppKit

extension SystemSettingsOpenEnvironment where Application == SystemSettingsNativeApplication {
    static var native: Self {
        .init { url, activates, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activates
            NSWorkspace.shared.open(url, configuration: configuration) { application, error in
                completion(application.map(SystemSettingsNativeApplication.init), error)
            }
        }
    }
}
