import Foundation
import AppKit
import ApplicationServices

enum EventStreamTerminalBundleIdentifiers {
    // Known terminal applications; preserve exact membership/case.
    static let all=["com.apple.Terminal","com.googlecode.iterm2","org.alacritty",
        "dev.warp.Warp-Stable","net.kovidgoyal.kitty","co.zeit.hyper",
        "com.github.wez.wezterm","org.tabby","com.mitchellh.ghostty",
        "com.raphaelamorim.rio","dev.commandline.waveterm"]
}

extension EventStreamRecorderAXObservationPolicy {
    static func notifications(bundleIdentifier:String?)->[String] {
        notifications(bundleIdentifier:bundleIdentifier,terminalBundleIdentifiers:EventStreamTerminalBundleIdentifiers.all)
    }
}

struct EventStreamPendingTerminalRecord<Element> {
    let identity:EventStreamRecordIdentity?
    let target:EventStreamAXElement
    let element:Element?
    let app:EventStreamApp?
    let window:EventStreamWindow?
}

// Terminal branch: the caller owns recording/application-policy gates.
@MainActor
struct EventStreamTerminalCapture<Reference,Node> {
    struct Backend {
        var wrap:(Reference)->Node
        var secureInputPID:()->Int?
        var role:(Node)->String?
        var nextIdentity:()->EventStreamRecordIdentity
        var target:(Node)->EventStreamAXElement
        var application:(Int32)->EventStreamApp?
        var window:(Node)->EventStreamWindow?
    }
    let backend:Backend
    func make(element:Reference,processIdentifier pid:Int32,bundleIdentifier:String?)->EventStreamPendingTerminalRecord<Reference>? {
        let node=backend.wrap(element)
        guard let bundleIdentifier,EventStreamTerminalBundleIdentifiers.all.contains(bundleIdentifier),
              pid>0,backend.secureInputPID()==Int(pid),backend.role(node)=="AXTextArea" else {return nil}
        // This path allocates identity BEFORE descriptors/context, unlike the
        // selection builder. Each notification replaces the whole old buffer.
        let identity=backend.nextIdentity()
        let target=backend.target(node)
        let app=backend.application(pid)
        let window=backend.window(node)
        return .init(identity:identity,target:target,element:element,app:app,window:window)
    }
}

// Metadata/identity are captured; the target descriptor
// is refreshed at flush using its retained element, when present.
@MainActor
final class EventStreamTerminalValueRecorder<Element> {
    private let nextIdentity:()->EventStreamRecordIdentity
    private let refreshTarget:(Element)->EventStreamAXElement
    private let isRecording:()->Bool
    private let sleep:(Duration) async throws->Void
    private let lifetimeOwner:()->AnyObject?
    private let emit:(EventStreamRecord)->Void
    private var pending:EventStreamPendingTerminalRecord<Element>?
    private var flushTask:Task<Void,Never>?
    var hasPendingRecord:Bool {pending != nil}
    var hasScheduledFlush:Bool {flushTask != nil}

    init(nextIdentity:@escaping ()->EventStreamRecordIdentity,
         refreshTarget:@escaping (Element)->EventStreamAXElement,
         isRecording:@escaping ()->Bool,
         sleep:@escaping (Duration) async throws->Void = {try await ContinuousClock().sleep(for:$0)},
         lifetimeOwner:@escaping ()->AnyObject? = {nil},
         emit:@escaping (EventStreamRecord)->Void) {
        self.nextIdentity=nextIdentity;self.refreshTarget=refreshTarget
        self.isRecording=isRecording;self.sleep=sleep;self.emit=emit
        self.lifetimeOwner=lifetimeOwner
    }
    func store(_ record:EventStreamPendingTerminalRecord<Element>) {
        pending=record
        flushTask?.cancel()
        let owner=lifetimeOwner()
        flushTask=Task { @MainActor [self,owner] in
            defer {withExtendedLifetime(owner) {}}
            try? await sleep(.milliseconds(750))
            guard !Task.isCancelled,isRecording() else {return}
            flush()
        }
    }
    func flush() {
        guard let record=pending else {return}
        let target=record.element.map(refreshTarget) ?? record.target
        pending=nil
        cancelPendingFlush()
        let identity=record.identity ?? nextIdentity()
        emit(.init(id:identity.id,timestamp:identity.timestamp,kind:.terminalValueChanged,
            app:record.app,window:record.window,
            keyboard:.init(text:nil,keyEquivalent:nil,modifiers:[],target:target)))
    }
    // Cleanup cancels the timer separately from resetting the buffer.
    func cancelPendingFlush() {flushTask?.cancel();flushTask=nil}
    func clearBuffer() {pending=nil}
    deinit {flushTask?.cancel()}
}

@MainActor struct EventStreamNativeTerminalCaptureIO {
    var secureInputPID:()->Int?
    var application:(Int32)->EventStreamApp?
    static var native:Self {
        let applications=EventStreamApplicationResolver()
        return .init(secureInputPID:{
            (CGSessionCopyCurrentDictionary() as? [String:Any])?["kCGSSessionSecureInputPID"] as? Int
        },application:{applications.snapshot(processIdentifier:$0,fallbackName:nil)})
    }
}

@MainActor final class EventStreamNativeTerminalCapture {
    private let sourceOwner:EventStreamNativeSelectionRecordFactory
    private let capture:EventStreamTerminalCapture<AXUIElement,EventStreamAXNode>
    init(sourceOwner:EventStreamNativeSelectionRecordFactory,nextIdentity:@escaping ()->EventStreamRecordIdentity,
         io:EventStreamNativeTerminalCaptureIO?=nil,
         reader:EventStreamNativeSelectionRecordBackend?=nil) {
        self.sourceOwner=sourceOwner
        let io=io ?? .native,reader=reader ?? .init()
        capture = .init(backend:.init(wrap:{sourceOwner.snapshots.node($0)},
            secureInputPID:io.secureInputPID,role:{reader.string($0,attribute:"AXRole")},nextIdentity:nextIdentity,
            target:{sourceOwner.context.backend.describeEndpoint($0,titleOverride:nil)},
            application:io.application,window:sourceOwner.context.resolver.window))
    }
    func make(element:AXUIElement,processIdentifier:Int32,bundleIdentifier:String?)->EventStreamPendingTerminalRecord<AXUIElement>? {
        capture.make(element:element,processIdentifier:processIdentifier,bundleIdentifier:bundleIdentifier)
    }
    func refreshTarget(_ element:AXUIElement)->EventStreamAXElement {
        sourceOwner.context.backend.describeEndpoint(sourceOwner.snapshots.node(element),titleOverride:nil)
    }
}
