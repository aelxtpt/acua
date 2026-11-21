import Foundation

// The Messages database stores the plain text inside a typedstream archive.
// Read only that prefix, without instantiating any archived objects.
struct MessagesAttributedBody {
    private let bytes: UnsafeRawBufferPointer
    private var offset = 0

    static func text(in bytes: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
        var reader = Self(bytes: bytes)
        guard reader.integer() == 4, reader.string()?.elementsEqual("streamtyped".utf8) == true,
              reader.integer() == 1000, reader.marker(64),
              reader.className("NSAttributedString", or: "NSMutableAttributedString"),
              reader.integer() == -110,
              reader.className("NSString", or: "NSMutableString"),
              reader.marker(43), let text = reader.string(), reader.byte() == 134 else { return nil }
        return text
    }

    private mutating func className(_ name: String, or mutableName: String) -> Bool {
        guard skipNewObjects(), let label = string(),
              label.elementsEqual(name.utf8) || label.elementsEqual(mutableName.utf8),
              length() != nil else { return false }
        while next == 132 {
            guard skipNewObjects(), string() != nil, length() != nil else { return false }
        }
        if next == 133 {
            offset += 1
            return true
        }
        return integer().map { $0 >= -110 } ?? false
    }

    private mutating func skipNewObjects() -> Bool {
        guard next == 132 else { return false }
        repeat { offset += 1 } while next == 132
        return true
    }

    private mutating func marker(_ value: UInt8) -> Bool {
        byte() == 132 && length() == 1 && byte() == value
    }

    private var next: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    private mutating func byte() -> UInt8? {
        guard let value = next else { return nil }
        offset += 1
        return value
    }

    private mutating func integer() -> Int? {
        guard let tag = byte() else { return nil }
        switch tag {
        case 129:
            guard let low = byte(), let high = byte() else { return nil }
            return Int(Int16(bitPattern: UInt16(low) | UInt16(high) << 8))
        case 130:
            guard let low = byte(), let second = byte(), let third = byte(), let high = byte() else { return nil }
            let value = UInt32(low) | UInt32(second) << 8 | UInt32(third) << 16 | UInt32(high) << 24
            return Int(Int32(bitPattern: value))
        default:
            return Int(Int8(bitPattern: tag))
        }
    }

    private mutating func length() -> Int? {
        guard let count = integer(), count >= 0 else { return nil }
        return count
    }

    private mutating func string() -> UnsafeRawBufferPointer? {
        guard let count = length(), count <= bytes.count - offset else { return nil }
        let start = offset
        offset += count
        return UnsafeRawBufferPointer(rebasing: bytes[start..<offset])
    }
}
