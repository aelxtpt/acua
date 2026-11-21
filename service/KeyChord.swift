import AppKit
import CoreFoundation

struct KeyChord {
    struct Modifier {
        let code: CGKeyCode
        let flag: CGEventFlags
    }
    let modifiers: [Modifier]
    let key: CGKeyCode?
    let literal: String?
    var flags: CGEventFlags { modifiers.reduce(CGEventFlags()) { $0.union($1.flag) } }

    static func parse(_ input: String) throws -> KeyChord {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw ServiceError(.unhandledEvent, "key is required") }
        var parts: [String]
        if input == "+" { parts = ["plus"] }
        else if input.hasSuffix("++") {
            parts = input.dropLast(2).split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            parts.append("plus")
        } else { parts = input.split(separator: "+", omittingEmptySubsequences: false).map(String.init) }
        let map: [String: Modifier] = [
            "control": .init(code: 59, flag: .maskControl), "ctrl": .init(code: 59, flag: .maskControl),
            "control_l": .init(code: 59, flag: .maskControl), "control_r": .init(code: 62, flag: .maskControl),
            "shift": .init(code: 56, flag: .maskShift), "shift_l": .init(code: 56, flag: .maskShift), "shift_r": .init(code: 60, flag: .maskShift),
            "alt": .init(code: 58, flag: .maskAlternate), "option": .init(code: 58, flag: .maskAlternate),
            "alt_l": .init(code: 58, flag: .maskAlternate), "alt_r": .init(code: 61, flag: .maskAlternate),
            "super": .init(code: 55, flag: .maskCommand), "cmd": .init(code: 55, flag: .maskCommand),
            "command": .init(code: 55, flag: .maskCommand), "meta": .init(code: 55, flag: .maskCommand),
            "super_l": .init(code: 55, flag: .maskCommand), "super_r": .init(code: 54, flag: .maskCommand),
            "fn": .init(code: 63, flag: .maskSecondaryFn),
        ]
        var modifiers: [Modifier] = []
        var key: CGKeyCode?
        var literal: String?
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let name = trimmed.lowercased()
            guard !name.isEmpty else { throw ServiceError(.unhandledEvent, "Empty key in chord '\(input)'") }
            if let modifier = map[name] {
                if !modifiers.contains(where: { $0.code == modifier.code }) { modifiers.append(modifier) }
                continue
            }
            guard key == nil && literal == nil else { throw ServiceError(.unhandledEvent, "A chord must contain only one non-modifier key") }
            if name == "plus" {
                key = 24
                if !modifiers.contains(where: { $0.flag == .maskShift }) { modifiers.append(.init(code: 56, flag: .maskShift)) }
            } else if let code = KeyCodes.code(for: name) { key = code }
            else if trimmed.count == 1 { literal = trimmed }
            else { throw ServiceError(.unhandledEvent, "Unknown key '\(trimmed)'") }
        }
        guard literal == nil || modifiers.isEmpty else {
            throw ServiceError(.unhandledEvent, "A modified shortcut requires a supported physical key")
        }
        return KeyChord(modifiers: modifiers, key: key, literal: literal)
    }

    static func duration(_ raw: Any?) throws -> Double {
        guard let raw, !(raw is NSNull) else { return 0 }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 3600 else {
            throw ServiceError(.unhandledEvent, "duration must be a finite number between 0 and 3600 seconds")
        }
        return n.doubleValue
    }
}

struct ClickOptions {
    let count: Int
    let button: Int
    let duration: Double
    let hasExplicitDuration: Bool
    let chord: KeyChord?
    var canUseAXPress: Bool { count == 1 && button == 0 && duration == 0 && chord == nil }
    // The native controller and UIElement.click distinguish an absent hold
    // duration from an explicitly supplied zero.
    var canUseNativeAXPress: Bool { canUseAXPress && !hasExplicitDuration }

    init(_ input: JSON) throws {
        func integer(_ name: String, default fallback: Int, allowed: ClosedRange<Int>) throws -> Int {
            guard let raw = input[name] else { return fallback }
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue >= Double(allowed.lowerBound), n.doubleValue <= Double(allowed.upperBound),
                  allowed.contains(n.intValue) else {
                throw ServiceError(.unhandledEvent, "Invalid \(name)")
            }
            return n.intValue
        }
        count = try integer("clickCount", default: 1, allowed: 1...Int.max)
        button = try integer("mouseButton", default: 0, allowed: 0...Int(UInt32.max))
        duration = try KeyChord.duration(input["duration"])
        hasExplicitDuration = input["duration"].map { !($0 is NSNull) } ?? false
        if let key = input["key"], !(key is NSNull) {
            guard let key = key as? String else { throw ServiceError(.unhandledEvent, "key must be a string") }
            chord = try KeyChord.parse(key)
            guard chord?.literal == nil else { throw ServiceError(.unhandledEvent, "A held click key must be a supported physical key") }
        } else { chord = nil }
    }
}

enum KeyCodes {
    private static let table: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "right": 124, "left": 123, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    ]
    static func code(for name: String) -> CGKeyCode? {
        let key = name.lowercased()
        if let code = table[key] { return code }
        // Function keys F1..F12
        if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) {
            let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            return fkeys[n - 1]
        }
        return nil
    }
}
