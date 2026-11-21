import Foundation
import OSLog

/// Live `[features]` and `[screenshots]` values for code that asks on every use.
///
/// The file is read on each call, so edits apply without a restart. If the file
/// cannot be read, every feature stays off and screenshots use their defaults;
/// privacy fails closed instead (see `privacyFailingClosed`). The application
/// policy path reports the same error to the agent, so it is only logged here
/// (once per distinct error, to keep hot paths quiet).
enum AcuaSettings {
    private static let logger = Logger(subsystem: "com.aex.computeruse", category: "Configuration")
    private static let lastReportedError = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func features() -> AcuaFeatureConfiguration {
        (loadedConfiguration() ?? .defaults).features
    }

    static func screenshots() -> AcuaScreenshotConfiguration {
        (loadedConfiguration() ?? .defaults).screenshots
    }

    /// `nil` when the file cannot be read. Callers must then treat every site as
    /// blocked: falling back to the empty default list would start recording
    /// sites the user asked to keep private.
    static func privacyFailingClosed() -> AcuaPrivacyConfiguration? {
        loadedConfiguration()?.privacy
    }

    private static func loadedConfiguration() -> AcuaConfiguration? {
        do {
            let configuration = try AcuaConfigurationLoader().load()
            lastReportedError.withLock { $0 = nil }
            return configuration
        } catch let error as AcuaConfigurationError {
            report(error)
            return nil
        } catch {
            logger.error("Unexpected configuration error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func report(_ error: AcuaConfigurationError) {
        let message = error.description
        let isNew = lastReportedError.withLock { previous -> Bool in
            guard previous != message else { return false }
            previous = message
            return true
        }

        guard isNew else { return }
        logger.error("Configuration unreadable, using safe defaults: \(message, privacy: .public)")
    }
}
