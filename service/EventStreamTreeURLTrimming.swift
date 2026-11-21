import Foundation

enum EventStreamTreeURLTrimming {
    //0x100765BBC: parent before children, using existing context accounting.
    // This worker does not compact/reset the shortener or trim independent
    // focusedElement. Empty trees retain their existing caches.
    static func trim<Element>(_ tree:inout EventStreamCollectedTree<Element>,
                              context:inout EventStreamMacTransformationContext) {
        for index in tree.roots.indices {
            var item=tree.roots[index],node=item.node
            if var rich=node.transformedString {
                let changed=rich.trimURLs {context.urlShortener.trim(url:$0,isImage:$1)}
                node.transformedString=rich
                // Informational attributed nodes retain the plain value;
                //0x100765D08 calls a retain-only helper, not a reformatter.
                if changed && !(context.type == .informationalContext && node.attributedString != nil) {
                    node.value=rich.description
                }
            }
            item=item.replacing(node:node)
            trim(&item.subtree,context:&context)
            tree.roots[index]=item
        }
    }
}
