import Foundation
func writerMaterialize(_ item:[String:Any],root:URL)throws {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    for path in item["directories"] as? [String] ?? [] {try FileManager.default.createDirectory(at:root.appendingPathComponent(path,isDirectory:true),withIntermediateDirectories:true)}
    for (path,contents) in item["files"] as? [String:String] ?? [:] {
        let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(contents.replacingOccurrences(of:"$ROOT",with:root.path).utf8).write(to:url)
    }
}
func writerSnapshot(_ root:URL)throws->[String:Any] {
    var directories=[String](),files=[String:String]()
    if let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey]) {
        for case let url as URL in enumerator {
            precondition(url.path.hasPrefix(root.path+"/"))
            let path=String(url.path.dropFirst(root.path.count+1))
            if (try url.resourceValues(forKeys:[.isDirectoryKey])).isDirectory==true {directories.append(path)}
            else {files[path]=(try String(contentsOf:url,encoding:.utf8)).replacingOccurrences(of:root.path,with:"$ROOT")}
        }
    }
    return ["directories":directories.sorted(),"files":files]
}
