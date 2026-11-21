import Foundation
import ApplicationServices

// Decoding/retry policy. A provider can be a real SPI capture
// or controlled hierarchy records; no synthetic tree replaces the native path.
@MainActor struct EventStreamHierarchyCapture {
    typealias Identity = EventStreamSnapshotAXIdentity
    typealias Table = [Identity:[String:EventStreamPartialValue]]
    let keys: EventStreamHierarchySPI.Keys
    let copy: (AXUIElement,[String],[String],Int) -> NSDictionary?
    let maximumIncompleteRetries:Int
    init(keys:EventStreamHierarchySPI.Keys,copy:@escaping (AXUIElement,[String],[String],Int)->NSDictionary?,
         maximumIncompleteRetries:Int=1024) {
        self.keys=keys;self.copy=copy;self.maximumIncompleteRetries=maximumIncompleteRetries
    }

    private enum Work {
        case request(AXUIElement)
        case node(Identity,NSDictionary)
        case finish(Identity)
    }
    func capture(_ element:AXUIElement,traversal:[String],attributes:[String],maximumArrayCount:Int) -> Table {
        var retrying:[Identity:Int] = [:],work:[Work] = [.request(element)],result:Table = [:]
        let arrayAttributes=Set(traversal)
        // Preserve depth-first retry/merge order without consuming the native
        // call stack on a deeply nested hierarchy of incomplete results.
        while let item=work.popLast() {
            switch item {
            case .request(let element):
                guard let raw=copy(element,traversal,attributes,maximumArrayCount),let entries=entries(from:raw) else {continue}
                work.append(contentsOf:entries.reversed().map { .node($0.0,$0.1) })
            case .finish(let identity):
                let remaining=(retrying[identity] ?? 1)-1
                if remaining==0 {retrying.removeValue(forKey:identity)} else {retrying[identity]=remaining}
            case .node(let identity,let values):
                if let incomplete=values[keys.incomplete], !(incomplete is NSNull),
                   let flag=incomplete as? Bool,flag {
                    // Allow repeated transient incomplete results, bounded at 1024 per
                    // active identity so a nonconverging provider cannot retry forever.
                    let attempts=retrying[identity,default:0]
                    guard attempts<maximumIncompleteRetries else {continue}
                    retrying[identity]=attempts+1
                    work.append(.finish(identity));work.append(.request(identity.element));continue
                }
                guard let records=values as? [String:[String:Any]] else {continue}
                var decoded:[String:EventStreamPartialValue] = [:]
                for (attribute,record) in records {
                    decoded[attribute] = .decode(attribute:attribute,record:record,siblings:records,
                                              arrayAttributes:arrayAttributes,valueKey:keys.value,countKey:keys.count)
                }
                result[identity]=decoded
            }
        }
        return result
    }
    private func entries(from raw:NSDictionary) -> [(Identity,NSDictionary)]? {
        var entries:[(Identity,NSDictionary)] = []
        // AX references are CF dictionary keys, not NSCopying objects.
        // NSDictionary.Iterator can trap on them; enumerate the toll-free CF
        // dictionary directly, retaining values into the decoded table.
        let dictionary=unsafeBitCast(raw,to:CFDictionary.self)
        let count=CFDictionaryGetCount(dictionary)
        var rawKeys=[UnsafeRawPointer?](repeating:nil,count:count)
        var rawValues=[UnsafeRawPointer?](repeating:nil,count:count)
        rawKeys.withUnsafeMutableBufferPointer {keys in
            rawValues.withUnsafeMutableBufferPointer {values in
                CFDictionaryGetKeysAndValues(dictionary,keys.baseAddress,values.baseAddress)
            }
        }
        for index in 0..<count {
            guard let key=rawKeys[index],let value=rawValues[index] else {return nil}
            let object=Unmanaged<AnyObject>.fromOpaque(key).takeUnretainedValue()
            let payload=Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
            guard CFGetTypeID(object)==AXUIElementGetTypeID(),let values=payload as? NSDictionary else {return nil}
            entries.append((.init(element:unsafeBitCast(object,to:AXUIElement.self)),values))
        }
        return entries
    }
}
