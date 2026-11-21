/// ACUA collects no telemetry.
///
/// The approval and lifecycle code raises events at a few points so tests can
/// observe them; every event they produce ends here.
enum DiscardedTelemetry {
    static func drop<Event>(_ event: Event) {}
}
