import Foundation

// Unit tests for the approval form the service draws for MCP clients without
// elicitation: which elicitation schemas it can show, in what order, and the
// answer it sends back in the elicitation result shape. No dialog is shown.

@main
enum AcuaApprovalFormTests {
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

    private static func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private static func rejects(_ body: [String: Any]) -> AcuaApprovalFormError? {
        do {
            _ = try AcuaApprovalForm(body)
            return nil
        } catch let error as AcuaApprovalFormError {
            return error
        } catch {
            return nil
        }
    }

    // The forms the helper sends, as ClientMCPEventStream and
    // ClientMCPMessagesApproval build them.
    private static let recording = #"""
        {"message": "Allow the agent to record your actions on your Mac?", "detail": "Until you press Stop.",
         "requestedSchema": {"type": "object", "properties": {}}}
        """#

    private static let readChats = #"""
        {"message": "Allow reading messages in the following chats?", "requestedSchema": {"type": "object", "required": ["scope"],
         "properties": {
           "scope": {"type": "string", "title": "Allow access:", "default": "session",
                     "oneOf": [{"const": "session", "title": "For this conversation"}, {"const": "always", "title": "Always"}]},
           "chats": {"type": "array", "title": "Select chats:", "default": [],
                     "items": {"anyOf": [{"const": "chat-a", "title": "Ana"}, {"const": "chat-b", "title": "Bruno"}]}}}}}
        """#

    private static let send = #"""
        {"message": "Send this to “Ana”?", "requestedSchema": {"type": "object", "required": ["text"],
         "properties": {
           "text": {"type": "string", "default": "See you at 6", "minLength": 1, "maxLength": 10000, "description": "Attachment: photo.jpg"},
           "trust_chat": {"type": "boolean", "title": "Always allow sending to this chat", "default": false}}}}
        """#

    static func main() throws {
        try parsing()
        try answers()
        rejections()
        print("\(passed) approval form tests passed")
    }

    // MARK: - Parsing

    private static func parsing() throws {
        let recordingForm = try AcuaApprovalForm(json(recording))
        check("Form_EmptySchema_IsAPlainAllowOrDeny", recordingForm.fields.isEmpty)
        check("Form_Detail_IsKept", recordingForm.detail == "Until you press Stop.")
        check("Form_Message_IsKept", recordingForm.message == "Allow the agent to record your actions on your Mac?")

        let read = try AcuaApprovalForm(json(readChats))
        check("Form_ReadChats_ListsChatsBeforeScope", read.fields.map(\.key) == ["chats", "scope"], "\(read.fields.map(\.key))")
        check("Form_ReadChats_ChatsAreCheckboxes", read.fields.first == .multipleChoice(key: "chats", title: "Select chats:",
            options: [.init(value: "chat-a", title: "Ana"), .init(value: "chat-b", title: "Bruno")], selected: []))
        check("Form_ReadChats_ScopeIsAChoiceWithItsDefault", read.fields.last == .choice(key: "scope", title: "Allow access:",
            options: [.init(value: "session", title: "For this conversation"), .init(value: "always", title: "Always")], selected: "session"))

        let sendForm = try AcuaApprovalForm(json(send))
        check("Form_Send_TextIsEditableWithItsDefault", sendForm.fields.first == .text(key: "text", title: nil,
            detail: "Attachment: photo.jpg", value: "See you at 6"))
        check("Form_Send_TrustIsACheckbox", sendForm.fields.last == .toggle(key: "trust_chat",
            title: "Always allow sending to this chat", isOn: false))

        let enumChoice = try AcuaApprovalForm(json(#"""
            {"message": "m", "requestedSchema": {"type": "object", "properties": {"size": {"type": "string", "enum": ["s", "m"]}}}}
            """#))
        check("Form_StringEnum_IsAChoiceTitledByValue", enumChoice.fields == [.choice(key: "size", title: nil,
            options: [.init(value: "s", title: "s"), .init(value: "m", title: "m")], selected: nil)])
    }

    // MARK: - Answers

    private static func answers() throws {
        let read = try AcuaApprovalForm(json(readChats))
        let accepted = read.answer(.accept, values: ["chats": .choices(["chat-b"]), "scope": .choice("always")])
        check("Answer_Accept_IsTheElicitationResultShape",
              accepted["action"] as? String == "accept"
                  && (accepted["content"] as? [String: Any])?["chats"] as? [String] == ["chat-b"]
                  && (accepted["content"] as? [String: Any])?["scope"] as? String == "always", "\(accepted)")

        let unanswered = read.answer(.accept, values: [:])
        check("Answer_AcceptWithoutValues_SendsTheDefaults",
              (unanswered["content"] as? [String: Any])?["scope"] as? String == "session"
                  && (unanswered["content"] as? [String: Any])?["chats"] as? [String] == [], "\(unanswered)")

        let sendForm = try AcuaApprovalForm(json(send))
        let edited = sendForm.answer(.accept, values: ["text": .text("See you at 7"), "trust_chat": .toggle(true)])
        let content = edited["content"] as? [String: Any]
        check("Answer_EditedText_IsSent", content?["text"] as? String == "See you at 7")
        check("Answer_Toggle_IsABoolean", content?["trust_chat"] as? Bool == true)

        let declined = sendForm.answer(.decline, values: ["text": .text("ignored")])
        check("Answer_Decline_HasNoContent", declined["action"] as? String == "decline" && declined["content"] == nil)

        let cancelled = sendForm.answer(.cancel, values: [:])
        check("Answer_Cancel_HasNoContent", cancelled["action"] as? String == "cancel" && cancelled["content"] == nil)

        check("Answer_IsSerializable", JSONSerialization.isValidJSONObject(edited))
    }

    // MARK: - Rejections

    private static func rejections() {
        check("Form_MissingMessage_IsRejected",
              rejects(["requestedSchema": ["type": "object", "properties": [String: Any]()]]) == .missingMessage)

        check("Form_NumberField_IsRejectedRatherThanDrawnWrong",
              rejects(json(#"{"message": "m", "requestedSchema": {"type": "object", "properties": {"n": {"type": "number"}}}}"#))
                  == .unsupportedField("n"))

        check("Form_ArrayWithoutOptions_IsRejected",
              rejects(json(#"{"message": "m", "requestedSchema": {"type": "object", "properties": {"a": {"type": "array"}}}}"#))
                  == .unsupportedField("a"))

        check("Form_SchemaNotAnObject_IsRejected",
              rejects(json(#"{"message": "m", "requestedSchema": {"type": "string"}}"#)) == .schemaNotAnObject)
    }
}
