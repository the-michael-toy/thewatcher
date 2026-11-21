import Foundation

/// Every decision TheWatcher makes, as a pure state machine: events go in,
/// actions come out. `Monitor` performs the actions (pings, path discovery,
/// storage, notifications) and feeds the results back as events, so the
/// decisions run the same in tests as in the app. Time comes only from events.
public struct Watch: Sendable {
    public static let liveWindow: TimeInterval = 15 * 60
    /// The longest stretch of once-a-second pinging; after it, trouble is
    /// watched at the normal pace until it clears.
    static let fastPaceCap: TimeInterval = 3 * 60
    static let quietStopRediscovery: TimeInterval = 5 * 60
    static let captiveRecheck: TimeInterval = 30

    public private(set) var assessment = Assessment(light: .gray, headline: "Starting…", detail: nil, wantsFastPace: false)
    public private(set) var path: NetworkPath?
    public private(set) var place: Place?
    /// The live window of probes to every stop, oldest first.
    public private(set) var probes: [Probe] = []
    public private(set) var traffic: [TrafficSample] = []
    public private(set) var outage: Outage?
    public private(set) var farBaseline = Baseline()
    public private(set) var routerBaseline = Baseline()

    private var awake = true
    private var connected = false
    private var connection: Connection = .other
    private var captive = false
    private var pathSignature: String?
    private var lastSent: [StopRole: Date] = [:]
    private var fastSince: Date?
    private var fastSpent = false
    private var lastDiscovery = Date.distantPast
    private var lastCaptiveCheck = Date.distantPast
    private var minute: MinuteAccumulator?

    public init() {}

    public enum Event: Sendable {
        case tick(Date)
        case pathChanged(satisfied: Bool, connection: Connection, signature: String, at: Date)
        /// Discovery finished. `place`, and the latency seeds from its recent
        /// history, are nil and empty for a network that isn't kept.
        case discovered(NetworkPath?, place: Place?, farSeed: [Double], routerSeed: [Double], at: Date)
        /// A ping sent on `network` (its router fingerprint) came back or timed out.
        case probe(Probe, network: String?, at: Date)
        case traffic(TrafficSample)
        case captive(Bool, at: Date)
        case sleep(Date)
        case wake(Date)
        case placeKept(Place, at: Date)
        case placeRenamed(Place)
        case placeForgotten(Int64)
        /// Forget what's normal at this place; the next samples define it again.
        case relearn(Int64, at: Date)
    }

    public enum Action: Equatable, Sendable {
        case ping(Stop, sentAt: Date, network: String?)
        case discover(Connection)
        case checkCaptive
        case recordProbe(Probe, Place)
        case recordTraffic(TrafficSample, Place)
        case recordMinute(MinuteSummary, Place)
        case recordOutage(Outage, Place)
        case outageEnded(Outage)
        case lightChanged(Assessment)
    }

    public mutating func handle(_ event: Event) -> [Action] {
        var actions: [Action] = []
        switch event {
        case .tick(let now):
            guard awake else { return [] }
            rollMinute(now, &actions)
            trim(now)
            if connected, let path {
                pace(now)
                for stop in path.stops where due(stop.role, now) {
                    lastSent[stop.role] = now
                    actions.append(.ping(stop, sentAt: now, network: path.fingerprint))
                }
                if quietStopMoved(now) {
                    lastDiscovery = now
                    actions.append(.discover(path.connection))
                }
                if (assessment.light == .red || captive), now.timeIntervalSince(lastCaptiveCheck) > Self.captiveRecheck {
                    lastCaptiveCheck = now
                    actions.append(.checkCaptive)
                }
            }
            assess(now, &actions)

        case .pathChanged(let satisfied, let conn, let signature, let now):
            guard awake else { return [] }
            connected = satisfied
            connection = conn
            if signature != pathSignature {
                pathSignature = signature
                if satisfied {
                    lastDiscovery = now
                    actions.append(.discover(conn))
                } else {
                    leaveNetwork(now, &actions)
                }
            }
            assess(now, &actions)

        case .discovered(let found, let kept, let farSeed, let routerSeed, let now):
            guard awake else { return [] }
            let sameNetwork = found?.fingerprint != nil && found?.fingerprint == path?.fingerprint
            if !sameNetwork {
                leaveNetwork(now, &actions)
                place = kept
                farBaseline = Baseline(samples: farSeed)
                routerBaseline = Baseline(samples: routerSeed)
            }
            path = found
            captive = false
            assess(now, &actions)

        case .probe(let probe, let network, let now):
            guard awake, path != nil, network == path?.fingerprint else { return [] }
            let index = probes.lastIndex { $0.time <= probe.time }.map { $0 + 1 } ?? 0
            probes.insert(probe, at: index)
            if let place { actions.append(.recordProbe(probe, place)) }
            learn(probe)
            if probe.role == .internet { addToMinute(probe.time) { $0.add(probe) } }
            trim(now)
            assess(now, &actions)

        case .traffic(let sample):
            guard awake, connected, path != nil else { return [] }
            traffic.append(sample)
            addToMinute(sample.time) { $0.add(sample) }
            if sample.resentBytes > 0, let place { actions.append(.recordTraffic(sample, place)) }

        case .captive(let isCaptive, let now):
            captive = isCaptive
            assess(now, &actions)

        case .sleep(let now):
            // Time asleep is unwatched, never counted as up or down.
            leaveNetwork(now, &actions)
            connected = false
            pathSignature = nil
            assess(now, &actions)
            awake = false

        case .wake(let now):
            awake = true
            assess(now, &actions)

        case .placeKept(let kept, let now):
            if kept.fingerprint == path?.fingerprint { place = kept }
            assess(now, &actions)

        case .placeRenamed(let renamed):
            if place?.id == renamed.id { place = renamed }

        case .placeForgotten(let id):
            if place?.id == id { place = nil }

        case .relearn(let id, let now):
            if place?.id == id {
                farBaseline = Baseline()
                routerBaseline = Baseline()
            }
            assess(now, &actions)
        }
        return actions
    }

    // MARK: - Pacing

    /// Once-a-second pinging runs while there is loss to time, up to the cap.
    private mutating func pace(_ now: Date) {
        if assessment.wantsFastPace {
            if fastSince == nil { fastSince = now }
            if let since = fastSince, now.timeIntervalSince(since) >= Self.fastPaceCap { fastSpent = true }
        } else {
            fastSince = nil
            fastSpent = false
        }
    }

    private var isFast: Bool { assessment.wantsFastPace && !fastSpent }

    private func due(_ role: StopRole, _ now: Date) -> Bool {
        let interval: TimeInterval = isFast ? 1 : (role == .isp ? 30 : 10)
        guard let last = lastSent[role] else { return true }
        return now.timeIntervalSince(last) >= interval - 0.05
    }

    /// A middle stop going silent while the internet still answers means the
    /// route moved, not that something broke.
    private func quietStopMoved(_ now: Date) -> Bool {
        guard now.timeIntervalSince(lastDiscovery) > Self.quietStopRediscovery, let path else { return false }
        let far = probes.filter { $0.role == .internet }.suffix(5)
        guard far.count == 5, far.allSatisfy({ !$0.lost }) else { return false }
        return path.stops.contains { stop in
            guard stop.role == .upstream || stop.role == .isp else { return false }
            let recent = probes.filter { $0.role == stop.role }.suffix(5)
            return recent.count == 5 && recent.allSatisfy(\.lost)
        }
    }

    // MARK: - Learning what's normal

    /// A new place learns its first samples whatever they are, so a link that
    /// is always slow becomes its own normal. After that, latency measured
    /// during trouble is kept out of what counts as normal.
    private mutating func learn(_ probe: Probe) {
        guard let ms = probe.ms else { return }
        switch probe.role {
        case .internet where !farBaseline.isLearned || assessment.light < .orange:
            farBaseline.add(ms)
        case .router where !routerBaseline.isLearned || assessment.light < .orange:
            routerBaseline.add(ms)
        default:
            break
        }
    }

    // MARK: - Assessment and outages

    private mutating func assess(_ now: Date, _ actions: inout [Action]) {
        let next = Evaluator.assess(Snapshot(
            now: now, connected: connected && awake, captive: captive,
            connection: path?.connection ?? connection, stops: path?.stops ?? [],
            probes: probes, traffic: traffic, farBaseline: farBaseline, routerBaseline: routerBaseline,
            outage: outage))
        trackOutage(next.light, now, &actions)
        if let m = minute, next.light > m.worstLight { minute?.worstLight = next.light }
        if next.light != assessment.light { actions.append(.lightChanged(next)) }
        assessment = next
    }

    private mutating func trackOutage(_ light: Light, _ now: Date, _ actions: inout [Action]) {
        let ongoing = outage.map { $0.end == nil } ?? false
        if light == .red && !ongoing {
            let far = probes.filter { $0.role == .internet }
            guard let firstLost = far.reversed().prefix(while: \.lost).last else { return }
            let lastGood = far.last { !$0.lost }?.time ?? firstLost.time.addingTimeInterval(-10)
            outage = Outage(startEarliest: lastGood, startLatest: firstLost.time).narrowed(by: traffic)
        } else if ongoing && light != .red && light != .gray {
            let back = probes.last { $0.role == .internet && !$0.lost }?.time ?? now
            closeOutage(at: back, notify: true, &actions)
        }
    }

    private mutating func closeOutage(at end: Date, notify: Bool, _ actions: inout [Action]) {
        guard var o = outage, o.end == nil else { return }
        o.end = max(end, o.startLatest)
        outage = o
        if let place { actions.append(.recordOutage(o, place)) }
        if notify { actions.append(.outageEnded(o)) }
    }

    /// Everything measured on a network says nothing about the next one.
    private mutating func leaveNetwork(_ now: Date, _ actions: inout [Action]) {
        closeOutage(at: now, notify: false, &actions)
        flushMinute(&actions)
        outage = nil
        path = nil
        place = nil
        probes = []
        traffic = []
        farBaseline = Baseline()
        routerBaseline = Baseline()
        lastSent = [:]
        fastSince = nil
        fastSpent = false
        captive = false
    }

    // MARK: - Bookkeeping

    private mutating func trim(_ now: Date) {
        let cutoff = now.addingTimeInterval(-Self.liveWindow)
        if let first = probes.firstIndex(where: { $0.time >= cutoff }), first > 0 { probes.removeFirst(first) }
        if let first = traffic.firstIndex(where: { $0.time >= cutoff }), first > 0 { traffic.removeFirst(first) }
    }

    private mutating func addToMinute(_ time: Date, _ add: (inout MinuteAccumulator) -> Void) {
        var m = minute ?? MinuteAccumulator(minute: MinuteAccumulator.index(time))
        add(&m)
        minute = m
    }

    private mutating func rollMinute(_ now: Date, _ actions: inout [Action]) {
        if let m = minute, m.minute != MinuteAccumulator.index(now) { flushMinute(&actions) }
    }

    private mutating func flushMinute(_ actions: inout [Action]) {
        if let summary = minute?.summary(), let place { actions.append(.recordMinute(summary, place)) }
        minute = nil
    }
}

extension Outage {
    /// Uses the Mac's own traffic to tighten when the outage began: data still
    /// arriving proves the connection worked; resends with nothing arriving
    /// prove it didn't.
    func narrowed(by traffic: [TrafficSample]) -> Outage {
        var o = self
        if let lastFlow = traffic.last(where: { $0.rxBytes > 0 && $0.time > o.startEarliest && $0.time < o.startLatest }) {
            o.startEarliest = lastFlow.time
        }
        if let firstStall = traffic.first(where: { $0.resentBytes > 0 && $0.rxBytes == 0 && $0.time > o.startEarliest && $0.time < o.startLatest }) {
            o.startLatest = firstStall.time
        }
        return o
    }
}

/// Collects one minute of measurements for the history.
struct MinuteAccumulator: Sendable {
    let minute: Int64
    var sent = 0
    var lost = 0
    var latencies: [Double] = []
    var resentBytes: UInt64 = 0
    var worstLight: Light = .gray

    static func index(_ time: Date) -> Int64 { Int64((time.timeIntervalSince1970 / 60).rounded(.down)) }

    init(minute: Int64) { self.minute = minute }

    mutating func add(_ p: Probe) {
        sent += 1
        if let ms = p.ms { latencies.append(ms) } else { lost += 1 }
    }

    mutating func add(_ t: TrafficSample) { resentBytes += t.resentBytes }

    func summary() -> MinuteSummary? {
        guard sent > 0 else { return nil }
        let sorted = latencies.sorted()
        return MinuteSummary(minute: minute, farSent: sent, farLost: lost,
                             farMedianMs: sorted.isEmpty ? nil : sorted[sorted.count / 2],
                             farMaxMs: sorted.last, resentBytes: Int(resentBytes), worstLight: worstLight)
    }
}
