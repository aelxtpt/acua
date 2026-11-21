import AppKit
import AVFoundation
import CoreVideo

@main @MainActor
private enum NativePIPWindowTests {
    private final class NativeEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CGWindowID] = []
        var windows: [CGWindowID] { lock.withLock { values } }
        func record(_ id: CGWindowID) { lock.withLock { values.append(id) } }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await testCapture()
                exit(0)
            } catch {
                fputs("FAIL \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    private static func testCapture() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw TestFailure("Screen Recording permission is required") }
        let window = NSWindow(contentRect: CGRect(x: 120, y: 160, width: 320, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .red
        window.orderFrontRegardless()
        defer { window.close() }

        var frameCount = 0
        var pixelSize = CGSize.zero
        var color: NSColor?
        var rightColor: NSColor?
        var cursorBounds: ClosedRange<Double>?
        var cursorFrames = 0
        let windowID = CGWindowID(window.windowNumber)
        // orderFront is asynchronous: the test must publish its own window
        // before passing its ID to a renderer that expects a capture source.
        try await waitFor("owned window is published with valid WindowServer bounds") {
            guard let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
                  let record = records.first,
                  (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid(),
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.width > 0 && frame.height > 0 && frame.width.isFinite && frame.height.isFinite
        }
        let nativeEvents = NativeEvents()
        var nativeObserver = RemoteHostedPIPWindowServerObserver(windowIDs: [windowID]) { id, _ in nativeEvents.record(id) }
        let renderer = RemoteHostedPIPWindowRenderer(windowID: windowID, associatedWindowIDs: [], onCursorFrame: { frame in
            cursorFrames += 1
            cursorBounds = alphaBounds(frame)
        }) { frame in
            frameCount += 1
            pixelSize = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
            color = colorAt(frame, horizontal: 0.5)
            rightColor = colorAt(frame, horizontal: 0.86)
        }
        let producer = try RemoteHostedPIPContentProducer()
        defer { producer.invalidate() }
        var maxDisplaySize: CGFloat = 200
        var refresh: Task<Void, Never>?
        var refreshCount = 0
        var refreshError: (any Error)?
        renderer.setGeometryChangeHandler { [weak renderer] in
            guard let renderer, refresh == nil else { return }
            refresh = Task {
                defer { refresh = nil }
                do {
                    try await renderer.refreshGeometry()
                    let size = renderer.presentationSize(forMaxDisplaySize: maxDisplaySize)
                    try await renderer.resize(producer: producer, isActive: true, size: size)
                    refreshCount += 1
                } catch { refreshError = error }
            }
        }
        defer { refresh?.cancel() }
        let overlay = CursorOverlay.shared
        overlay.observeLocation { _, overlayID, targetID in
            renderer.setCursorWindowID(targetID == windowID ? overlayID : nil)
        }
        defer { overlay.hide(); overlay.observeLocation { _, _, _ in } }
        do {
            let size = try await renderer.prepare(producer: producer, isActive: true, maxDisplaySize: 200)
            try await waitFor("initial red frame") { (color?.redComponent ?? 0) > 0.75 }
            let aspect = pixelSize.height / pixelSize.width
            try check(abs(size.width - 200) < 0.01 && abs(size.height - 200 * aspect) < 0.01,
                      "initial presentation preserves window aspect (presentation \(size), frame \(pixelSize))")
            try check(renderer.sourceProcessIdentifier == getpid(), "renderer identifies the source process")
            let videoLayer = producer.rootLayer.sublayers?.first as? AVSampleBufferDisplayLayer
            try check(videoLayer?.frame.size == size, "remote producer owns the video display layer")
            let cursorLayer = producer.rootLayer.sublayers?.dropFirst().first as? AVSampleBufferDisplayLayer
            try check(cursorLayer?.isHidden == true, "cursor layer starts hidden")
            let cursorY = (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.midY
            overlay.place(at: CGPoint(x: 200, y: cursorY), animated: false, targetWindowID: windowID)
            try await waitFor("separate cursor capture contains artwork over transparent pixels") {
                cursorBounds != nil && cursorLayer?.isHidden == false
            }
            let cursorSize = cursorLayer?.frame.size ?? .zero
            let videoSize = videoLayer?.frame.size ?? .zero
            try check(abs(cursorSize.width - videoSize.width) < 0.01 && abs(cursorSize.height - videoSize.height) < 0.01,
                      "cursor layer aligns with the current source window crop")
            let initialCursor = cursorBounds!.lowerBound
            overlay.place(at: CGPoint(x: 295, y: cursorY), animated: false, targetWindowID: windowID)
            try await waitFor("cursor movement updates the transparent capture") {
                (cursorBounds?.lowerBound ?? 0) > initialCursor + 0.2
            }
            overlay.place(at: CGPoint(x: 295, y: cursorY), animated: false, targetWindowID: windowID + 1)
            try check(cursorLayer?.isHidden == true, "retargeting the same overlay hides the old presentation cursor")
            overlay.place(at: CGPoint(x: 295, y: cursorY), animated: false, targetWindowID: windowID)
            try await waitFor("returning to the target restarts cursor capture") { cursorLayer?.isHidden == false }
            let originalFrame = window.frame
            let beforeMove = refreshCount
            let cursorBeforeMove = cursorBounds!.lowerBound
            window.setFrameOrigin(CGPoint(x: originalFrame.minX + 48, y: originalFrame.minY))
            try await waitFor("moving the source refreshes the cursor crop without another input event") {
                refreshCount > beforeMove && (cursorBounds?.lowerBound ?? 1) < cursorBeforeMove - 0.08
            }
            let beforeRestore = refreshCount
            window.setFrameOrigin(originalFrame.origin)
            try await waitFor("restoring the source restores the cursor coordinates") {
                refreshCount > beforeRestore && abs((cursorBounds?.lowerBound ?? 0) - cursorBeforeMove) < 0.025
            }
            overlay.hide()
            let hiddenCount = cursorFrames
            try await Task.sleep(for: .milliseconds(100))
            try check(cursorLayer?.isHidden == true && cursorFrames == hiddenCount, "hide drops old cursor frames")

            window.backgroundColor = .blue
            window.display()
            try await waitFor("updated blue frame") { (color?.blueComponent ?? 0) > 0.75 }
            let originalPixels = pixelSize
            let nativeBeforeResize = nativeEvents.windows.count
            window.setContentSize(CGSize(width: 400, height: originalFrame.height))
            if nativeObserver != nil {
                try await waitFor("WindowServer delivers the source resize for the explicit window ID") {
                    nativeEvents.windows.count > nativeBeforeResize && nativeEvents.windows.allSatisfy { $0 == windowID }
                }
            }
            try await waitFor("source resize reconfigures capture pixels and presentation aspect") {
                pixelSize.width > originalPixels.width && producer.rootLayer.bounds.height < 102
            }
            window.setContentSize(originalFrame.size)
            do {
                try await waitFor("restoring the source size restores the presentation aspect") {
                    abs(pixelSize.width - originalPixels.width) < 12 &&
                    abs(producer.rootLayer.bounds.height - size.height) < 1
                }
            } catch {
                throw TestFailure("source restoration produced frame \(pixelSize), layer \(producer.rootLayer.bounds.size), window \(window.frame.size), refresh error \(String(describing: refreshError))")
            }
            try check(refreshError == nil, "geometry observer refreshes without a capture error")
            maxDisplaySize = 300
            let resized = renderer.presentationSize(forMaxDisplaySize: 300)
            try await renderer.resize(producer: producer, isActive: true, size: resized)
            let restoredAspect = pixelSize.height / pixelSize.width
            try check(abs(resized.width - 300) < 0.01 && abs(resized.height - 300 * restoredAspect) < 0.01
                      && videoLayer?.frame.size == resized,
                      "resize preserves aspect and updates the video layer")
            let auxiliary = NSWindow(contentRect: CGRect(x: 440, y: 160, width: 120, height: 180),
                                     styleMask: .borderless, backing: .buffered, defer: false)
            auxiliary.isReleasedWhenClosed = false
            auxiliary.backgroundColor = .green
            auxiliary.orderFrontRegardless()
            defer { auxiliary.close() }
            let auxiliaryID = CGWindowID(auxiliary.windowNumber)
            let auxiliaryEvents = NativeEvents()
            let auxiliaryObserver = RemoteHostedPIPWindowServerObserver(windowIDs: [auxiliaryID]) { id, _ in auxiliaryEvents.record(id) }
            defer { withExtendedLifetime(auxiliaryObserver) {} }
            try await renderer.setAssociatedWindowIDs([CGWindowID(auxiliary.windowNumber)])
            try await waitFor("associated window appears in the restarted capture") {
                (rightColor?.greenComponent ?? 0) > 0.65 && (rightColor?.blueComponent ?? 1) < 0.4
            }
            let joined = renderer.presentationSize(forMaxDisplaySize: 300)
            try check(abs(joined.height - 300 * 180 / 440) < 1, "associated window expands the capture geometry")
            let beforeAuxiliaryMove = refreshCount
            auxiliary.setFrameOrigin(CGPoint(x: 480, y: 160))
            try await waitFor("moving an associated window updates the composed capture crop") {
                refreshCount > beforeAuxiliaryMove &&
                abs(producer.rootLayer.bounds.height - 300 * 180 / 480) < 1
            }
            try await renderer.setAssociatedWindowIDs([])
            try await waitFor("removing the associated window restores the standalone capture") {
                (rightColor?.blueComponent ?? 0) > 0.75
            }
            if auxiliaryObserver != nil, nativeObserver != nil {
                let auxiliaryCount = auxiliaryEvents.windows.count
                auxiliary.setContentSize(CGSize(width: 132, height: 187))
                try await waitFor("a second WindowServer subscription receives only its own window") {
                    auxiliaryEvents.windows.count > auxiliaryCount && auxiliaryEvents.windows.allSatisfy { $0 == auxiliaryID }
                }
                let sourceCount = nativeEvents.windows.count
                window.setContentSize(CGSize(width: originalFrame.width + 16, height: originalFrame.height))
                try await waitFor("the first subscription stays active after registering a second window") {
                    nativeEvents.windows.count > sourceCount && nativeEvents.windows.allSatisfy { $0 == windowID }
                }
            }
            await renderer.stop()

            nativeObserver = nil
            let stoppedEvents = nativeEvents.windows.count
            let stoppedCount = frameCount
            window.setContentSize(CGSize(width: originalFrame.width + 32, height: originalFrame.height))
            window.backgroundColor = .green
            window.display()
            try await Task.sleep(for: .milliseconds(250))
            try check(stoppedCount == frameCount && videoLayer?.superlayer == nil, "stop detaches the layer and ends frame delivery")
            try check(stoppedEvents == nativeEvents.windows.count, "releasing the native observer removes its WindowServer callbacks")
        } catch {
            await renderer.stop()
            throw error
        }
    }

    private static func alphaBounds(_ frame: CVPixelBuffer) -> ClosedRange<Double>? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let strideBytes = CVPixelBufferGetBytesPerRow(frame)
        var minX = width
        var maxX = 0
        var hasTransparency = false
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                let alpha = base[y * strideBytes + x * 4 + 3]
                if alpha < 10 { hasTransparency = true }
                if alpha > 100 { minX = min(minX, x); maxX = max(maxX, x) }
            }
        }
        guard hasTransparency, minX < maxX else { return nil }
        return Double(minX) / Double(width)...Double(maxX) / Double(width)
    }

    private static func colorAt(_ frame: CVPixelBuffer, horizontal: Double) -> NSColor? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let offset = CVPixelBufferGetBytesPerRow(frame) * (CVPixelBufferGetHeight(frame) / 2)
            + 4 * Int(Double(CVPixelBufferGetWidth(frame)) * horizontal)
        return NSColor(srgbRed: CGFloat(base[offset + 2]) / 255, green: CGFloat(base[offset + 1]) / 255,
                       blue: CGFloat(base[offset]) / 255, alpha: CGFloat(base[offset + 3]) / 255)
    }

    private static func waitFor(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try check(condition(), description)
    }

    private static func check(_ passed: Bool, _ description: String) throws {
        guard passed else { throw TestFailure(description) }
        print("PASS \(description)")
    }
}
