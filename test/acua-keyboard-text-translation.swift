import Foundation

// Unit tests for type_text's text-to-keystroke translation, with a fake U.S.
// keyboard layout. No events are posted.

@main
enum AcuaKeyboardTextTranslationTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    private static let shift: UInt32 = 0x200 >> 8

    /// A small U.S. layout: a/A, e/E, space and Return. It has no key for é or emoji.
    private static func usLayout(_ code: UInt16, _ modifiers: UInt32) -> ControllerKeyboardTextTranslation.Translation {
        let units: [UInt16]

        switch (code, modifiers) {
        case (0, 0): units = Array("a".utf16)
        case (0, shift): units = Array("A".utf16)
        case (14, 0): units = Array("e".utf16)
        case (49, 0): units = Array(" ".utf16)
        case (36, 0): units = [13]
        default: units = []
        }

        return .init(status: 0, units: units)
    }

    private static func translate(_ text: String) -> [ControllerKeyboardStroke] {
        ControllerKeyboardTextTranslation.translate(text, key: usLayout)
    }

    private static func keyStroke(_ code: UInt16, _ text: String, flags: UInt64 = 0) -> ControllerKeyboardStroke {
        .init(keyCode: code, flags: flags, unicode: Array(text.utf16))
    }

    private static func unicodeStroke(_ text: String) -> ControllerKeyboardStroke {
        .init(keyCode: ControllerKeyboardTextTranslation.unicodeOnlyKeyCode, flags: 0, unicode: Array(text.utf16))
    }

    static func main() {
        let mapped = translate("aA e")
        check("Translate_CharactersOnTheLayout_UseTheirKeys",
              mapped == [keyStroke(0, "a"), keyStroke(0, "A", flags: 0x20000), keyStroke(49, " "), keyStroke(14, "e")],
              "\(mapped)")

        check("Translate_Newline_IsSentAsReturn", translate("\n") == [keyStroke(36, "\r")])

        let accented = translate("caf\u{E9}")
        check("Translate_CharacterWithoutKey_IsSentAsUnicode",
              accented.last == unicodeStroke("\u{E9}"), "\(accented)")

        let emoji = translate("🙂")
        check("Translate_EmojiWithoutKey_KeepsItsSurrogatePairInOneStroke",
              emoji == [unicodeStroke("🙂")], "\(emoji)")

        let combining = translate("e\u{301}")
        check("Translate_CombiningMarkWithoutKey_FollowsItsBaseCharacter",
              combining == [keyStroke(14, "e"), unicodeStroke("\u{301}")], "\(combining)")

        let mixed = translate("a 🙂 \u{E9}a")
        check("Translate_MixedText_KeepsTheOriginalOrder",
              mixed == [keyStroke(0, "a"), keyStroke(49, " "), unicodeStroke("🙂"), keyStroke(49, " "),
                        unicodeStroke("\u{E9}"), keyStroke(0, "a")], "\(mixed)")

        print("\(passed) keyboard text translation tests passed")
    }
}
