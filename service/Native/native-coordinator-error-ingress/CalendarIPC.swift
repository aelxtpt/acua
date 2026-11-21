import Contacts
import CoreLocation
import EventKit
import Foundation
import MapKit
import os

@MainActor
final class CalendarPermissionGate {
    private let status: () -> EKAuthorizationStatus
    private let request: () async throws -> Bool
    private var requesting = false

    init(status: @escaping () -> EKAuthorizationStatus, request: @escaping () async throws -> Bool) {
        self.status = status
        self.request = request
    }

    @available(macOS 14, *)
    func requireAccess() throws {
        switch status() {
        case .fullAccess: return
        case .notDetermined:
            if !requesting {
                requesting = true
                Task {
                    _ = try? await request()
                    requesting = false
                }
            }
            throw ControllerNativeServerError.calendarPermissionsPending
        default: throw Self.denied
        }
    }

    nonisolated static var denied: ControllerNativeServerError {
        ControllerNativeServerError.calendarPermissionsDenied
    }
}

@available(macOS 14, *)
@MainActor
final class CalendarNativeOwner {
    static let shared = CalendarNativeOwner(
        backend: NativeCalendarBackend(),
        permission: CalendarPermissionGate(status: { EKEventStore.authorizationStatus(for: .event) },
            request: { try await EKEventStore().requestFullAccessToEvents() }),
        locate: CalendarLocation.resolve
    )

    private let backend: NativeCalendarBackend
    private let permission: CalendarPermissionGate
    private let locate: (String) async -> EKStructuredLocation?

    init(backend: NativeCalendarBackend, permission: CalendarPermissionGate,
         locate: @escaping (String) async -> EKStructuredLocation?) {
        self.backend = backend
        self.permission = permission
        self.locate = locate
    }

    func execute(_ operation: CalendarOperation, checkpoint: () throws -> Void) async throws -> Data {
        try checkpoint()
        try permission.requireAccess()
        return try await operation.execute(on: backend, locate: locate, checkpoint: checkpoint)
    }
}

enum CalendarIPC {
    private static let queue = AsyncSerialQueue()

    @available(macOS 14, *)
    static func perform(route: CalendarOperation.Route, request: Any,
                        owner: @escaping @MainActor @Sendable () -> CalendarNativeOwner = { .shared }) throws -> Any {
        let operation = try CalendarOperation(route: route, request: request)
        // Requests arrive on connection workers. The main actor services
        // permission presentation and EventKit callbacks while the worker waits.
        guard !Thread.isMainThread else {
            throw ServiceError(.unknownError, "Calendar requests require a connection worker")
        }
        let scope = RequestRuntime.workerScope()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let pending = PendingResult<Data>(discard: { _ in })
        let task = Task {
            do {
                let data = try await queue.sync {
                    let checkpoint = {
                        try RequestRuntime.withWorkerScope(scope, cancelled: { cancelled.withLock { $0 } }) {}
                    }
                    return try await owner().execute(operation, checkpoint: checkpoint)
                }
                pending.complete(.success(data))
            } catch {
                pending.complete(.failure(translate(error)))
            }
        }
        do {
            try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120)
            return try JSONSerialization.jsonObject(with: pending.take(), options: [.fragmentsAllowed])
        } catch {
            cancelled.withLock { $0 = true }
            task.cancel()
            pending.abandon()
            throw error
        }
    }

    private static func translate(_ error: Error) -> Error {
        if let paging = error as? CalendarPagingError {
            return ControllerNativeServerError.calendarInvalidRequest(paging.description)
        }
        if let read = error as? CalendarReadError {
            switch read {
            case .accessRequired: return CalendarPermissionGate.denied
            case .eventNotFound: return ControllerNativeServerError.calendarInvalidRequest(read.description)
            default: return ControllerNativeServerError.unknown(read.description)
            }
        }
        if let write = error as? CalendarWriteError {
            switch write {
            case .missingAttendeeEmail, .invalidDate:
                return ControllerNativeServerError.calendarInvalidRequest(write.description)
            default: return ControllerNativeServerError.unknown(write.description)
            }
        }
        return error
    }
}

private enum CalendarLocation {
    static func resolve(_ text: String) async -> EKStructuredLocation? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fallback = EKStructuredLocation(title: text)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue),
              let match = detector.firstMatch(in: text, range: range),
              let address = Range(match.range, in: text) else { return fallback }
        guard let placemark = try? await CLGeocoder().geocodeAddressString(String(text[address])).first,
              let coordinate = placemark.location?.coordinate, let postal = placemark.postalAddress else { return fallback }
        let location = EKStructuredLocation(mapItem: MKMapItem(placemark: MKPlacemark(coordinate: coordinate, postalAddress: postal)))
        if address.lowerBound != text.startIndex {
            location.title = text[..<address.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return location
    }
}
