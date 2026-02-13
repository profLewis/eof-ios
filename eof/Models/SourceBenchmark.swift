import Foundation

/// Benchmark result for a single STAC source.
struct SourceBenchmark: Identifiable {
    let sourceID: SourceID
    let searchLatencyMs: Double?
    let cogHeaderLatencyMs: Double?
    let isReachable: Bool
    let timestamp: Date

    var id: String { sourceID.rawValue }

    /// Composite score (lower is better). nil if unreachable.
    var score: Double? {
        guard isReachable else { return nil }
        let search = searchLatencyMs ?? 10000
        let cog = cogHeaderLatencyMs ?? 10000
        return search * 0.4 + cog * 0.6
    }

    /// Human-readable latency string.
    var latencyLabel: String {
        guard isReachable else { return "unreachable" }
        if let s = searchLatencyMs, let c = cogHeaderLatencyMs {
            return "\(Int(s))ms search, \(Int(c))ms COG"
        } else if let s = searchLatencyMs {
            return "\(Int(s))ms search"
        }
        return "unknown"
    }
}
