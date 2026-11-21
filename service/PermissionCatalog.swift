import Foundation
import CoreGraphics

protocol PermissionRequirementProviding: Sendable {
    var identifier: String { get }
}

/// Construction data for the concrete provider values. Their native
/// status/grant adapters are separate owners; this descriptor invokes neither.
enum PermissionProviderDescriptor: PermissionRequirementProviding {
    case accessibility, screenRecording, fullDiskAccess, automationMessages
    case calendar(identifier: String), contacts(identifier: String)
    case named(String)
    var identifier: String {
        switch self {
        case .accessibility: "system_settings_Privacy_Accessibility"
        case .screenRecording: "system_settings_Privacy_ScreenCapture"
        case .fullDiskAccess: "system_settings_Privacy_AllFiles"
        case .automationMessages: "apple_events_com.apple.MobileSMS"
        case let .calendar(id), let .contacts(id), let .named(id): id
        }
    }
}

/// Retain the provider value and snapshot its identifier once.
/// Equality/hash use that snapshot, independently of concrete provider identity.
struct PermissionRequirement: Hashable, Sendable {
    let provider: any PermissionRequirementProviding
    let identifier: String
    init(_ provider: any PermissionRequirementProviding) { self.provider = provider;identifier = provider.identifier }
    init(identifier: String) { self.init(PermissionProviderDescriptor.named(identifier)) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identifier == rhs.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
    static let accessibility = Self(PermissionProviderDescriptor.accessibility)
    static let screenRecording = Self(PermissionProviderDescriptor.screenRecording)
    static let fullDiskAccess = Self(PermissionProviderDescriptor.fullDiskAccess)
    static let calendar = Self(PermissionProviderDescriptor.calendar(identifier: "eventkit_events"))
    static let contacts = Self(PermissionProviderDescriptor.contacts(identifier: "contacts"))
    static let automationMessages = Self(PermissionProviderDescriptor.automationMessages)
}

/// Permission sources and the provider factories for each.
struct PermissionCatalog: Sendable {
    enum Source: UInt8, Sendable { case appshot, calendar, computerUse, development, messages, timeline }
    enum ServiceSource: UInt8, Sendable { case computerUse, appshot, timeline }
    enum HeaderIcon: Equatable, Sendable {
        case application(bundleIdentifier: String), symbol(String), currentApplication
    }
    struct Row: Sendable {
        enum Icon: Equatable, Sendable {
            case application(bundleIdentifier: String, fallbackSymbol: String)
            case bundle(path: String, fallbackSymbol: String)
            case contentType(identifier: String, fallbackSymbol: String)
            case symbol(String)
        }
        let permission: PermissionRequirement
        let title: String
        let subtitle: String
        let icon: Icon
        let iconFrameSize: CGFloat
        let isSupplemental: Bool
    }
    let title: String
    let description: String
    let headerIcon: HeaderIcon
    let rows: [Row]
    let requestSource: Source

    static func service(source: ServiceSource) -> Self {
        let accessibility = Row(permission: .accessibility, title: "Accessibility",
            subtitle: source == .appshot ? "Allows the agent to read the text in apps" : "Allows the agent to access app interfaces",
            icon: .symbol("accessibility"), iconFrameSize: 59, isSupplemental: false)
        let screenshots = Row(permission: .screenRecording, title: "Screenshots",
            subtitle: source == .computerUse ? "The agent uses screenshots to know where to click" : "Allows the agent to see the visuals in apps",
            icon: .symbol("camera.viewfinder"), iconFrameSize: 44, isSupplemental: false)
        let rows = [accessibility, screenshots]
        switch source {
        case .computerUse:
            return .init(title: "Enable Aex Computer Use",
                description: "Aex Computer Use needs these permissions to use apps on your Mac.\nThese permissions are used when you ask an agent to perform tasks.",
                headerIcon: .currentApplication, rows: rows, requestSource: .computerUse)
        case .appshot:
            return .init(title: "Enable Appshots",
                description: "Aex Computer Use needs these permissions to take appshots. Appshots are captured when you attach from the + menu or press both command keys simultaneously.",
                headerIcon: .symbol("macwindow.on.rectangle"), rows: rows, requestSource: .appshot)
        case .timeline:
            return .init(title: "Enable Aex Computer History",
                description: "Aex Computer Use needs permission to privately capture activity on your Mac so that it can help you pick up where you left off.",
                headerIcon: .symbol("clock.arrow.circlepath"), rows: rows, requestSource: .timeline)
        }
    }
    static let calendar = Self(title: "Enable Aex Computer Use with Calendar",
        description: "Aex Computer Use uses Calendar to read and manage your events.",
        headerIcon: .application(bundleIdentifier: "com.apple.iCal"), rows: [
            .init(permission: .calendar, title: "Calendar", subtitle: "Allows reading and managing your events when asked",
                  icon: .application(bundleIdentifier: "com.apple.iCal", fallbackSymbol: "calendar"), iconFrameSize: 48, isSupplemental: false)
        ], requestSource: .calendar)
    static let messages = Self(title: "Enable Aex Computer Use with Messages",
        description: "By default, Aex Computer Use uses messages only from conversations you approve to answer your requests, and sends messages only after you approve the message and its recipients.",
        headerIcon: .application(bundleIdentifier: "com.apple.MobileSMS"), rows: [
            .init(permission: .automationMessages, title: "Automation", subtitle: "Allows sending messages",
                  icon: .contentType(identifier: "com.apple.graphic-icon.automation", fallbackSymbol: "gearshape.2.fill"), iconFrameSize: 48, isSupplemental: false),
            .init(permission: .contacts, title: "Contacts", subtitle: "Enables finding contacts by name",
                  icon: .application(bundleIdentifier: "com.apple.AddressBook", fallbackSymbol: "person.crop.circle.fill"), iconFrameSize: 48, isSupplemental: false),
            .init(permission: .accessibility, title: "Accessibility", subtitle: "Start a new multi-person conversation",
                  icon: .symbol("accessibility"), iconFrameSize: 48, isSupplemental: false),
            .init(permission: .fullDiskAccess, title: "Full Disk Access", subtitle: "Allows searching your messages when asked",
                  icon: .bundle(path: "/System/Library/ExtensionKit/Extensions/StartupDisk.appex", fallbackSymbol: "internaldrive.fill"), iconFrameSize: 44, isSupplemental: false)
        ], requestSource: .messages)
}
