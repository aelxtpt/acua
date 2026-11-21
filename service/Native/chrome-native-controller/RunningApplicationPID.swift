import AppKit

/// The fallback is only for a nonpositive NSRunningApplication PID.
enum RunningApplicationPID {
    struct Environment {
        let processIdentifier: () -> Int32
        let isTerminated: () -> Bool
        let executableURL: () -> URL?
        let processesWithExecutablePath: (String) -> [Int32]?
    }

    static func resolve(_ environment: Environment) -> Int32 {
        let pid = environment.processIdentifier()
        if pid > 0 { return pid }
        guard !environment.isTerminated(), let url = environment.executableURL(),
              let pids = environment.processesWithExecutablePath(url.path), pids.count == 1 else { return -1 }
        // The helper returns the one record's PID as-is; its caller checks >0.
        return pids[0]
    }

    static func resolve(_ application: NSRunningApplication) -> Int32 {
        resolve(.init(processIdentifier: { application.processIdentifier },
            isTerminated: { application.isTerminated }, executableURL: { application.executableURL },
            processesWithExecutablePath: { path in
                RunningProcessSearch.find(.init(executablePath: path, options: 1))?.map(\.pid)
            }))
    }
}
