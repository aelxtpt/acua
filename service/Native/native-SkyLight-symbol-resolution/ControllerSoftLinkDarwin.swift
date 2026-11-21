import Darwin
import Foundation
import MachO

struct ControllerSoftLinkDarwin: ControllerSoftLinkBackend {
    struct Image { let header: UnsafeRawPointer }
    private static let mask: UInt64 = 0x00ff_ffff_ffff_ffff
    private func currentImages() -> [(hashBytes: [UInt8], image: Image)] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let header = _dyld_get_image_header(index), let path = _dyld_get_image_name(index) else { return nil }
            let bytes = UnsafeRawPointer(path).assumingMemoryBound(to: UInt8.self)
            return (Array(UnsafeBufferPointer(start: bytes, count: strlen(path))), .init(header: UnsafeRawPointer(header)))
        }
    }
    func loadedImages(requests: [UInt64], salt: String) -> [Image] {
        guard !requests.isEmpty else { return [] }
        let wanted = Set(requests.map { $0 & Self.mask }), suffix = Array(salt.utf8)
        var found: [UInt64: Image] = [:]
        for (path, image) in currentImages() {
            let hash = ControllerSoftLink.hash(path, appending: suffix) & Self.mask
            if wanted.contains(hash), found[hash] == nil { found[hash] = image }
        }
        return requests.compactMap { found[$0 & Self.mask] }
    }

    /// Scan the public/private framework roots,
    /// their immediate nested Frameworks, then the two dylib roots. Preserve
    /// directory enumeration order and nil/Current/A/B/C version order.
    func loadImagesFromFilesystem(requests: [UInt64], salt: String) -> [Image] {
        guard !requests.isEmpty else { return [] }
        let suffix = Array(salt.utf8)
        var pending: [UInt8: [UInt64: [Int]]] = [:]
        var found: [Int: Image] = [:]
        for (index, request) in requests.enumerated() where request >> 58 == 0 {
            pending[UInt8(request >> 56), default: [:]][request & Self.mask, default: []].append(index)
        }
        func needs(_ strategy: UInt8) -> Bool { !(pending[strategy]?.isEmpty ?? true) }
        func attempt(_ path: String, strategy: UInt8) {
            let hash = ControllerSoftLink.hash(path.utf8, appending: suffix) & Self.mask
            guard let indices = pending[strategy]?[hash], dlopen(path, RTLD_NOW) != nil else { return }
            // Rescan dyld after dlopen and remove the request
            // from its strategy even when no matching image header appears.
            let loaded = currentImages()
            for index in indices where found[index] == nil {
                found[index] = loaded.first {
                    ControllerSoftLink.hash($0.hashBytes, appending: suffix) & Self.mask == requests[index] & Self.mask
                }?.image
            }
            pending[strategy]?[hash] = nil
        }
        let versions: [String?] = [nil, "Current", "A", "B", "C"]
        func paths(_ root: String, framework: String, nested: Bool) -> [String] {
            versions.map { version in
                let base = root + "/" + framework + (version.map { "/Versions/" + $0 } ?? "")
                return base + (nested ? "/Frameworks" : "/" + String(framework.dropLast(".framework".count)))
            }
        }
        func list(_ path: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] }
        for (strategy, root) in [(UInt8(0), "/System/Library/Frameworks"), (UInt8(1), "/System/Library/PrivateFrameworks")] {
            guard needs(strategy) else { continue }
            for framework in list(root) where framework.hasSuffix(".framework") {
                for path in paths(root, framework: framework, nested: false) {
                    attempt(path, strategy: strategy)
                    if !needs(strategy) { break }
                }
                if !needs(strategy) { break }
                for container in paths(root, framework: framework, nested: true) {
                    for child in list(container) where child.hasSuffix(".framework") {
                        for path in paths(container, framework: child, nested: false) {
                            attempt(path, strategy: strategy)
                            if !needs(strategy) { break }
                        }
                        if !needs(strategy) { break }
                    }
                    if !needs(strategy) { break }
                }
                if !needs(strategy) { break }
            }
        }
        if needs(2) {
            for root in ["/usr/lib", "/usr/lib/system"] {
                for name in list(root) where name.hasSuffix(".dylib") || name.hasSuffix(".so") {
                    attempt(root + "/" + name, strategy: 2)
                    if !needs(2) { break }
                }
                if !needs(2) { break }
            }
        }
        return requests.indices.compactMap { found[$0] }
    }

    func symbols(in image: Image, hashes: Set<UInt64>, salt: String) -> [UInt64: ControllerSoftLinkSymbol] {
        let header = image.header
        guard !hashes.isEmpty, header.load(as: UInt32.self) == MH_MAGIC_64 else { return [:] }
        var text: UInt64?, linkedit: (vm: UInt64, file: UInt64)?
        var exports: (offset: UInt32, size: UInt32)?, symtab: (offset: UInt32, count: UInt32, strings: UInt32)?
        var command = header.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.load(as: mach_header_64.self).ncmds {
            let c = command.load(as: load_command.self)
            guard c.cmdsize >= 8 else { return [:] }
            if c.cmd == LC_SEGMENT_64 {
                let segment = command.load(as: segment_command_64.self)
                let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                if name == "__TEXT" { text = segment.vmaddr }
                if name == "__LINKEDIT" { linkedit = (segment.vmaddr, segment.fileoff) }
            } else if c.cmd == LC_SYMTAB {
                let value = command.load(as: symtab_command.self); symtab = (value.symoff,value.nsyms,value.stroff)
            } else if c.cmd == LC_DYLD_INFO || c.cmd == LC_DYLD_INFO_ONLY {
                let value = command.load(as: dyld_info_command.self)
                if value.export_size != 0 { exports = (value.export_off,value.export_size) }
            } else if c.cmd == LC_DYLD_EXPORTS_TRIE {
                let value = command.load(as: linkedit_data_command.self); exports = (value.dataoff,value.datasize)
            }
            command = command.advanced(by: Int(c.cmdsize))
        }
        guard let text, let linkedit, text <= Int.max, linkedit.vm <= Int.max, linkedit.file <= Int.max else { return [:] }
        let base = header.advanced(by: Int(linkedit.vm) - Int(text) - Int(linkedit.file))
        var found: [UInt64: ControllerSoftLinkSymbol] = [:]
        let suffix = Array(salt.utf8)
        if let exports, exports.size > 0 {
            found = ControllerSoftLinkExportTrie.read(UnsafeBufferPointer(start: base.advanced(by:Int(exports.offset)).assumingMemoryBound(to:UInt8.self), count:Int(exports.size)),
                imageAddress:UInt(bitPattern:header), hashes:hashes, salt:suffix, reexport: { name in
                    guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
                    let alternate = name.hasPrefix("_") ? String(name.dropFirst()) : nil
                    return dlsym(handle,name).map { UInt(bitPattern:$0) } ?? alternate.flatMap { dlsym(handle,$0).map { UInt(bitPattern:$0) } }
                })
        }
        if found.count != hashes.count, let symtab {
            let table = base.advanced(by:Int(symtab.offset)).assumingMemoryBound(to:nlist_64.self)
            let strings = base.advanced(by:Int(symtab.strings)).assumingMemoryBound(to:CChar.self)
            for i in 0..<Int(symtab.count) {
                let row = table[i]
                guard row.n_un.n_strx != 0, row.n_type & 15 == 15 else { continue }
                let pointer = strings.advanced(by:Int(row.n_un.n_strx))
                let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to:UInt8.self)
                let hash = ControllerSoftLink.hash(UnsafeBufferPointer(start:bytes,count:strlen(pointer)),appending:suffix)
                guard hashes.contains(hash), found[hash] == nil, row.n_value >= text else { continue }
                let offset = row.n_value - text
                guard offset <= Int.max else { continue }
                found[hash] = .init(address:UInt(bitPattern:header.advanced(by:Int(offset))),name:String(cString:pointer))
                if found.count == hashes.count { break }
            }
        }
        return found
    }
}

/// Iterative export traversal, visited offsets, raw-prefix hash,
/// repaired UTF8 spelling and optional reexport-name resolution.
enum ControllerSoftLinkExportTrie {
    static func read(_ bytes: UnsafeBufferPointer<UInt8>, imageAddress: UInt, hashes: Set<UInt64>, salt: [UInt8],
                     reexport: (String) -> UInt?) -> [UInt64: ControllerSoftLinkSymbol] {
        var found: [UInt64: ControllerSoftLinkSymbol] = [:], visited: Set<Int> = []
        var stack: [(offset: Int, name: [UInt8])] = [(0,[])]
        func uleb(_ cursor: inout Int, limit: Int) -> UInt64? {
            var result: UInt64 = 0, shift = 0
            while cursor < limit {
                let byte = bytes[cursor];cursor += 1
                guard shift <= 63, shift < 63 || byte & 0x7e == 0 else { return nil }
                result |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while let node = stack.popLast() {
            guard node.offset >= 0, node.offset < bytes.count, visited.insert(node.offset).inserted else { continue }
            var cursor = node.offset
            guard let size = uleb(&cursor,limit:bytes.count), size <= UInt64(Int.max), Int(size) <= bytes.count - cursor else { continue }
            let children = cursor + Int(size)
            if size != 0, let flags = uleb(&cursor,limit:bytes.count) {
                let hash = ControllerSoftLink.hash(node.name,appending:salt)
                if hashes.contains(hash), found[hash] == nil {
                    if flags & 8 == 0 {
                        if let offset = uleb(&cursor,limit:bytes.count), offset <= Int.max {
                            let name = String(decoding:node.name,as:UTF8.self)
                            found[hash] = .init(address:imageAddress + UInt(offset),name:name)
                        }
                    } else {
                        _ = uleb(&cursor,limit:children)
                        var renamed: [UInt8] = [], terminated = false
                        while cursor < children { let byte=bytes[cursor];cursor += 1;if byte == 0 { terminated = true; break };renamed.append(byte) }
                        let name=String(decoding:terminated && !renamed.isEmpty ? renamed : node.name,as:UTF8.self)
                        if let address=reexport(name) { found[hash] = .init(address:address,name:name) }
                    }
                    if found.count == hashes.count { break }
                }
            }
            cursor = children
            guard cursor < bytes.count else { continue }
            let count = Int(bytes[cursor]);cursor += 1
            for _ in 0..<count {
                var edge: [UInt8] = []
                var terminated=false
                while cursor < bytes.count { let byte=bytes[cursor];cursor += 1;if byte == 0 { terminated=true;break };edge.append(byte) }
                guard terminated, let offset=uleb(&cursor,limit:bytes.count), offset <= Int.max else { break }
                stack.append((Int(offset),node.name+edge))
            }
        }
        return found
    }
}
