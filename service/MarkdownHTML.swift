import Foundation
import Darwin

/// A Markdown.HTMLFormatter-style visitor over the system
/// cmark-gfm tree. The generic cmark HTML writer has different output semantics.
enum MarkdownHTML {
    private typealias Node=OpaquePointer
    private struct API {
        typealias StringGetter=@convention(c)(Node)->UnsafePointer<CChar>?
        typealias NodeGetter=@convention(c)(Node)->Node?
        typealias IntegerGetter=@convention(c)(Node)->Int32
        let makeParser:@convention(c)(Int32)->Node?
        let freeParser:@convention(c)(Node)->Void
        let feed:@convention(c)(Node,UnsafePointer<CChar>,Int)->Void
        let finish:@convention(c)(Node)->Node?
        let freeNode:@convention(c)(Node)->Void
        let findExtension:@convention(c)(UnsafePointer<CChar>)->Node?
        let attach:@convention(c)(Node,Node)->Int32
        let first:NodeGetter,next:NodeGetter
        let kind:StringGetter,literal:StringGetter,url:StringGetter,title:StringGetter,language:StringGetter,attributes:StringGetter
        let heading:IntegerGetter,listType:IntegerGetter,listStart:IntegerGetter
        let checked:@convention(c)(Node)->Bool
        let alignments:@convention(c)(Node)->UnsafePointer<UInt8>?
        let columns:@convention(c)(Node)->UInt16
        let colspan:@convention(c)(Node)->UInt32
        let rowspan:@convention(c)(Node)->UInt32

        init?() {
            guard let library=dlopen("/usr/lib/libcmark-gfm.dylib",RTLD_LAZY | RTLD_LOCAL) else{return nil}
            func symbol<T>(_ name:String,_ type:T.Type)->T? {
                guard let pointer=dlsym(library,name) else{return nil}
                return unsafeBitCast(pointer,to:type)
            }
            guard let register=symbol("cmark_gfm_core_extensions_ensure_registered",(@convention(c)()->Void).self),
                  let makeParser=symbol("cmark_parser_new",(@convention(c)(Int32)->Node?).self),
                  let freeParser=symbol("cmark_parser_free",(@convention(c)(Node)->Void).self),
                  let feed=symbol("cmark_parser_feed",(@convention(c)(Node,UnsafePointer<CChar>,Int)->Void).self),
                  let finish=symbol("cmark_parser_finish",(@convention(c)(Node)->Node?).self),
                  let freeNode=symbol("cmark_node_free",(@convention(c)(Node)->Void).self),
                  let findExtension=symbol("cmark_find_syntax_extension",(@convention(c)(UnsafePointer<CChar>)->Node?).self),
                  let attach=symbol("cmark_parser_attach_syntax_extension",(@convention(c)(Node,Node)->Int32).self),
                  let first=symbol("cmark_node_first_child",NodeGetter.self),let next=symbol("cmark_node_next",NodeGetter.self),
                  let kind=symbol("cmark_node_get_type_string",StringGetter.self),let literal=symbol("cmark_node_get_literal",StringGetter.self),
                  let url=symbol("cmark_node_get_url",StringGetter.self),let title=symbol("cmark_node_get_title",StringGetter.self),
                  let language=symbol("cmark_node_get_fence_info",StringGetter.self),let heading=symbol("cmark_node_get_heading_level",IntegerGetter.self),
                  let listType=symbol("cmark_node_get_list_type",IntegerGetter.self),let listStart=symbol("cmark_node_get_list_start",IntegerGetter.self),
                  let checked=symbol("cmark_gfm_extensions_get_tasklist_item_checked",(@convention(c)(Node)->Bool).self),
                  let alignments=symbol("cmark_gfm_extensions_get_table_alignments",(@convention(c)(Node)->UnsafePointer<UInt8>?).self),
                  let columns=symbol("cmark_gfm_extensions_get_table_columns",(@convention(c)(Node)->UInt16).self),
                  let attributes=symbol("cmark_node_get_attributes",StringGetter.self),
                  let colspan=symbol("cmark_gfm_extensions_get_table_cell_colspan",(@convention(c)(Node)->UInt32).self),
                  let rowspan=symbol("cmark_gfm_extensions_get_table_cell_rowspan",(@convention(c)(Node)->UInt32).self) else{return nil}
            self.makeParser=makeParser;self.freeParser=freeParser;self.feed=feed;self.finish=finish;self.freeNode=freeNode
            self.findExtension=findExtension;self.attach=attach;self.first=first;self.next=next
            self.kind=kind;self.literal=literal;self.url=url;self.title=title;self.language=language
            self.heading=heading;self.listType=listType;self.listStart=listStart;self.checked=checked
            self.alignments=alignments;self.columns=columns;self.attributes=attributes;self.colspan=colspan;self.rowspan=rowspan
            register()
        }
        func string(_ getter:StringGetter,_ node:Node)->String{getter(node).map{String(cString:$0)} ?? ""}
        func children(_ node:Node)->[Node] {
            var values=[Node](),child=first(node)
            while let current=child{values.append(current);child=next(current)}
            return values
        }
    }
    private enum Work {
        case node(Node)
        case text(String)
        case cell(Node,header:Bool,alignment:UInt8)
    }
    private static let api=API()

    static func render(_ text:String,checkpoint:() throws->Void = {}) throws->String {
        try checkpoint()
        guard let api else{throw ServiceError(.unhandledEvent,"Markdown converter is unavailable")}
        // cmark_parser_new option bits used for every Markdown document.
        guard let parser=api.makeParser(0x100402) else{throw ServiceError(.unknownError,"Could not render Markdown")}
        var finished=false,document:Node?
        defer {
            // finish transfers the tree to its caller; free an unfinished
            // partial document too when a checkpoint aborts between chunks.
            if !finished{document=api.finish(parser)}
            if let document{api.freeNode(document)}
            api.freeParser(parser)
        }
        for name in ["table","strikethrough","tasklist"] {
            guard let syntax=name.withCString({api.findExtension($0)}),api.attach(parser,syntax) != 0 else{
                throw ServiceError(.unhandledEvent,"Markdown converter is unavailable")
            }
        }
        try text.withCString { source in
            let length=text.utf8.count
            var offset=0
            while offset<length {
                try checkpoint()
                let count=min(65_536,length-offset)
                api.feed(parser,source.advanced(by:offset),count)
                offset += count
            }
        }
        finished=true
        document=api.finish(parser)
        guard let root=document else{throw ServiceError(.unknownError,"Could not render Markdown")}
        try checkpoint()
        var output="",work=[Work.node(root)]
        func schedule(_ opening:String,_ children:[Node],_ closing:String) {
            output += opening
            work.append(.text(closing))
            work.append(contentsOf:children.reversed().map{.node($0)})
        }
        while let current=work.popLast() {
            try checkpoint()
            switch current {
            case .text(let text):output += text
            case .cell(let node,let header,let alignment):
                let colspan=api.colspan(node),rowspan=api.rowspan(node)
                guard colspan>0,rowspan>0 else{continue}
                let tag=header ? "th":"td"
                let align:String
                switch alignment{case 108:align=" align=\"left\"";case 99:align=" align=\"center\"";case 114:align=" align=\"right\"";default:align=""}
                let spans=(rowspan>1 ? " rowspan=\"\(rowspan)\"":"")+(colspan>1 ? " colspan=\"\(colspan)\"":"")
                schedule("<\(tag)\(align)\(spans)>",api.children(node),"</\(tag)>\n")
            case .node(let node):
                let kind=api.string(api.kind,node)
                switch kind {
                case "text","html_inline":output += api.string(api.literal,node)
                case "html_block":output += api.string(api.literal,node)
                case "softbreak":output += "\n"
                case "linebreak":output += "<br />\n"
                case "thematic_break":output += "<hr />\n"
                case "code":output += "<code>"+api.string(api.literal,node)+"</code>"
                case "code_block":
                    let language=api.string(api.language,node)
                    output += "<pre><code"+(language.isEmpty ? "":" class=\"language-\(language)\"")+">"+api.string(api.literal,node)+"</code></pre>\n"
                case "paragraph":schedule("<p>",api.children(node),"</p>\n")
                case "heading":let level=api.heading(node);schedule("<h\(level)>",api.children(node),"</h\(level)>\n")
                case "block_quote":schedule("<blockquote>\n",api.children(node),"</blockquote>\n")
                case "emph":schedule("<em>",api.children(node),"</em>")
                case "strong":schedule("<strong>",api.children(node),"</strong>")
                case "strikethrough":schedule("<del>",api.children(node),"</del>")
                case "link":
                    let url=api.string(api.url,node)
                    schedule(url.isEmpty ? "<a>":"<a href=\"\(url)\">",api.children(node),"</a>")
                case "attribute":
                    let attributes=api.string(api.attributes,node).replacingOccurrences(of:"\"",with:"\\\"")
                    schedule("<span data-attributes=\"\(attributes)\">",api.children(node),"</span>")
                case "image":
                    let source=api.string(api.url,node),title=api.string(api.title,node)
                    output += "<img"+(source.isEmpty ? "":" src=\"\(source)\"")+(title.isEmpty ? "":" title=\"\(title)\"")+" />"
                case "list":
                    let ordered=api.listType(node)==2,start=api.listStart(node)
                    let tag=ordered ? "ol":"ul",attribute=ordered && start != 1 ? " start=\"\(start)\"":""
                    schedule("<\(tag)\(attribute)>\n",api.children(node),"</\(tag)>\n")
                case "item","tasklist":
                    let checkbox=kind=="tasklist" ? "<input type=\"checkbox\" disabled=\"\""+(api.checked(node) ? " checked=\"\"":"")+" /> ":""
                    schedule("<li>"+checkbox,api.children(node),"</li>\n")
                case "table":
                    let rows=api.children(node),columns=Int(api.columns(node)),align=api.alignments(node)
                    output += "<table>\n";work.append(.text("</table>\n"))
                    for (rowIndex,row) in rows.enumerated().reversed() {
                        let header=rowIndex==0
                        if rowIndex==rows.count-1 && !header{work.append(.text("</tbody>\n"))}
                        work.append(.text(header ? "</tr>\n</thead>\n":"</tr>\n"))
                        // Advance alignment once per rendered
                        // cell, including merged cells, and skips ghost cells.
                        let cells=api.children(row).filter{api.colspan($0)>0 && api.rowspan($0)>0}.prefix(columns)
                        for (index,cell) in cells.enumerated().reversed(){work.append(.cell(cell,header:header,alignment:align?[index] ?? 0))}
                        work.append(.text(header ? "<thead>\n<tr>\n":rowIndex==1 ? "<tbody>\n<tr>\n":"<tr>\n"))
                    }
                default:work.append(contentsOf:api.children(node).reversed().map{.node($0)})
                }
            }
        }
        try checkpoint()
        return output
    }
}
