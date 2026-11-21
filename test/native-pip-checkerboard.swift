import CoreVideo
import Foundation
import QuartzCore

private final class WeakReference { weak var value: AnyObject?; init(_ value: AnyObject) { self.value = value } }

@main enum Tests {
    @MainActor static func main() async throws {
        let corpusURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [String: Any]
        let destination = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : NSTemporaryDirectory() + "cua-pip-checkerboard-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(message)")
        }
        func normalized(_ value: [String: Any]) -> [String: Any] {
            var value = value
            if var error = value["error"] as? [String: Any], let domain = error["domain"] as? String {
                error["domain"] = domain.replacingOccurrences(of: #"\$[0-9a-fA-F]+"#, with: "$<context>", options: .regularExpression)
                value["error"] = error
            }
            return value
        }
        let producer = try RemoteHostedPIPContentProducer()
        var buffer: CVPixelBuffer?, callbacks = 0, callbackAfterCommit = true
        var renderer: RemoteHostedPIPCheckerboardRenderer? = RemoteHostedPIPCheckerboardRenderer { value in
            buffer = value; callbacks += 1
            callbackAfterCommit = callbackAfterCommit && Thread.isMainThread && producer.rootLayer.sublayers?.count == 1 && producer.rootLayer.contents != nil
        }
        let expected = corpus["cases"] as! [[String: Any]]
        var rows = [[String: Any]]()
        for (index, tuple) in CheckerboardFixture.cases.enumerated() {
            let (name, active, size) = tuple
            let oldStripe = producer.rootLayer.sublayers?.first, oldBuffer = buffer
            var failure: Swift.Error?
            do { try renderer!.render(producer: producer, isActive: active, size: size) } catch { failure = error }
            var row = CheckerboardFixture.snapshot(root: producer.rootLayer, buffer: buffer, previousStripe: oldStripe, previousBuffer: oldBuffer, error: failure)
            row["name"] = name; row["active"] = active; row["requestedSize"] = [size.width, size.height]
            rows.append(row)
            if !NSDictionary(dictionary: normalized(row)).isEqual(to: expected[index]) {
                try! JSONSerialization.data(withJSONObject: ["actual": normalized(row), "expected": expected[index]], options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("mismatch.json"))
            }
            check(NSDictionary(dictionary: normalized(row)).isEqual(to: expected[index]), "native image, buffer, layer, animation and error state: \(name)")
            if let buffer, failure == nil { try CheckerboardFixture.logicalPixels(buffer).write(to: destination.appendingPathComponent(name + ".bgra")) }
        }
        let normalization = corpus["normalization"] as! [[String: String]]
        for (i, value) in CheckerboardFixture.normalizationValues.enumerated() {
            let result = RemoteHostedPIPCheckerboardRenderer.normalizedMaxDisplaySize(value)
            check(String(Double(result).bitPattern) == normalization[i]["outputBits"] && String(value.bitPattern) == normalization[i]["inputBits"], "size normalization bit pattern \(i)")
        }
        check(callbacks == 17, "each successful render delivers one actual buffer and failures deliver none")
        check(callbackAfterCommit, "pixel callbacks run on main thread after image and stripe installation")
        var asyncRows = [[String: Any]]()
        for (i, value) in CheckerboardFixture.normalizationValues.enumerated() {
            let oldStripe = producer.rootLayer.sublayers?.first, oldBuffer = buffer
            let size = try await renderer!.prepare(producer: producer, isActive: true, maxDisplaySize: value)
            var row = CheckerboardFixture.snapshot(root: producer.rootLayer, buffer: buffer, previousStripe: oldStripe, previousBuffer: oldBuffer, error: nil)
            row["name"] = "prepare-\(i)"; row["returnSize"] = [size.width, size.height]; row["inputBits"] = String(value.bitPattern)
            asyncRows.append(row)
        }
        for (i, size) in [CGSize(width: 49.75, height: 97.5), .init(width: 96, height: 48), .zero, .init(width: -1, height: 10)].enumerated() {
            let oldStripe = producer.rootLayer.sublayers?.first, oldBuffer = buffer
            var failure: Swift.Error?
            do { try await renderer!.resize(producer: producer, isActive: false, size: size) } catch { failure = error }
            var row = CheckerboardFixture.snapshot(root: producer.rootLayer, buffer: buffer, previousStripe: oldStripe, previousBuffer: oldBuffer, error: failure)
            row["name"] = "resize-\(i)"; row["requestedSize"] = [size.width, size.height]; asyncRows.append(row)
        }
        let oldStripe = producer.rootLayer.sublayers?.first, oldBuffer = buffer
        await renderer!.stop()
        var stopped = CheckerboardFixture.snapshot(root: producer.rootLayer, buffer: buffer, previousStripe: oldStripe, previousBuffer: oldBuffer, error: nil)
        stopped["name"] = "stop"; asyncRows.append(stopped)
        do {
        let currentRenderer = renderer!
        let cancelled = Task { @MainActor in
            let oldStripe = producer.rootLayer.sublayers?.first, oldBuffer = buffer
            let size = try await currentRenderer.prepare(producer: producer, isActive: false, maxDisplaySize: 101.5)
            var row = CheckerboardFixture.snapshot(root: producer.rootLayer, buffer: buffer, previousStripe: oldStripe, previousBuffer: oldBuffer, error: nil)
            row["name"] = "cancelled-prepare"; row["returnSize"] = [size.width, size.height]; row["taskCancelled"] = Task.isCancelled; asyncRows.append(row)
        }
        cancelled.cancel(); try await cancelled.value
        }
        let expectedAsync = corpus["asyncCases"] as! [[String: Any]]
        for (i, row) in asyncRows.enumerated() {
            if !NSDictionary(dictionary: normalized(row)).isEqual(to: expectedAsync[i]) {
                try! JSONSerialization.data(withJSONObject: ["actual": normalized(row), "expected": expectedAsync[i]], options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("async-mismatch.json"))
            }
            check(NSDictionary(dictionary: normalized(row)).isEqual(to: expectedAsync[i]), "async renderer state: \(row["name"]!)")
        }
        try JSONSerialization.data(withJSONObject: asyncRows, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("async-renderer-results.json"))
        let retainedStripe = producer.rootLayer.sublayers!.first!
        let weakRenderer = WeakReference(renderer!)
        renderer = nil
        check(weakRenderer.value == nil, "renderer releases without an implicit stop or root invalidation")
        check(producer.rootLayer.sublayers!.first === retainedStripe && producer.rootLayer.contents != nil, "native root retains rendered output after renderer release")
        var asyncBuffer: CVPixelBuffer?, asyncCallbacks = 0
        let asyncProducer = try RemoteHostedPIPContentProducer()
        let asyncRenderer = RemoteHostedPIPCheckerboardRenderer { asyncBuffer = $0; asyncCallbacks += 1 }
        let size = try await asyncRenderer.prepare(producer: asyncProducer, isActive: true, maxDisplaySize: .nan)
        check(size == CGSize(width: 200, height: 200) && asyncProducer.rootLayer.frame.size == size, "async prepare renders and returns finite fallback square")
        check(CVPixelBufferGetWidth(asyncBuffer!) == 200 && asyncCallbacks == 1, "async prepare delivers actual IOSurface-backed buffer")
        try await asyncRenderer.resize(producer: asyncProducer, isActive: false, size: CGSize(width: 49.75, height: 97.5))
        check(asyncProducer.rootLayer.frame.size == CGSize(width: 49.75, height: 97.5) && CVPixelBufferGetWidth(asyncBuffer!) == 49 && CVPixelBufferGetHeight(asyncBuffer!) == 97, "async resize preserves fractional layer size and truncates buffer dimensions")
        let beforeError = asyncCallbacks
        do { try await asyncRenderer.resize(producer: asyncProducer, isActive: true, size: .zero); fatalError("Zero resize should throw") } catch {
            check((error as NSError).code == 1 && asyncCallbacks == beforeError, "async resize forwards actual buffer allocation failure without callback")
        }
        let beforeStop = CheckerboardFixture.snapshot(root: asyncProducer.rootLayer, buffer: asyncBuffer, previousStripe: nil, previousBuffer: nil, error: nil)
        await asyncRenderer.stop()
        let afterStop = CheckerboardFixture.snapshot(root: asyncProducer.rootLayer, buffer: asyncBuffer, previousStripe: nil, previousBuffer: nil, error: nil)
        check(NSDictionary(dictionary: beforeStop).isEqual(to: afterStop) && asyncCallbacks == beforeError, "async stop leaves rendered image, animation and callback count intact")
        let contextID = asyncProducer.contextID
        asyncProducer.invalidate()
        check(asyncProducer.contextID == contextID && asyncProducer.rootLayer.contents != nil, "producer invalidation preserves root rendering while detaching native context")
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("renderer-results.json"))
        let result: [String: Any] = ["status": "passed", "checks": checks, "renderCases": rows.count, "normalizationCases": normalization.count,
            "actualNativeProducerAndRendererUsed": true, "remoteHostRenderingExercised": false, "asyncEntriesCompared": true, "asyncCases": asyncRows.count]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("result.json"))
        print("NATIVE PIP CHECKERBOARD PASSED — artifacts: \(destination.path)")
    }
}
