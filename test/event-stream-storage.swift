import Foundation

@main
struct EventStreamStorageTests {
    static var checks = 0
    static func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
        do { guard try condition() else { fatalError("FAIL: \(name)") } }
        catch { fatalError("FAIL: \(name): \(error)") }
        checks += 1
        print("PASS: \(name)")
    }
    static func rejects<T: Decodable>(_ type: T.Type, _ json: String) -> Bool {
        do { _ = try decoder().decode(type, from: Data(json.utf8)); return false }
        catch { return true }
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cua-event-stream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let boundary = EventStreamRecord(id: 1, timestamp: date, kind: .sessionStarted)
        let writer = try EventStreamJSONLWriter(sessionID: "session-01", rootDirectoryURL: temp)
        let events = temp.appendingPathComponent("session-01/events.jsonl")
        check("session directory and events filename", writer.directoryURL == temp.appendingPathComponent("session-01", isDirectory: true) && writer.eventsURL == events)
        check("fresh events file is empty", try Data(contentsOf: events).isEmpty)
        let initialFiles = try FileManager.default.contentsOfDirectory(atPath: writer.directoryURL.path)
        check("no invented suppressed-events file", writer.suppressedEventsURL == nil && initialFiles == ["events.jsonl"])
        try writer.append(boundary)
        let golden = #"{"id":1,"kind":"session.started","timestamp":"2024-01-01T00:00:00Z"}"# + "\n"
        check("boundary golden bytes: ISO date, sorted keys, omitted optionals, LF", try String(contentsOf: events, encoding: .utf8) == golden)

        let element = EventStreamAXElement(role: "AXTextField", title: "ação 🧪", value: "linha 1\nlinha 2", identifier: "editor")
        let app = EventStreamApp(name: "Fixture", secureInput: false, processIdentifier: 123, bundleIdentifier: "local.fixture")
        let window = EventStreamWindow(title: "Documento", url: "https://example.test/a/b", windowID: UInt32.max)
        let record = EventStreamRecord(id: 2, timestamp: date, kind: .mouseDrag, app: app, window: window,
            mouse: .init(button: "left", clickCount: 2, modifiers: ["shift"], target: element,
                origin: .init(app: app, window: window, element: element), destination: .init(element: .init(role: "AXSlider"))),
            keyboard: .init(text: "olá\n世界", keyEquivalent: "q", modifiers: [], target: element),
            selection: .init(target: element, selectedText: "🧪", selectedRange: .init(location: 0, length: 2), selectedItems: [element]),
            ax: .init(mode: .diffFromPrevious, text: "- antigo\n+ novo"), diagnostic: .init(message: "linha\n2"))
        try writer.append(record)
        let bytes = try Data(contentsOf: events)
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
        check("embedded newlines do not split JSONL records", lines.count == 2 && bytes.last == 10)
        check("URL slashes are not escaped", lines[1].contains("https://example.test/a/b") && !lines[1].contains("\\/"))
        check("Unicode and escaped content round trip", try decoder().decode(EventStreamRecord.self, from: Data(lines[1].utf8)) == record)
        let object = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        check("drag endpoints carry app/window/element", ((object["mouse"] as? [String: Any])?["origin"] as? [String: Any])?["element"] != nil)
        check("selectedRange uses UTF-16 length without rewriting", ((object["selection"] as? [String: Any])?["selectedRange"] as? [String: Int]) == ["location":0,"length":2])

        writer.close()
        writer.close()
        try writer.append(.init(id: 999, timestamp: date, kind: .debugError))
        check("close is idempotent and append after close is a no-op", try Data(contentsOf: events) == bytes)
        let reopened = try EventStreamJSONLWriter(sessionID: "session-01", rootDirectoryURL: temp)
        try reopened.append(.init(id: 3, timestamp: date, kind: .sessionEnded))
        reopened.close()
        let reopenedBytes = try Data(contentsOf: events)
        check("reopening appends without truncation", reopenedBytes.starts(with: bytes) && reopenedBytes.count > bytes.count)
        let third = String(decoding: reopenedBytes, as: UTF8.self).split(separator: "\n")[2]
        check("appended session boundary decodes", try decoder().decode(EventStreamRecord.self, from: Data(third.utf8)).kind == .sessionEnded)

        let metadata = EventStreamMetadata(id: "session-01", eventsPath: events.path, startedAt: date, endedAt: date, endReason: .toolStopped)
        let metadataURL = writer.directoryURL.appendingPathComponent("session.json")
        try EventStreamMetadataStorage.write(metadata, to: metadataURL)
        let metadataBytes = try Data(contentsOf: metadataURL)
        let metadataText = String(decoding: metadataBytes, as: UTF8.self)
        check("metadata uses pretty JSON and unescaped paths", metadataText.contains("\n") && metadataText.contains(events.path) && !metadataText.contains("\\/"))
        check("metadata has the stop reason and dates", try decoder().decode(EventStreamMetadata.self, from: metadataBytes) == metadata)
        let metadataObject = try JSONSerialization.jsonObject(with: metadataBytes) as! [String: Any]
        check("nil event counts are absent, not fabricated zeroes", metadataObject["eventCount"] == nil && metadataObject["suppressedEventCount"] == nil)
        try EventStreamMetadataStorage.write(.init(id: "replacement", eventsPath: "/tmp/other", startedAt: date), to: metadataURL)
        check("metadata atomically replaces previous document", try decoder().decode(EventStreamMetadata.self, from: Data(contentsOf: metadataURL)).id == "replacement")

        let reasons = ["tool_stopped","debug_ui_stopped","recording_controls_stopped","recording_controls_cancelled","max_duration","service_terminated"]
        check("all six end reasons preserve order and spelling", EventStreamEndReason.allCases.map(\.rawValue) == reasons)
        for reason in reasons {
            let decoded = try decoder().decode(EventStreamStopRequest.self, from: Data("{\"reason\":\"\(reason)\"}".utf8))
            check("stop accepts \(reason)", decoded.reason.rawValue == reason)
        }
        check("stop requires reason", rejects(EventStreamStopRequest.self, "{}"))
        check("stop rejects null reason", rejects(EventStreamStopRequest.self, #"{"reason":null}"#))
        check("stop rejects unknown reason", rejects(EventStreamStopRequest.self, #"{"reason":"stopped"}"#))
        check("stop rejects wrong reason type", rejects(EventStreamStopRequest.self, #"{"reason":true}"#))
        check("start accepts empty object and ignores unknown fields", try decoder().decode(EventStreamStartRequest.self, from: Data(#"{"unused":1}"#.utf8)) == EventStreamStartRequest())
        check("status accepts empty object", try decoder().decode(EventStreamStatusRequest.self, from: Data("{}".utf8)) == EventStreamStatusRequest())
        for value in ["[]", "null", "true", "123", #""text""#] {
            check("empty request decoder accepts \(value) as an empty request", !rejects(EventStreamStartRequest.self, value) && !rejects(EventStreamStatusRequest.self, value))
        }
        check("empty request still rejects malformed JSON", rejects(EventStreamStartRequest.self, "{") && rejects(EventStreamStatusRequest.self, "{"))
        check("event kinds match all twelve values", EventStreamEventKind.allCases.map(\.rawValue) == ["session.started","session.ended","window.changed","mouse.click","mouse.context_menu","mouse.drag","keyboard.text_input","keyboard.submit","keyboard.shortcut","terminal.value_changed","selection.changed","debug.error"])
        check("unknown event kind rejected", rejects(EventStreamEventKind.self, #""mouse.move""#))
        check("AX mode has both exact values", EventStreamAXTree.Mode.allCases.map(\.rawValue) == ["fullTree","diffFromPrevious"])
        check("AX tree requires text", rejects(EventStreamAXTree.self, #"{"mode":"fullTree"}"#))
        check("diagnostic requires message", rejects(EventStreamDiagnostic.self, "{}"))
        check("empty AX element is valid", try decoder().decode(EventStreamAXElement.self, from: Data("{}".utf8)) == EventStreamAXElement())
        check("app defaults missing secure-input flag to false", try decoder().decode(EventStreamApp.self, from: Data(#"{"name":"Fixture"}"#.utf8)).secureInput == false)
        check("mouse defaults missing modifiers to empty", try decoder().decode(EventStreamMouseInteraction.self, from: Data("{}".utf8)).modifiers.isEmpty)
        check("keyboard defaults missing modifiers to empty", try decoder().decode(EventStreamKeyboardInteraction.self, from: Data("{}".utf8)).modifiers.isEmpty)
        check("selection defaults missing selectedItems to empty", try decoder().decode(EventStreamSelection.self, from: Data("{}".utf8)).selectedItems.isEmpty)
        check("PID enforces Int32 bounds", rejects(EventStreamApp.self, #"{"secureInput":false,"processIdentifier":2147483648}"#))
        check("window ID enforces UInt32 bounds", rejects(EventStreamWindow.self, #"{"windowID":-1}"#) && rejects(EventStreamWindow.self, #"{"windowID":4294967296}"#))
        check("record requires id/timestamp/kind", rejects(EventStreamRecord.self, "{}") && rejects(EventStreamRecord.self, #"{"id":1,"kind":"session.started"}"#))
        let status = EventStreamSessionStatus(isRecording: false, maxDurationSeconds: 1800)
        let statusObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Any]
        check("initial status contains only required fields", statusObject.count == 2 && statusObject["isRecording"] as? Bool == false && statusObject["maxDurationSeconds"] as? Int == 1800)
        check("status requires recording flag and maximum", rejects(EventStreamSessionStatus.self, "{}"))

        let badRoot = temp.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: badRoot)
        do { _ = try EventStreamJSONLWriter(sessionID: "session", rootDirectoryURL: badRoot); fatalError("accepted file as directory") }
        catch { check("directory creation failure propagates", true) }
        let badEvents = temp.appendingPathComponent("bad/events.jsonl")
        try FileManager.default.createDirectory(at: badEvents, withIntermediateDirectories: true)
        do { _ = try EventStreamJSONLWriter(sessionID: "bad", rootDirectoryURL: temp); fatalError("accepted directory as events file") }
        catch { check("file-handle opening failure propagates", true) }
        let beforeFailedWrite = try Data(contentsOf: metadataURL)
        do { try EventStreamMetadataStorage.write(metadata, to: badRoot.appendingPathComponent("session.json")); fatalError("accepted invalid metadata destination") }
        catch { check("metadata failure propagates without replacing prior file", try Data(contentsOf: metadataURL) == beforeFailedWrite) }
        check("existing metadata remains valid after failed write elsewhere", try decoder().decode(EventStreamMetadata.self, from: Data(contentsOf: metadataURL)).id == "replacement")
        print("EVENT STREAM CONTRACT AND STORAGE: \(checks) checks passed")
    }
}
