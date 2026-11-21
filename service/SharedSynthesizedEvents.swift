/// One process-wide source for normal mouse actions and lock-screen reveals.
/// Creating a controller or changing an app/session never resets this sequence.
enum SynthesizedEventNumbers {
    static let shared = SynthesizedEventNumberSequence()
}
