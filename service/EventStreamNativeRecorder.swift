import Foundation
import AppKit
import ApplicationServices

typealias EventStreamNativeRecorder=EventStreamRecorderLifecycle<NSRunningApplication>

@MainActor struct EventStreamNativeRecorderCaptureBinding {
    var capture:(EventStreamEventTarget?,Bool) async throws->EventStreamAXCaptureResult
    var clearPreviousRevision:()->Void
    var clearPreviousWindowID:()->Void
    static func native(source:EventStreamNativeSelectionRecordFactory,configuration:@escaping ()->[String:Any])->Self {
        let capture=source.context.makeNativeAXCapture(prefetchConfiguration:configuration,snapshots:source.snapshots)
        return .init(capture:{try await capture.capture($0,preferDiff:$1)},
            clearPreviousRevision:capture.clearPreviousRevision,clearPreviousWindowID:capture.clearPreviousWindowID)
    }
}

@MainActor final class EventStreamNativeRecorderInputSource {
    private let stopBody:()->Void
    init(stop:@escaping ()->Void) {stopBody=stop}
    func stop() {stopBody()}
}

// Native defaults use real sources/capture. Explicit overrides support owned
// fixtures; they are not installed by service handlers or used as fallbacks.
@MainActor struct EventStreamNativeRecorderIO {
    typealias FrontmostToken=EventStreamFrontmostObservers<NSRunningApplication>.Token
    var makeInputSource:(@escaping (UInt32)->Int32?,@escaping (EventStreamInputObservation)->Void)->EventStreamNativeRecorderInputSource
    var addFrontmost:(@escaping (NSRunningApplication)->Void)->FrontmostToken
    var removeFrontmost:(FrontmostToken)->Void
    var frontmost:()->NSRunningApplication?
    var runningApplication:(Int32)->NSRunningApplication?
    var bundleIdentifier:(NSRunningApplication)->String?
    var applicationSnapshot:(NSRunningApplication)->EventStreamApp?
    var observationBackend:EventStreamRecorderObservation.Backend?
    var terminalIO:EventStreamNativeTerminalCaptureIO?
    var selectionBackend:EventStreamNativeSelectionRecordBackend?
    var textContext:((EventStreamEventTarget?)->(EventStreamApp?,EventStreamWindow?))?
    var makeCapture:((EventStreamNativeSelectionRecordFactory,@escaping ()->[String:Any])->EventStreamNativeRecorderCaptureBinding)?
    var observationFailed:(Error,NSRunningApplication)->Void
    var captureFailed:(Error)->Void

    static var native:Self {
        let applications=EventStreamApplicationResolver()
        return .init(makeInputSource:{windowOwner,onInput in
            let tap=EventStreamInputTap()
            // recorder.start is not aborted when the tap is unavailable.
            try? tap.start(windowOwner:windowOwner,onInput:onInput)
            return .init(stop:tap.stop)
        },addFrontmost:{EventStreamNativeFrontmostTracker.shared.addObserver($0)},
            removeFrontmost:{EventStreamNativeFrontmostTracker.shared.removeObserver($0)},
            frontmost:{EventStreamNativeFrontmostTracker.shared.application},
            runningApplication:{NSRunningApplication(processIdentifier:$0)},
            bundleIdentifier:{$0.bundleIdentifier},
            applicationSnapshot:{applications.snapshot(processIdentifier:$0.processIdentifier,fallbackName:$0.localizedName)},
            observationFailed:{error,app in
                let name=app.localizedName ?? String(app.processIdentifier)
                FileHandle.standardError.write(Data("Failed to observe AX notifications for \(name): \(error)\n".utf8))
            },captureFailed:{error in
                FileHandle.standardError.write(Data("Failed to capture AX payload: \(String(reflecting:error))\n".utf8))
            })
    }
}

@MainActor enum EventStreamNativeRecorderFactory {
    // No remote configuration is fetched: the recorder runs on the empty
    // prefetch configuration, i.e. its defaults.
    static func make(prefetchConfiguration:@escaping ()->[String:Any] = { [:] },
                     snapshots:EventStreamNativeSnapshots?=nil,
                     io:EventStreamNativeRecorderIO?=nil,
                     now:@escaping ()->Date=Date.init,
                     sleep:@escaping (Duration) async throws->Void = {try await ContinuousClock().sleep(for:$0)}) -> EventStreamNativeRecorder {
        let bindings=EventStreamNativeRecorderBindings(configuration:prefetchConfiguration,
            snapshots:snapshots ?? .init(),io:io ?? .native,now:now,sleep:sleep)
        let recorder=EventStreamNativeRecorder(backend:.init(now:now,
            clearPreviousRevision:{bindings.capture.clearPreviousRevision()},
            clearPreviousWindowID:{bindings.capture.clearPreviousWindowID()},
            clearURLs:{bindings.source.context.resolver.clearWindowURLs()},
            clearMouseDown:{bindings.input.clearMouseDown()},clearTextBuffer:{bindings.input.clearTextBuffer()},
            clearTerminalBuffer:{bindings.notifications.clearTerminalBuffer()},
            clearSelectionRecords:{bindings.notifications.clearSelectionRecords()},
            clearSelectionTaskOwners:{bindings.notifications.clearSelectionTaskOwners()},
            installInputTap:bindings.installInput,subscribeFrontmost:bindings.subscribe,
            currentApplication:{bindings.io.frontmost()},refreshApplication:{bindings.applications.refresh($0,at:$1)},
            flushText:{bindings.input.flushText()},flushTerminal:{bindings.notifications.flushTerminal()},
            flushSelectionAfterRecordingGuard:{bindings.notifications.flushSelection()},
            stopInputTap:bindings.stopInput,unsubscribeFrontmost:bindings.unsubscribe,
            stopAXObserver:{bindings.applications.stopObserver()},
            cancelDelayedTasks:{bindings.input.cancelTextFlush();bindings.notifications.cancelPendingTasks()},
            clearCurrentApplication:{bindings.applications.clearCurrentApplication()},
            capturePolicyChanged:bindings.updatePolicy))
        bindings.owner=recorder
        return recorder
    }
}

@MainActor private final class EventStreamNativeRecorderBindings {
    final class Observation:NSObject {
        let value:any EventStreamAXObservation
        init(_ value:any EventStreamAXObservation) {self.value=value}
    }
    weak var owner:EventStreamNativeRecorder?
    let io:EventStreamNativeRecorderIO
    private let configuration:()->[String:Any],now:()->Date,sleep:(Duration) async throws->Void
    private let snapshots:EventStreamNativeSnapshots
    private var inputSource:EventStreamNativeRecorderInputSource?
    private var frontmostToken:EventStreamNativeRecorderIO.FrontmostToken?
    init(configuration:@escaping ()->[String:Any],snapshots:EventStreamNativeSnapshots,
         io:EventStreamNativeRecorderIO,now:@escaping ()->Date,sleep:@escaping (Duration) async throws->Void) {
        self.configuration=configuration;self.snapshots=snapshots;self.io=io;self.now=now;self.sleep=sleep
    }
    private func identity()->EventStreamRecordIdentity {
        guard let owner else {preconditionFailure("Record identity requested after native owner release")}
        return owner.nextIdentity()
    }
    private func identity(at timestamp:Date)->EventStreamRecordIdentity {
        guard let owner else {preconditionFailure("Record identity requested after native owner release")}
        return owner.nextIdentity(at:timestamp)
    }
    private func emit(_ record:EventStreamRecord) {owner?.onRecordStored?(record)}
    lazy var source=EventStreamNativeSelectionRecordFactory(nextIdentity:{[unowned self] in identity()},snapshots:snapshots,selectionBackend:io.selectionBackend)
    lazy var capture:EventStreamNativeRecorderCaptureBinding = io.makeCapture?(source,configuration) ?? .native(source:source,configuration:configuration)
    private lazy var records=EventStreamRecordFactory(nextIdentity:{[unowned self] in identity()},capture:capture.capture,onCaptureError:io.captureFailed)
    lazy var notifications:EventStreamNativeRecorderNotifications = {
        let terminal=EventStreamNativeTerminalCapture(sourceOwner:source,nextIdentity:{[unowned self] in identity()},io:io.terminalIO)
        return .init(sourceOwner:source,terminalCapture:terminal,nextIdentity:{[unowned self] in identity()},
            identityAt:{[unowned self] in identity(at:$0)},isRecording:{[weak self] in self?.owner?.isRecording ?? false},
            runningApplication:io.runningApplication,sleep:sleep,lifetimeOwner:{[weak self] in self?.owner},
            captureWindowChanged:{[weak self] in await self?.captureWindow($0)},emit:{[weak self] in self?.emit($0)})
    }()
    lazy var input:EventStreamInputRecordBuilder<EventStreamAXNode> = source.context.makeInputBuilder(
        nextIdentity:{[unowned self] in identity()},isRecording:{[weak self] in self?.owner?.isRecording ?? false},
        fallbackProcessIdentifier:{[weak self] in self?.applications.currentProcessIdentifier},
        shouldCaptureApplication:{[weak self] in self?.owner?.shouldCaptureApplication?($0) ?? true},
        resolveTextContext:io.textContext,sleep:sleep,lifetimeOwner:{[weak self] in self?.owner},
        emitText:{[weak self] in self?.emit($0)},prepare:{[weak self] in self?.prepare($0)})
    lazy var applications:EventStreamApplicationCaptureController<NSRunningApplication,Observation> = .init(backend:.init(
        isRecording:{[weak self] in self?.owner?.isRecording ?? false},processIdentifier:{$0.processIdentifier},
        nextIdentity:{[unowned self] in identity(at:$0)},observe:{[weak self] in try self?.observe($0)},
        stop:{$0.value.stop()},applicationSnapshot:io.applicationSnapshot,
        captureWindowChanged:{[weak self] _,identity in self?.scheduleWindow(identity)},
        emit:{[weak self] in self?.emit($0)},observationFailed:io.observationFailed))
    func updatePolicy(_ policy:((NSRunningApplication)->Bool)?) {
        applications.shouldCaptureApplication=policy;notifications.shouldCaptureApplication=policy
    }
    func installInput() {
        inputSource=io.makeInputSource({[source] in source.context.backend.window($0)?.processIdentifier},{[weak self] observation in
            guard let self,let owner else {return}
            input.receive(observation);withExtendedLifetime(owner) {}
        })
    }
    func stopInput() {inputSource?.stop();inputSource=nil}
    func subscribe() {
        guard let owner else {return}
        let delivery=EventStreamRecorderFrontmostDelivery(owner:owner,now:now) {[weak self] owner,app,date in
            self?.applications.refresh(app,at:date);withExtendedLifetime(owner) {}
        }
        frontmostToken=io.addFrontmost(delivery.receive)
    }
    func unsubscribe() {if let frontmostToken {io.removeFrontmost(frontmostToken)};frontmostToken=nil}
    private func observe(_ application:NSRunningApplication)throws->Observation? {
        guard let owner else {return nil}
        let observer=io.observationBackend.map {EventStreamRecorderObservation(backend:$0)} ?? .init(snapshots:source.snapshots)
        return try observer.make(processIdentifier:application.processIdentifier,bundleIdentifier:io.bundleIdentifier(application),owner:owner,now:now) {[weak self] owner,event,pid,bundle,date in
            self?.notifications.receive(event,processIdentifier:pid,bundleIdentifier:bundle,timestamp:date)
            withExtendedLifetime(owner) {}
        }.map(Observation.init)
    }
    private func prepare(_ interaction:EventStreamPreparedInteraction) {
        guard let owner else {return}
        Task { @MainActor [owner] in owner.store(await records.make(interaction)) }
    }
    private func scheduleWindow(_ identity:EventStreamRecordIdentity) {
        guard let owner else {return}
        Task { @MainActor [owner] in owner.store(await records.make(identity:identity,kind:.windowChanged)) }
    }
    private func captureWindow(_ identity:EventStreamRecordIdentity) async {
        guard let owner else {return}
        owner.store(await records.make(identity:identity,kind:.windowChanged))
    }
}
