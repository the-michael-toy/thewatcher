import Foundation

/// What latency is normal at one place: its typical round trip and how much
/// it usually swings. Satellite and fiber get different notions of "slow".
public struct Baseline: Equatable, Sendable {
    public private(set) var samples: [Double] = []
    public static let capacity = 600
    static let minimumSamples = 20

    public init(samples: [Double] = []) {
        self.samples = Array(samples.suffix(Self.capacity))
    }

    public mutating func add(_ ms: Double) {
        samples.append(ms)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    public var isLearned: Bool { samples.count >= Self.minimumSamples }

    public var median: Double? { percentile(0.5) }

    public func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }

    /// Latency above this counts as slow here: well beyond both the typical
    /// round trip and the usual swing. Nil until enough samples say what's
    /// normal; nothing counts as slow before then.
    public var slowThresholdMs: Double? {
        guard isLearned, let m = percentile(0.5), let p90 = percentile(0.9) else { return nil }
        let spread = p90 - m
        return max(2.5 * m, m + 4 * spread, m + 50)
    }
}
