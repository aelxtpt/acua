import Foundation

/// This follows UTF-16 units rather than Characters; missing layout data
/// fails the whole translation.
///
/// A unit with no key on the current layout (for example "é" or "🙂" on a U.S.
/// layout) is sent as a keystroke that carries only its Unicode text, rather
/// than being skipped; a surrogate pair stays in one stroke so the emoji
/// arrives whole.
enum ControllerKeyboardTextTranslation {
    static let modifierOrder: [UInt32] = [0, 0x200, 0x800, 0xa00, 0x1000, 0x1200, 0x1800, 0x1a00]
    /// Key code of a Unicode-only stroke. Text fields read the attached string;
    /// 0 is what other macOS input tools use for the same purpose.
    static let unicodeOnlyKeyCode: UInt16 = 0
    struct Translation {
        let status: Int32
        let units: [UInt16]
    }
    static func flags(_ carbon: UInt32) -> UInt64 {
        var flags: UInt64 = 0
        if carbon & 0x200 != 0 { flags |= 0x20000 }
        if carbon & 0x800 != 0 { flags |= 0x80000 }
        if carbon & 0x1000 != 0 { flags |= 0x40000 }
        return flags
    }
    static func translate(_ text: String, key: (UInt16, UInt32) -> Translation) -> [ControllerKeyboardStroke] {
        var result: [ControllerKeyboardStroke] = []

        for unit in text.utf16 {
            let wanted: UInt16 = unit == 10 ? 13 : unit

            // A low surrogate completes the Unicode-only stroke of its high surrogate.
            if UTF16.isTrailSurrogate(wanted), let last = result.last, last.keyCode == unicodeOnlyKeyCode,
               let pending = last.unicode, pending.count == 1, UTF16.isLeadSurrogate(pending[0]) {
                result[result.count - 1] = unicodeOnly(pending + [wanted])
                continue
            }

            result.append(keyStroke(for: wanted, key: key) ?? unicodeOnly([wanted]))
        }

        return result
    }

    private static func keyStroke(for wanted: UInt16, key: (UInt16, UInt32) -> Translation) -> ControllerKeyboardStroke? {
        for modifiers in modifierOrder {
            for code in UInt16(0)...127 {
                let value = key(code, (modifiers >> 8) & 0xff)

                if value.status == 0, value.units.first == wanted {
                    return .init(keyCode: code, flags: flags(modifiers), unicode: value.units)
                }
            }
        }

        return nil
    }

    private static func unicodeOnly(_ units: [UInt16]) -> ControllerKeyboardStroke {
        .init(keyCode: unicodeOnlyKeyCode, flags: 0, unicode: units)
    }
}
