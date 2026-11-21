import Foundation
import CoreGraphics

extension SettingsTransitionController {
    func presentationTransition() -> SettingsAccessoryPresentation<Artwork>.Transition {
        .init(start:{ [self] in start(from:$0,to:$1,completion:$2) },retarget:{ [self] in retarget($0) },stop:{ [self] in stop() })
    }
}
