import Carbon
import Foundation

@MainActor enum ControllerNativeKeyboardTextTranslation {
    static func translate(_ text: String) -> [ControllerKeyboardStroke]? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            NSLog("Unable to get current keyboard layout.")
            return nil
        }
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            NSLog("Unable to get keyboard layout data.")
            return nil
        }
        let data = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else {
            NSLog("Unable to get keyboard layout pointer.")
            return nil
        }
        let type = UInt32(LMGetKbdType())
        return withExtendedLifetime(source) {
            bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                ControllerKeyboardTextTranslation.translate(text, key: { code, modifiers in
                    var dead: UInt32 = 0
                    var length = 0
                    var buffer = [UInt16](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, 3, modifiers, type, 0,
                        &dead, buffer.count, &length, &buffer)
                    return .init(status: status, units: Array(buffer.prefix(length)))
                })
            }
        }
    }
}
