import Foundation

enum TimelineOperation {
    enum Route: String, CaseIterable {
        case start = "ComputerUseIPCTimelineStartRequest"
        case status = "ComputerUseIPCTimelineStatusRequest"
        case stop = "ComputerUseIPCTimelineStopRequest"
        case pause = "ComputerUseIPCTimelinePauseRequest"
        case resume = "ComputerUseIPCTimelineResumeRequest"
        case getSettings = "ComputerUseIPCTimelineGetSettingsRequest"
        case updateSettings = "ComputerUseIPCTimelineUpdateSettingsRequest"
        case updatePolicy = "ComputerUseIPCTimelineUpdateObservationPolicyRequest"
        case clearHistory = "ComputerUseIPCTimelineClearHistoryRequest"
    }

    case start, status, stop, resume, getSettings
    case pause(TimelinePauseDuration?)
    case updateSettings(TimelineSettings)
    case updatePolicy(TimelineUpdateObservationPolicyRequest)
    case clearHistory(TimelineValidatedHistoryScope)

    init(route: Route, request: Any) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: request, options: [.fragmentsAllowed])
        } catch {
            throw ServiceError(.couldNotGetRequestData, "Could not decode \(route.rawValue)")
        }
        let decoder = JSONDecoder()
        do {
            switch route {
            case .start:
                _ = try decoder.decode(TimelineStartRequest.self, from: data)
                self = .start
            case .status:
                _ = try decoder.decode(TimelineStatusRequest.self, from: data)
                self = .status
            case .stop:
                _ = try decoder.decode(TimelineStopRequest.self, from: data)
                self = .stop
            case .pause:
                self = .pause(try decoder.decode(TimelinePauseRequest.self, from: data).duration)
            case .resume:
                _ = try decoder.decode(TimelineResumeRequest.self, from: data)
                self = .resume
            case .getSettings:
                _ = try decoder.decode(TimelineGetSettingsRequest.self, from: data)
                self = .getSettings
            case .updateSettings:
                self = .updateSettings(try decoder.decode(TimelineUpdateSettingsRequest.self, from: data).settings)
            case .updatePolicy:
                self = .updatePolicy(try decoder.decode(TimelineUpdateObservationPolicyRequest.self, from: data))
            case .clearHistory:
                self = .clearHistory(try decoder.decode(TimelineClearHistoryRequest.self, from: data).validatedScope())
            }
        } catch let error as TimelineHistoryValidationError {
            throw ServiceError(.unknownError, error.description)
        } catch {
            throw ServiceError(.couldNotGetRequestData, "Could not decode \(route.rawValue)")
        }
    }

    @MainActor func execute<P: EventStreamCaptureProducing>(on service: TimelineService<P>,
                                                           now: Date = Date(), calendar: Calendar = .current) throws -> Data {
        let encoder = JSONEncoder()
        do {
            switch self {
            case .start: return try encoder.encode(service.start())
            case .status: return try encoder.encode(service.status())
            case .stop: return try encoder.encode(service.stop(reason: .requested))
            case .pause(let duration): return try encoder.encode(service.pause(duration: duration))
            case .resume: return try encoder.encode(service.resume())
            case .getSettings: return try encoder.encode(service.getSettings())
            case .updateSettings(let value): return try encoder.encode(service.updateSettings(value))
            case .updatePolicy(let request): return try encoder.encode(service.updatePolicy(request))
            case .clearHistory(let scope):
                try service.clearHistory(scope, now: now, calendar: calendar)
                return try encoder.encode(service.status())
            }
        } catch let error as TimelineError {
            throw ServiceError(.unknownError, error.description)
        }
    }
}
