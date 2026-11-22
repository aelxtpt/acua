import CoreGraphics
import Foundation

// Prints the number of on-screen windows owned by the process with the given
// PID. Owner PIDs need no Screen Recording grant; window titles would.
guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: ServiceWindows <pid>\n".utf8))
    exit(2)
}

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.count)
