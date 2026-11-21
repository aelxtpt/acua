import Foundation
import IOKit.pwr_mgt
import os

enum NativeRequestActivity {
    private static let logger = Logger(subsystem: "com.aex.computeruse", category: "request-activity")
    static func make() -> RequestActivity {
        RequestActivity(provider: .init(create: { kind, assertion in
            let name = "Aex Computer Use interaction" as CFString
            switch kind {
            case .remoteUserActivity:
                return IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveRemote, &assertion)
            case .displaySleepPrevention:
                return IOPMAssertionCreateWithDescription("PreventUserIdleDisplaySleep" as CFString, name,
                    "Keeping the display awake while Computer Use handles a request." as CFString,
                    nil, nil, 0, nil, &assertion)
            }
        }, release: { IOPMAssertionRelease($0) }, failed: { kind, status in
            logger.error("Could not acquire \(kind.rawValue, privacy: .public): \(status)")
        }))
    }
}
