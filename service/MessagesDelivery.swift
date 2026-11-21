import AppKit
import ApplicationServices
import Carbon
import Intents
import ScriptingBridge
import UniformTypeIdentifiers

enum MessagesDelivery {
    private static let bundleID = "com.apple.MobileSMS"

    enum Failure: Error {
        case unavailable, destination, composer, content, notCleared
    }

    static func deliver(_ attempt: MessagesSendPlans.Attempt, files: MessagesSendFiles,
                        checkpoint: @escaping @Sendable () throws -> Void) async throws {
        switch attempt.target.kind {
        case .existingChat:
            try existing(attempt, urls: files.urls, checkpoint: checkpoint)
        case .newDirectMessage, .newGroupMessage:
            try await newConversation(attempt, urls: files.urls, checkpoint: checkpoint)
        }
    }

    private final class ScriptErrors: NSObject, SBApplicationDelegate {
        var error: (any Error)?

        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
            self.error = error
            return nil
        }
    }

    private static func existing(_ attempt: MessagesSendPlans.Attempt, urls: [URL], checkpoint: () throws -> Void) throws {
        try checkpoint()
        guard let guid = attempt.target.chatGUID, let app = SBApplication(bundleIdentifier: bundleID) else {
            throw Failure.unavailable
        }
        let errors = ScriptErrors()
        app.delegate = errors
        defer { app.delegate = nil }
        let sendSelector = NSSelectorFromString("send:to:")
        guard app.responds(to: sendSelector), let implementation = app.method(for: sendSelector) else {
            throw Failure.unavailable
        }
        func chat(in owner: NSObject) -> SBObject? {
            let selector = NSSelectorFromString("chats")
            guard owner.responds(to: selector),
                  let chats = owner.perform(selector)?.takeUnretainedValue() as? SBElementArray else { return nil }
            return chats.object(withID: guid) as? SBObject
        }
        func exists(_ chat: SBObject) -> Bool {
            let selector = NSSelectorFromString("exists:")
            guard app.responds(to: selector), let method = app.method(for: selector) else { return false }
            return unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector, AnyObject) -> Bool).self)(app, selector, chat)
        }

        var destination: SBObject?
        if guid.hasPrefix("any;"), let service = attempt.target.service, let code = serviceCode(service) {
            let selector = NSSelectorFromString("accounts")
            if app.responds(to: selector), let accounts = app.perform(selector)?.takeUnretainedValue() as? SBElementArray {
                let predicate = NSPredicate(format: "serviceType == %@", NSAppleEventDescriptor(enumCode: code))
                if let account = accounts.filtered(using: predicate).first as? NSObject,
                   let candidate = chat(in: account), exists(candidate) {
                    destination = candidate
                }
            }
        }
        errors.error = nil
        guard let destination = destination ?? chat(in: app), exists(destination), errors.error == nil else {
            throw Failure.destination
        }
        let send = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void).self)
        var objects: [AnyObject] = []
        if let text = attempt.text, !text.isEmpty { objects.append(text as NSString) }
        objects.append(contentsOf: urls.map { $0 as NSURL })
        for object in objects {
            try checkpoint()
            send(app, sendSelector, object, destination)
            if let error = errors.error { throw error }
        }
    }

    static func serviceCode(_ service: MessagesIPCService) -> UInt32? {
        switch service {
        case .iMessage, .iMessageLite: return 0x696d7367 // imsg
        case .sms, .rcs, .satelliteSMS: return 0x736d7373 // smss
        case .unknown: return nil
        }
    }

    static func composeURL(_ attempt: MessagesSendPlans.Attempt) throws -> URL {
        let addresses = attempt.target.participants.map(\.handle)
        guard !addresses.isEmpty, addresses.allSatisfy({ !$0.isEmpty && !$0.contains(",") }) else {
            throw Failure.destination
        }
        var parts = URLComponents()
        parts.scheme = "sms"
        parts.host = "open"
        var query = [URLQueryItem(name: "addresses", value: addresses.joined(separator: ","))]
        if let body = attempt.text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            query.append(.init(name: "body", value: body))
        }
        parts.queryItems = query
        guard let url = parts.url else { throw Failure.destination }
        return url
    }

    @MainActor
    static func composeEvent(_ attempt: MessagesSendPlans.Attempt, urls: [URL], applicationURL: URL) throws -> NSAppleEventDescriptor {
        let recipients = attempt.target.participants.map {
            INPerson(personHandle: INPersonHandle(value: $0.handle, type: .unknown),
                nameComponents: nil, displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: nil)
        }
        guard !recipients.isEmpty else { throw Failure.destination }
        let attachmentSelector = NSSelectorFromString("attachmentWithFile:")
        guard let attachmentMethod = class_getClassMethod(INSendMessageAttachment.self, attachmentSelector) else {
            throw Failure.unavailable
        }
        let attachment = unsafeBitCast(method_getImplementation(attachmentMethod),
            to: (@convention(c) (AnyClass, Selector, INFile) -> Unmanaged<INSendMessageAttachment>?).self)
        let attachments = try urls.map { url in
            let type = UTType(filenameExtension: url.pathExtension)?.identifier
            let file = INFile(fileURL: url, filename: url.lastPathComponent, typeIdentifier: type)
            guard let value = attachment(INSendMessageAttachment.self, attachmentSelector, file)?.takeUnretainedValue()
            else { throw Failure.content }
            return value
        }
        let intent = INSendMessageIntent(recipients: recipients, outgoingMessageType: .outgoingMessageText,
            content: attempt.text, speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil,
            sender: nil, attachments: attachments)
        let activity = NSUserActivity(activityType: NSStringFromClass(INSendMessageIntent.self))
        let interaction = INInteraction(intent: intent, response: nil)
        let set = NSSelectorFromString("_setInteraction:donate:")
        let encode = NSSelectorFromString("_createUserActivityDataWithSaving:options:error:")
        guard activity.responds(to: set), activity.responds(to: encode),
              let setter = activity.method(for: set), let encoder = activity.method(for: encode) else {
            throw Failure.unavailable
        }
        unsafeBitCast(setter, to: (@convention(c) (AnyObject, Selector, INInteraction, Bool) -> Void).self)(activity, set, interaction, false)
        let data = unsafeBitCast(encoder, to: (@convention(c) (AnyObject, Selector, Bool, NSDictionary?, UnsafeMutableRawPointer?) -> Unmanaged<NSData>?).self)
        guard let payload = data(activity, encode, false, nil, nil)?.takeUnretainedValue() else {
            throw Failure.content
        }
        let event = NSAppleEventDescriptor(eventClass: 0x61657674, eventID: 0x6374706f,
            targetDescriptor: NSAppleEventDescriptor(applicationURL: applicationURL), returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: UUID().uuidString), forKeyword: 0x2d2d2d2d)
        event.setParam(NSAppleEventDescriptor(string: activity.activityType), forKeyword: 0x70746175)
        guard let encoded = NSAppleEventDescriptor(descriptorType: 0x61746474, data: payload as Data) else {
            throw Failure.content
        }
        event.setParam(encoded, forKeyword: 0x74646175)
        return event
    }

    @MainActor
    private static func newConversation(_ attempt: MessagesSendPlans.Attempt, urls: [URL],
                                        checkpoint: @escaping @Sendable () throws -> Void) async throws {
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else { throw Failure.unavailable }
        try checkpoint()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        let app: NSRunningApplication
        if urls.isEmpty {
            let url = try composeURL(attempt)
            app = try await workspace.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            config.appleEvent = try composeEvent(attempt, urls: urls, applicationURL: appURL)
            app = try await workspace.openApplication(at: appURL, configuration: config)
        }
        guard app.bundleIdentifier == bundleID, !app.isTerminated else { throw Failure.destination }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        let expected = urls.isEmpty ? attempt.text?.trimmingCharacters(in: .whitespacesAndNewlines) : attempt.text
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var didSend = false
        while clock.now < deadline {
            try checkpoint()
            if let composer = focusedComposer(root),
               composerMatches(composer.value, expected: expected, attachmentCount: urls.count),
               let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) {
                try checkpoint()
                guard let current = focusedComposer(root), CFEqual(current.element, composer.element),
                      composerMatches(current.value, expected: expected, attachmentCount: urls.count) else {
                    throw Failure.composer
                }
                for event in [down, up] {
                    UserInteraction.markSynthesized(event)
                    event.postToPid(app.processIdentifier)
                }
                didSend = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard didSend else { throw Failure.composer }
        let confirmation = clock.now.advanced(by: .seconds(5))
        while clock.now < confirmation {
            try checkpoint()
            if let composer = focusedComposer(root), composer.value?.isEmpty != false { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.notCleared
    }

    private static func focusedComposer(_ root: AXUIElement) -> (element: AXUIElement, value: String?)? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var identifier: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier) == .success,
              identifier as? String == "messageBodyField" else { return nil }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        return (element, value as? String)
    }

    static func composerMatches(_ value: String?, expected: String?, attachmentCount: Int) -> Bool {
        guard let value, !value.isEmpty else { return false }
        if attachmentCount == 0 { return value == expected }
        let marker: Unicode.Scalar = "\u{FFFC}"
        let parts = value.unicodeScalars.split(separator: marker, omittingEmptySubsequences: false)
        return parts.count - 1 == attachmentCount && parts.map(String.init).joined() == (expected ?? "")
    }
}
