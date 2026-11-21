import Foundation
import CoreGraphics

/// Finds the audio heading in System Settings. The descendant search starts at the root's children,
/// visits breadth first, then selects the third matching direct child heading.
@MainActor struct SettingsAudioHeading<Element> {
    struct Section { let identifier: String;let element: Element }
    struct Environment {
        let focusedWindow: (Int32) -> Element?
        let sections: (Element) -> [Section]
        let children: (Element) -> [Element]
        let role: (Element) -> String?
        let frame: (Element) -> CGRect?
        let isMacOS26OrLater: () -> Bool
    }
    let environment: Environment
    func resolve(ownerPID: Int32) -> CGRect? {
        guard let window=environment.focusedWindow(ownerPID),
              let root=environment.sections(window).first(where:{ $0.identifier == "AXContent" })?.element else { return nil }
        var queue=environment.children(root),index=0
        var scroll: Element?
        while index < queue.count {
            let node=queue[index];index += 1
            if environment.role(node) == "AXScrollArea" { scroll=node;break }
            queue.append(contentsOf:environment.children(node))
        }
        guard let scroll else { return nil }
        let targetRole=environment.isMacOS26OrLater() ? "AXStaticText":"AXHeading"
        let headings=environment.children(scroll).filter { environment.role($0) == targetRole }
        guard headings.count >= 3,let heading=environment.frame(headings[2]),let windowFrame=environment.frame(window) else { return nil }
        return CGRect(x:heading.minX-windowFrame.minX,y:heading.minY-windowFrame.minY,width:heading.width,height:heading.height)
    }
}
