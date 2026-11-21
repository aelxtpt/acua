import Foundation

enum EventStreamElementContextType:UInt8,CaseIterable {
    case fullUIContext=0,eventStreamContext,informationalContext
}
struct EventStreamFlattenedRole:Equatable {
    let separator:String,description:String,targetDescription:String
    // Native TransformedUIElement override0x1007688B4 / table init0x10076BED0.
    static func native(for role:String) -> Self? {
        switch role {
        case "AXStaticText":return .init(separator:" ",description:"text",targetDescription:"text")
        case "AXRadioButton":return .init(separator:"; ",description:"radio button",targetDescription:"radio buttons")
        case "AXRow":return .init(separator:"; ",description:"outline row",targetDescription:"rows")
        default:return nil
        }
    }
}

extension EventStreamSharedTreeTransform {
    // Case8 requires the actual context type as well as its URL shortener.
    // Case7 uses the same URL-aware entry; remaining cases require their own
    // render/rebuild context and are not substituted with an identity result.
    static func transform<Element>(_ item:EventStreamCollectedItem<Element>,pass:EventStreamSharedTreeTransformation,
        contextType:EventStreamElementContextType,shortener:inout EventStreamURLShortener
    ) throws -> EventStreamTreeTransformationResult<Element> {
        if pass == .flattenLinksIntoMarkdownText {return try transform(item,pass:pass,shortener:&shortener)}
        guard pass == .mergeTextOnlySiblings else {throw EventStreamTreePruningError.unsupportedTransformation(pass)}
        guard !item.node.isSelectable,!item.node.isFocusable else {return .unchanged}
        //0x1006676F8: cache candidates once left-to-right, including empty text
        // and informational links with no URL. Only nil results split runs.
        var cache:[Int:EventStreamTransformedString]=[:],runs:[Range<Int>]=[],start:Int?
        for (index,child) in item.children.enumerated() {
            let node=child.node
            var text:EventStreamTransformedString?
            if node.role=="AXStaticText",let value=node.stringValue {text = .init(value)}
            else if node.role=="AXLink",contextType == .informationalContext {
                var link=EventStreamTransformedString("")
                if let url=node.url {
                    link = .init()
                    link.appendMarkdownLink(url:url,role:node.role,stringValue:node.stringValue,title:node.title,
                                            description:node.description,shortener:&shortener)
                }
                text=link
            }
            if let text {cache[index]=text;if start==nil {start=index}}
            else if let lower=start {runs.append(lower..<index);start=nil}
        }
        if let lower=start {runs.append(lower..<item.children.count)}
        guard !runs.isEmpty else {return .unchanged}
        var children=item.children
        for range in runs.reversed() where range.count>1 {
            let first=item.children[range.lowerBound]
            guard let role=EventStreamFlattenedRole.native(for:first.node.role) else {continue}
            let parts=range.compactMap {cache[$0]}.filter { !$0.description.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
            let text=EventStreamTransformedString.joined(parts,separator:role.separator)
            var node=first.node
            node.role=first.node.role;node.roleDescription=role.targetDescription
            node.transformedString=text
            if node.stringValue != nil {node.value=text.description} else {node.description=text.description}
            let merged=first.replacing(node:node,children:[])
            children.replaceSubrange(range,with:[merged])
        }
        // At least one eligible run returns transformed even if all runs are
        // singletons or their first role has no native flattened-role entry.
        return .transformed(item.replacing(children:children))
    }
}
