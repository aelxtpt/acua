import Foundation
import Darwin

/// Bundled SAIRunningProcess-style process search.
enum RunningProcessSearch {
    struct Process: Equatable {
        let pid: Int32
        let uid: UInt32
        let name: String?
    }
    struct Filter {
        var name: String? = nil
        var executablePath: String? = nil
        var options: UInt64 = 0
    }
    struct Environment {
        var currentUID: () -> UInt32
        var allocate: (Int) -> UnsafeMutableRawPointer?
        var deallocate: (UnsafeMutableRawPointer) -> Void
        var listPIDs: (UInt32, UInt32, UnsafeMutableRawPointer?, Int32) -> Int32
        var process: (Int32) -> Process?
        var executablePath: (Int32) -> String?
        var canonicalizePath: (String) -> String

        static var native: Self {
            .init(currentUID: { getuid() }, allocate: { malloc($0) }, deallocate: { free($0) },
                listPIDs: { proc_listpids($0, $1, $2, $3) }, process: nativeProcess,
                executablePath: nativeExecutablePath,
                canonicalizePath: { (($0 as NSString).resolvingSymlinksInPath as NSString).standardizingPath })
        }
    }

    static func find(_ filter: Filter, environment: Environment = .native) -> [Process]? {
        let userOnly = filter.options & 1 != 0
        let type: UInt32 = userOnly ? 4 : 1
        let typeInfo = userOnly ? environment.currentUID() : 0
        let capacity = environment.listPIDs(type, typeInfo, nil, 0)
        guard capacity > 0, let buffer = environment.allocate(Int(capacity)) else { return nil }
        defer { environment.deallocate(buffer) }
        let bytesRead = environment.listPIDs(type, typeInfo, buffer, capacity)
        guard bytesRead > 0 else { return nil }
        // proc_listpids must not report initialized bytes beyond its buffer.
        precondition(bytesRead <= capacity)
        let path = filter.executablePath.map(environment.canonicalizePath)
        let pids = buffer.assumingMemoryBound(to: Int32.self)
        var result: [Process] = []
        for index in 0..<(Int(bytesRead) / MemoryLayout<Int32>.size) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var process: Process?
            if let name = filter.name {
                process = environment.process(pid)
                guard let processName = process?.name, (processName as NSString).isEqual(to: name) else { continue }
            }
            if let path {
                guard let executablePath = environment.executablePath(pid),
                      (environment.canonicalizePath(executablePath) as NSString).isEqual(path as NSString) else { continue }
            }
            if let process = process ?? environment.process(pid) { result.append(process) }
        }
        return result
    }

    static func nativeExecutablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, 4096) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    }

    static func nativeProcess(_ pid: Int32) -> Process? {
        var info = proc_bsdinfo()
        // Accept any positive result rather than an exact-size check.
        // Darwin normally returns the full 136-byte BSD record.
        guard proc_pidinfo(pid, 3, 0, &info, 136) > 0 else { return nil }
        let nameSize = MemoryLayout.size(ofValue: info.pbi_name)
        let name = withUnsafePointer(to: &info.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: nameSize) {
                String(validatingCString: $0)
            }
        }
        return .init(pid: Int32(bitPattern: info.pbi_pid), uid: info.pbi_uid, name: name)
    }
}
