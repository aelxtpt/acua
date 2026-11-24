import Foundation

enum TimelineLifecycleTelemetry {
    static func parameters<P:EventStreamCaptureProducing>(event:TimelineLifecycle<P>.Event)->[String:Any] {
        let prefix="acua.telemetry.v1."
        switch event {
        case .started:return ["@type":prefix+"TimelineServiceStarted"]
        case .paused:return ["@type":prefix+"TimelineServicePaused"]
        case .resumed:return ["@type":prefix+"TimelineServiceResumed"]
        case .stopped(let reason,let duration):
            var result:[String:Any]=["@type":prefix+"TimelineServiceStopped",
                "stopReason":reason == .requested ? "TIMELINE_SERVICE_STOP_REASON_REQUESTED":"TIMELINE_SERVICE_STOP_REASON_SERVICE_TERMINATED"]
            if let duration{result["sessionDurationSeconds"]=duration}
            return result
        }
    }
}
