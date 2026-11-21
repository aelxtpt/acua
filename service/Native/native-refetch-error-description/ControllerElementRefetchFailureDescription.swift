import Foundation

/// Client-facing descriptions for every element refetch failure case.
extension ControllerElementRefetchFailure: CustomStringConvertible {
    var description: String {
        switch self {
        case .missingID(let id):return "\(id) is an invalid element ID"
        case .unavailable(let reason):
            switch reason {
            case .missingMonitor:return "The appSnapshot is unexpectedly missing an invalidation monitor. This state shouldn't happen, likely programmer error."
            case .ambiguousBeforeRefetch:return "The element was invalidated, and an attempt was made to refetch it, but the refetch couldn't be started because multiple elements were found that match the criteria. Try to get the on-screen content again and see if that resolves the issue."
            case .ambiguousAfterRefetch:return "The element was invalidated, and an attempt was made to refetch it, but the refetch couldn't be finished because multiple elements were found that match the criteria. Try to get the on-screen content again and see if that resolves the issue."
            case .invalidElement,.missingAfterRefetch:return "The element ID is no longer valid. Try to get the on-screen content again and see if that resolves the issue."
            }
        }
    }
}
