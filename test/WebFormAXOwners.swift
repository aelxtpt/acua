import ApplicationServices
import Foundation
import Darwin
import AppKit

// A separate client avoids reading an application's own AX server while its
// main thread is occupied. The runner supplies only its owned fixture PID.
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL)!
typealias GetPID = @convention(c) (AXUIElement, UnsafeMutablePointer<pid_t>) -> AXError
let symbol = dlsym(image, "AXUIElementGetActualPid") ?? dlsym(image, "_AXUIElementGetActualPid")!
let actualPID = unsafeBitCast(symbol, to: GetPID.self)
typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
let windowSymbol = dlsym(image, "AXUIElementGetWindow") ?? dlsym(image, "_AXUIElementGetWindow")
let getWindow = windowSymbol.map { unsafeBitCast($0, to: GetWindow.self) }
func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}
var seen: [AXUIElement] = []
var records: [[String: Any]] = []
func visit(_ element: AXUIElement, depth: Int) {
    guard depth < 18, seen.count < 300, !seen.contains(where: { CFEqual($0, element) }) else { return }
    seen.append(element)
    var publicPID: pid_t = 0, actual: pid_t = 0
    let publicStatus = AXUIElementGetPid(element, &publicPID)
    let actualStatus = actualPID(element, &actual)
    let role = value(element, kAXRoleAttribute as String) as? String ?? ""
    var selectionSettable = DarwinBoolean(false)
    let selectionStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &selectionSettable)
    var record: [String: Any] = ["role": role, "title": value(element, kAXTitleAttribute as String) as? String ?? "",
                    "description": value(element, kAXDescriptionAttribute as String) as? String ?? "",
                    "value": value(element, kAXValueAttribute as String) as? String ?? "",
                    "selectionSettable": selectionSettable.boolValue, "selectionStatus": selectionStatus.rawValue,
                    "pid": publicPID, "actualPID": actual, "pidStatus": publicStatus.rawValue, "actualPIDStatus": actualStatus.rawValue]
    if let owner = NSRunningApplication(processIdentifier: actual) {
        record["actualProcessFinishedLaunching"] = owner.isFinishedLaunching
        record["actualProcessActivationPolicy"] = owner.activationPolicy.rawValue
        record["actualProcessBundle"] = owner.bundleIdentifier ?? ""
    }
    if let getWindow {
        var windowID: UInt32 = 0
        record["windowStatus"] = getWindow(element, &windowID).rawValue
        record["windowID"] = windowID
        if windowID != 0, ["AXButton", "AXWindow", "AXSheet"].contains(role) {
            let ordinary = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] ?? []
            record["ordinaryWindowDescriptionAvailable"] = ordinary.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
        }
        var windowPointer = UnsafeRawPointer(bitPattern: UInt(windowID))
        let ids = CFArrayCreate(nil, &windowPointer, 1, nil)
        if windowID != 0, let ids, let windows = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
           let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }) {
            record["windowOwnerPID"] = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            record["windowBounds"] = window[kCGWindowBounds as String]
            record["windowOnscreen"] = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
        }
    }
    if role == "AXTextArea" {
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        record["parameterizedAttributes"] = names as? [String] ?? []
        var markerRange: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, "AXTextMarkerRangeForUIElement" as CFString, element, &markerRange)
        record["markerRangeStatus"] = status.rawValue
        if let markerRange {
            var rich: CFTypeRef?
            let options = ["AXTextMarkerRange": markerRange, "AXSpellCheck": false] as NSDictionary
            let richStatus = AXUIElementCopyParameterizedAttributeValue(element, "AXAttributedStringForTextMarkerRangeWithOptions" as CFString, options, &rich)
            record["attributedStatus"] = richStatus.rawValue
            record["attributedString"] = (rich as? NSAttributedString)?.string ?? ""
        }
    }
    records.append(record)
    if let children = value(element, kAXChildrenAttribute as String) as? [AXUIElement] {
        for child in children { visit(child, depth: depth + 1) }
    }
}
visit(app, depth: 0)
typealias QueryFocus = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<DarwinBoolean>) -> Int32
typealias ProcessPID = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>) -> Int32
if let querySymbol = dlsym(image, "CPSGetKeyFocusProcess") ?? dlsym(image, "_CPSGetKeyFocusProcess"),
   let pidSymbol = dlsym(image, "GetProcessPID") {
    let query = unsafeBitCast(querySymbol, to: QueryFocus.self), process = unsafeBitCast(pidSymbol, to: ProcessPID.self)
    var serial = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
    var flag = DarwinBoolean(false), focusPID: Int32 = 0
    let queryStatus = query(&serial, &flag), processStatus = process(&serial, &focusPID)
    records.append(["role": "OwnedFocusProbe", "keyFocusPID": focusPID, "queryStatus": queryStatus, "processStatus": processStatus, "flag": flag.boolValue])
}
let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
