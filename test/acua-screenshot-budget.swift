import Foundation

// Unit tests for the screenshot size budget: which encodings are tried, in
// which order, and which written file is kept. The writer is a fake that
// reports a size per encoding; no image is encoded.

private final class FakeWriter {
    var sizes: [AcuaScreenshotEncodingAttempt: Int]
    var written: [AcuaScreenshotEncodingAttempt] = []
    var discarded: [AcuaScreenshotEncodingAttempt] = []

    init(_ sizes: [AcuaScreenshotEncodingAttempt: Int]) { self.sizes = sizes }

    func write(_ attempt: AcuaScreenshotEncodingAttempt) -> (AcuaScreenshotEncodingAttempt, Int) {
        written.append(attempt)
        return (attempt, sizes[attempt] ?? 0)
    }
}

@main
enum AcuaScreenshotBudgetTests {
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

    private static func configuration(format: AcuaScreenshotFormat = .jpeg, quality: Double = 0.8,
                                      maxBytes: Int = 1000) -> AcuaScreenshotConfiguration {
        var configuration = AcuaScreenshotConfiguration()
        configuration.format = format
        configuration.jpegQuality = quality
        configuration.maxImageBytes = maxBytes
        return configuration
    }

    private static func run(_ configuration: AcuaScreenshotConfiguration, _ writer: FakeWriter)
        throws -> AcuaScreenshotBudget.Written<AcuaScreenshotEncodingAttempt> {
        try AcuaScreenshotBudget.write(AcuaScreenshotBudget.attempts(for: configuration), maxBytes: configuration.maxImageBytes,
                                       write: writer.write, discard: { writer.discarded.append($0) })
    }

    static func main() throws {
        check("Attempts_JPEG_ConfiguredQualityThenLowerFallbacks",
              AcuaScreenshotBudget.attempts(for: configuration()) == [.jpeg(quality: 0.8), .jpeg(quality: 0.6),
                                                                      .jpeg(quality: 0.4), .jpeg(quality: 0.25)])

        // A fallback is never a higher quality than the user asked for.
        check("Attempts_LowConfiguredQuality_SkipsHigherFallbacks",
              AcuaScreenshotBudget.attempts(for: configuration(quality: 0.5)) == [.jpeg(quality: 0.5), .jpeg(quality: 0.4),
                                                                                  .jpeg(quality: 0.25)])

        check("Attempts_PNG_ThenJPEGAtConfiguredQualityThenFallbacks",
              AcuaScreenshotBudget.attempts(for: configuration(format: .png)) == [.png, .jpeg(quality: 0.8), .jpeg(quality: 0.6),
                                                                                  .jpeg(quality: 0.4), .jpeg(quality: 0.25)])

        check("Attempts_NoLimit_OnlyTheConfiguredEncoding",
              AcuaScreenshotBudget.attempts(for: configuration(format: .png, maxBytes: 0)) == [.png])

        let small = FakeWriter([.jpeg(quality: 0.8): 900])
        let kept = try run(configuration(), small)
        check("Write_FirstWithinLimit_KeptWithoutRetry",
              kept.file == .jpeg(quality: 0.8) && kept.withinLimit && small.written.count == 1 && small.discarded.isEmpty)

        let large = FakeWriter([.png: 5000, .jpeg(quality: 0.8): 1500, .jpeg(quality: 0.6): 990])
        let fallback = try run(configuration(format: .png), large)
        check("Write_PNGOverLimit_FallsBackToFirstJPEGWithinLimit",
              fallback.attempt == .jpeg(quality: 0.6) && fallback.byteCount == 990 && fallback.withinLimit)
        check("Write_RejectedAttempts_AreDiscarded", large.discarded == [.png, .jpeg(quality: 0.8)])

        let exact = FakeWriter([.jpeg(quality: 0.8): 1000])
        check("Write_SizeEqualToLimit_IsWithinLimit", try run(configuration(), exact).withinLimit && exact.written.count == 1)

        // Nothing fits: the smallest attempt is still delivered, marked over
        // the limit, rather than failing the request with no image.
        let huge = FakeWriter([.jpeg(quality: 0.8): 9000, .jpeg(quality: 0.6): 8000, .jpeg(quality: 0.4): 7000,
                               .jpeg(quality: 0.25): 6000])
        let last = try run(configuration(), huge)
        check("Write_NothingFits_KeepsLastAttemptMarkedOverLimit",
              last.attempt == .jpeg(quality: 0.25) && !last.withinLimit && huge.discarded.count == 3)

        let unlimited = FakeWriter([.png: 50_000_000])
        let any = try run(configuration(format: .png, maxBytes: 0), unlimited)
        check("Write_NoLimit_KeepsFirstWhateverItsSize", any.attempt == .png && any.withinLimit && unlimited.discarded.isEmpty)

        // A write error is not retried with another encoding.
        var failures = 0
        do {
            _ = try AcuaScreenshotBudget.write([.png, .jpeg(quality: 0.8)], maxBytes: 10,
                write: { (_: AcuaScreenshotEncodingAttempt) -> (Int, Int) in failures += 1; throw CocoaError(.fileWriteNoPermission) },
                discard: { _ in })
            check("Write_WriterThrows_Rethrows", false)
        } catch {
            check("Write_WriterThrows_RethrowsWithoutRetry", failures == 1)
        }

        print("\(passed) screenshot budget tests passed")
    }
}
