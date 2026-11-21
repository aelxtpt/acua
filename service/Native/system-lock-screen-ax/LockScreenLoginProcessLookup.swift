import Foundation
import Darwin

@MainActor struct LockScreenLoginProcessLookup {
    var processIDs: () -> [Int32]?
    var bsdInfo: (Int32) -> Data?

    func processIdentifier() -> Int32? {
        guard let pids = processIDs() else { return nil }
        var matches = [Int32]()
        // SAIRunningProcess creates the whole filtered result before selecting
        // its first entry. Preserve native enumeration order, including duplicates.
        for pid in pids where pid > 0 {
            guard let data = bsdInfo(pid), data.count >= 136 else { continue }
            let bytes = Array(data.dropFirst(64))
            guard let end = bytes.firstIndex(of: 0),
                  String(bytes: bytes[..<end], encoding: .utf8) == "loginwindow" else { continue }
            matches.append(pid)
        }
        return matches.first
    }

    static var native: Self {
        .init(processIDs: {
            let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard size > 0, let buffer = malloc(Int(size)) else { return nil }
            defer { free(buffer) }
            let received = proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer, size)
            guard received > 0 else { return nil }
            return Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: Int32.self), count: Int(received) / 4))
        }, bsdInfo: { pid in
            var data = Data(count: 136)
            let received = data.withUnsafeMutableBytes { proc_pidinfo(pid, 3, 0, $0.baseAddress, 136) }
            return received > 0 ? data : nil
        })
    }
}
