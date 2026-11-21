import Foundation
import ApplicationServices

struct LockScreenAXAttributeValues {
    let cached: [String: AnyObject]
    let supported: Set<String>
    let requested: Set<String>?
    let read: (String) -> AnyObject?

    func string(_ name: String) -> String? { cached[name] as? String }
    var isEnabled: Bool { cached["AXEnabled"] as? Bool ?? true }
    func value<T>(_ name: String, decode: (AnyObject?) -> T?) -> T? {
        if let result = decode(cached[name]) { return result }
        if let requested {
            if requested.contains(name), !supported.contains(name) { return nil }
        } else if !supported.isEmpty && !supported.contains(name) { return nil }
        return decode(read(name))
    }
    var frame: CGRect? {
        if let frame = value("AXFrame",decode: { raw -> CGRect? in
            guard let value = Self.axValue(raw,.cgRect) else { return nil }
            var rect = CGRect.zero; return AXValueGetValue(value,.cgRect,&rect) ? rect : nil
        }) { return frame }
        guard let position = value("AXPosition",decode: { raw -> CGPoint? in
            guard let value = Self.axValue(raw,.cgPoint) else { return nil }
            var point = CGPoint.zero; return AXValueGetValue(value,.cgPoint,&point) ? point : nil
        }), let size = value("AXSize",decode: { raw -> CGSize? in
            guard let value = Self.axValue(raw,.cgSize) else { return nil }
            var size = CGSize.zero; return AXValueGetValue(value,.cgSize,&size) ? size : nil
        }) else { return nil }
        return .init(origin:position,size:size)
    }
    private static func axValue(_ raw: AnyObject?,_ type: AXValueType) -> AXValue? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw,to:AXValue.self)
        return AXValueGetType(value) == type ? value : nil
    }
}

struct LockScreenMouseEventPlan: Equatable {
    enum Kind { case down, up }
    let kind: Kind
    let global: CGPoint
    let local: CGPoint
    let windowID: UInt32
    let number: Int64
    static func events(_ click: LockScreenRevealClick, number: Int64) -> [Self] {
        let local = CGPoint(x:click.point.x - click.windowBounds.minX,y:click.point.y - click.windowBounds.minY)
        return [.down,.up].map { .init(kind:$0,global:click.point,local:local,windowID:click.windowID,number:number) }
    }
}
