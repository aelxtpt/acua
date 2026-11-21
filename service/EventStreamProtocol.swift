import Foundation

// EventStream wire contracts. EventStreamIPC binds them to the shared
// native producer, policy and application-group storage owner.
typealias EventStreamEndReason = ComputerUseIPCEventStreamEndReason
enum ComputerUseIPCEventStreamEndReason: String, Codable, CaseIterable {
    case toolStopped = "tool_stopped"
    case debugUIStopped = "debug_ui_stopped"
    case recordingControlsStopped = "recording_controls_stopped"
    case recordingControlsCancelled = "recording_controls_cancelled"
    case maxDuration = "max_duration"
    case serviceTerminated = "service_terminated"
}

// These Decodable witnesses consume the decoder without requesting a keyed
// container, accepting any well-formed JSON value.
struct EventStreamStartRequest: Codable, Equatable {}
struct EventStreamStatusRequest: Codable, Equatable {}
struct EventStreamStopRequest: Codable, Equatable {
    var reason: EventStreamEndReason
}

struct EventStreamSessionStatus: Codable, Equatable {
    var isRecording: Bool
    var sessionID: String?
    var sessionDirectoryPath: String?
    var eventsPath: String?
    var metadataPath: String?
    var suppressedEventsPath: String?
    var startedAt: Date?
    var endedAt: Date?
    var endReason: EventStreamEndReason?
    var maxDurationSeconds: Int
}

enum EventStreamEventKind: String, Codable, CaseIterable {
    case sessionStarted = "session.started"
    case sessionEnded = "session.ended"
    case windowChanged = "window.changed"
    case mouseClick = "mouse.click"
    case mouseContextMenu = "mouse.context_menu"
    case mouseDrag = "mouse.drag"
    case keyboardTextInput = "keyboard.text_input"
    case keyboardSubmit = "keyboard.submit"
    case keyboardShortcut = "keyboard.shortcut"
    case terminalValueChanged = "terminal.value_changed"
    case selectionChanged = "selection.changed"
    case debugError = "debug.error"
}

struct EventStreamApp: Codable, Equatable {
    var name: String?
    var secureInput: Bool
    var processIdentifier: Int32?
    var bundleIdentifier: String?
}

struct EventStreamWindow: Codable, Equatable {
    var title: String?
    var url: String?
    var windowID: UInt32?
}

struct EventStreamAXElement: Codable, Equatable {
    var role: String?
    var subrole: String?
    var title: String?
    var description: String?
    var value: String?
    var placeholder: String?
    var identifier: String?
}

struct EventStreamMouseInteractionDragEndpoint: Codable, Equatable {
    var app: EventStreamApp?
    var window: EventStreamWindow?
    var element: EventStreamAXElement?
}

struct EventStreamMouseInteraction: Codable, Equatable {
    var button: String?
    var clickCount: Int?
    var modifiers: [String]
    var target: EventStreamAXElement?
    var origin: EventStreamMouseInteractionDragEndpoint?
    var destination: EventStreamMouseInteractionDragEndpoint?
}

struct EventStreamKeyboardInteraction: Codable, Equatable {
    var text: String?
    var keyEquivalent: String?
    var modifiers: [String]
    var target: EventStreamAXElement?
}

struct EventStreamTextRange: Codable, Equatable {
    var location: Int
    var length: Int
}

struct EventStreamSelection: Codable, Equatable {
    var target: EventStreamAXElement?
    var selectedText: String?
    var selectedRange: EventStreamTextRange?
    var selectedItems: [EventStreamAXElement]
}

struct EventStreamAXTree: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case fullTree
        case diffFromPrevious
    }
    var mode: Mode
    var text: String
}

struct EventStreamDiagnostic: Codable, Equatable {
    var message: String
}

struct EventStreamRecord: Codable, Equatable {
    var id: Int
    var timestamp: Date
    var kind: EventStreamEventKind
    var app: EventStreamApp?
    var window: EventStreamWindow?
    var mouse: EventStreamMouseInteraction?
    var keyboard: EventStreamKeyboardInteraction?
    var selection: EventStreamSelection?
    var ax: EventStreamAXTree?
    var diagnostic: EventStreamDiagnostic?
}

struct EventStreamMetadata: Codable, Equatable {
    var id: String
    var eventsPath: String
    var startedAt: Date
    var endedAt: Date?
    var endReason: EventStreamEndReason?
    var eventCount: Int?
    var suppressedEventCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, segmentID, eventsPath, startedAt, endedAt, endReason, eventCount, suppressedEventCount
    }

    init(id: String, eventsPath: String, startedAt: Date, endedAt: Date? = nil,
         endReason: EventStreamEndReason? = nil, eventCount: Int? = nil, suppressedEventCount: Int? = nil) {
        self.id = id; self.eventsPath = eventsPath; self.startedAt = startedAt
        self.endedAt = endedAt; self.endReason = endReason
        self.eventCount = eventCount; self.suppressedEventCount = suppressedEventCount
    }

    // Only absent/null IDs fall through. A present invalid
    // field throws, while legacy aliases after a valid ID are never decoded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .sessionID)
            ?? c.decode(String.self, forKey: .segmentID)
        eventsPath = try c.decode(String.self, forKey: .eventsPath)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        endReason = try c.decodeIfPresent(EventStreamEndReason.self, forKey: .endReason)
        eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount)
        suppressedEventCount = try c.decodeIfPresent(Int.self, forKey: .suppressedEventCount)
    }

    // Write only the current ID key.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(eventsPath, forKey: .eventsPath)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(endReason, forKey: .endReason)
        try c.encodeIfPresent(eventCount, forKey: .eventCount)
        try c.encodeIfPresent(suppressedEventCount, forKey: .suppressedEventCount)
    }
}

// Custom Codable witnesses. Default-valued fields are omitted;
// absent/null collections decode as empty and absent/null secureInput as false.
extension EventStreamApp {
    private enum CodingKeys:String,CodingKey {case name,secureInput,processIdentifier,bundleIdentifier}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        name=try c.decodeIfPresent(String.self,forKey:.name)
        secureInput=try c.decodeIfPresent(Bool.self,forKey:.secureInput) ?? false
        processIdentifier=try c.decodeIfPresent(Int32.self,forKey:.processIdentifier)
        bundleIdentifier=try c.decodeIfPresent(String.self,forKey:.bundleIdentifier)
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encodeIfPresent(name,forKey:.name)
        if secureInput {try c.encode(true,forKey:.secureInput)}
        try c.encodeIfPresent(processIdentifier,forKey:.processIdentifier)
        try c.encodeIfPresent(bundleIdentifier,forKey:.bundleIdentifier)
    }
}
extension EventStreamMouseInteraction {
    private enum CodingKeys:String,CodingKey {case button,clickCount,modifiers,target,origin,destination}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        button=try c.decodeIfPresent(String.self,forKey:.button)
        clickCount=try c.decodeIfPresent(Int.self,forKey:.clickCount)
        modifiers=try c.decodeIfPresent([String].self,forKey:.modifiers) ?? []
        target=try c.decodeIfPresent(EventStreamAXElement.self,forKey:.target)
        origin=try c.decodeIfPresent(EventStreamMouseInteractionDragEndpoint.self,forKey:.origin)
        destination=try c.decodeIfPresent(EventStreamMouseInteractionDragEndpoint.self,forKey:.destination)
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encodeIfPresent(button,forKey:.button)
        if clickCount != 1 {try c.encodeIfPresent(clickCount,forKey:.clickCount)}
        if !modifiers.isEmpty {try c.encode(modifiers,forKey:.modifiers)}
        try c.encodeIfPresent(target,forKey:.target)
        try c.encodeIfPresent(origin,forKey:.origin)
        try c.encodeIfPresent(destination,forKey:.destination)
    }
}
extension EventStreamKeyboardInteraction {
    private enum CodingKeys:String,CodingKey {case text,keyEquivalent,modifiers,target}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        text=try c.decodeIfPresent(String.self,forKey:.text)
        keyEquivalent=try c.decodeIfPresent(String.self,forKey:.keyEquivalent)
        modifiers=try c.decodeIfPresent([String].self,forKey:.modifiers) ?? []
        target=try c.decodeIfPresent(EventStreamAXElement.self,forKey:.target)
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encodeIfPresent(text,forKey:.text)
        try c.encodeIfPresent(keyEquivalent,forKey:.keyEquivalent)
        if !modifiers.isEmpty {try c.encode(modifiers,forKey:.modifiers)}
        try c.encodeIfPresent(target,forKey:.target)
    }
}
extension EventStreamSelection {
    private enum CodingKeys:String,CodingKey {case target,selectedText,selectedRange,selectedItems}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        target=try c.decodeIfPresent(EventStreamAXElement.self,forKey:.target)
        selectedText=try c.decodeIfPresent(String.self,forKey:.selectedText)
        selectedRange=try c.decodeIfPresent(EventStreamTextRange.self,forKey:.selectedRange)
        selectedItems=try c.decodeIfPresent([EventStreamAXElement].self,forKey:.selectedItems) ?? []
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encodeIfPresent(target,forKey:.target)
        try c.encodeIfPresent(selectedText,forKey:.selectedText)
        try c.encodeIfPresent(selectedRange,forKey:.selectedRange)
        if !selectedItems.isEmpty {try c.encode(selectedItems,forKey:.selectedItems)}
    }
}
