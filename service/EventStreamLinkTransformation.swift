import Foundation

extension EventStreamSharedTreeTransform {
    // Shared case7. This overload requires its actual mutable URL shortener;
    // full native context/traversal binding remains the pipeline driver's job.
    static func transform<Element>(_ item:EventStreamCollectedItem<Element>,pass:EventStreamSharedTreeTransformation,
                                   shortener:inout EventStreamURLShortener) throws -> EventStreamTreeTransformationResult<Element> {
        guard pass == .flattenLinksIntoMarkdownText else {throw EventStreamTreePruningError.unsupportedTransformation(pass)}
        guard item.node.role=="AXLink",let url=item.node.url else {return .unchanged}
        var text=EventStreamTransformedString()
        text.appendMarkdownLink(url:url,role:item.node.role,stringValue:item.node.stringValue,title:item.node.title,
                                description:item.node.description,shortener:&shortener)
        guard !text.description.isEmpty else {return .unchanged}
        var node=item.node
        node.role="AXStaticText";node.roleDescription="link"
        node.transformedString=text;node.value=text.description;node.url=nil
        return .transformed(item.replacing(node:node,children:[]))
    }
}
