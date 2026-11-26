import Foundation

/// What is normal for one stop at one place: its typical round trip, how much
/// it usually swings, and how often it ignores a ping. Satellite and fiber get
/// different notions of "slow", and an ISP box that drops pings when busy
/// doesn't get blamed for loss it always has.
public struct Baseline: Equatable, Sendable {
    /// Round trips of answered pings, oldest first.
    public private(set) var samples: [Double] = []
    /// Whether each recent ping was lost, oldest first.
    public private(set) var outcomes: [Bool] = []
    public static let capacity = 600
    static let minimumSamples = 20

    /// `pings` are round trips, nil for a lost ping, oldest first.
    public init(pings: [Double?] = []) {
        for ms in pings.suffix(Self.capacity) { add(ms) }
    }

    public init(samples: [Double]) {
        self.init(pings: samples)
    }

    public mutating func add(_ ms: Double?) {
        outcomes.append(ms == nil)
        if outcomes.count > Self.capacity { outcomes.removeFirst(outcomes.count - Self.capacity) }
        guard let ms else { return }
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

    /// Latency above this is a significant problem, not just slow.
    public var verySlowThresholdMs: Double? {
        guard let slow = slowThresholdMs, let m = median else { return nil }
        return max(10 * m, 2 * slow)
    }

    /// The share of pings this stop usually loses; zero until enough are known.
    public var usualLoss: Double {
        guard outcomes.count >= Self.minimumSamples else { return 0 }
        return Double(outcomes.filter { $0 }.count) / Double(outcomes.count)
    }
}
