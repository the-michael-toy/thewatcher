import Foundation

/// Everything the evaluator looks at, captured at one moment.
public struct Snapshot: Sendable {
    public var now: Date
    public var connected: Bool
    public var captive: Bool
    public var connection: Connection
    public var stops: [Stop]
    /// Recent probes to every stop, oldest first.
    public var probes: [Probe]
    /// Recent seconds of this Mac's own traffic, oldest first.
    public var traffic: [TrafficSample]
    public var baselines: [StopRole: Baseline]
    /// The ongoing outage, or the most recent one.
    public var outage: Outage?

    public init(now: Date, connected: Bool = true, captive: Bool = false, connection: Connection = .wifi,
                stops: [Stop] = [], probes: [Probe] = [], traffic: [TrafficSample] = [],
                baselines: [StopRole: Baseline] = [:], outage: Outage? = nil) {
        self.now = now
        self.connected = connected
        self.captive = captive
        self.connection = connection
        self.stops = stops
        self.probes = probes
        self.traffic = traffic
        self.baselines = baselines
        self.outage = outage
    }

    func baseline(_ role: StopRole) -> Baseline { baselines[role] ?? Baseline() }
}

public struct Assessment: Equatable, Sendable {
    public let light: Light
    public let headline: String
    public let detail: String?
    /// Ping once a second until things settle.
    public let wantsFastPace: Bool
    /// For red: the first probe that showed the trouble.
    public var troubleStarted: Date? = nil
}

/// Turns recent measurements into the dot's color and the sentence that
/// explains it. Only the far hosts set the color. Every symptom is then placed
/// by the same rule: the nearest stop showing it beyond its own normal.
public enum Evaluator {
    /// Consecutive lost internet pings that mean nothing is getting through.
    static let outageRun = 3
    /// Every symptom is judged over the same recent stretch of internet pings.
    static let windowPings = 20
    static let windowSpan: TimeInterval = 180
    /// Losing this share of recent internet pings is a significant problem.
    static let redLossShare = 0.25
    /// How long a cleared problem keeps the dot yellow.
    static let memory: TimeInterval = 5 * 60
    /// How long after a lost ping to keep pinging once a second.
    static let fastPaceMemory: TimeInterval = 30
    /// This many answered internet pings in a row mean the loss has stopped.
    static let lossClearsAfter = 5
    /// Latency is judged on the last few answered pings within this span.
    static let latencySpan: TimeInterval = 120

    public static func assess(_ s: Snapshot) -> Assessment {
        let far = s.probes.filter { $0.role == .internet }
        let link = s.connection == .hotspot ? "hotspot" : s.connection.rawValue

        guard s.connected else {
            return Assessment(light: .gray, headline: "Not connected to a network.", detail: nil, wantsFastPace: false)
        }
        if s.captive {
            return Assessment(light: .gray, headline: "Waiting for network login.",
                              detail: "Open a browser to sign in to this network.", wantsFastPace: false)
        }
        guard !far.isEmpty else {
            return Assessment(light: .gray, headline: "Checking the connection…", detail: nil, wantsFastPace: true)
        }

        let window = Array(far.filter { s.now.timeIntervalSince($0.time) <= windowSpan }.suffix(windowPings))
        let windowStart = window.first?.time ?? s.now
        let trailingLost = far.reversed().prefix { $0.lost }.count

        // Nothing gets through.
        if trailingLost >= outageRun {
            let failingSince = far[far.count - trailingLost].time
            let place = locateLoss(s, since: failingSince)
            let started = lossRuns(window) > 1 ? window.first(where: \.lost)?.time ?? failingSince : failingSince
            let detail = "\(whereDetail(place, s, link: link)) Nothing has answered for \(Format.duration(s.now.timeIntervalSince(failingSince)))."
            return Assessment(light: .red, headline: downHeadline(place, s), detail: detail, wantsFastPace: true,
                              troubleStarted: started)
        }

        // Losing pings: more than one run of loss, and still happening. A
        // single run that has ended is a blip.
        var losing: Assessment?
        let trailingAnswered = far.reversed().prefix { !$0.lost }.count
        if lossRuns(window) > 1 && trailingAnswered < lossClearsAfter {
            let share = Double(window.filter(\.lost).count) / Double(window.count)
            let place = locateLoss(s, since: windowStart)
            let pings = s.probes.filter { $0.role == place && $0.time >= windowStart }
            let headline = "\(subject(place, s)) is losing \(pings.filter(\.lost).count) of the last \(pings.count) pings."
            let red = share >= redLossShare
            losing = Assessment(light: red ? .red : .orange, headline: headline,
                                detail: whereDetail(place, s, link: link), wantsFastPace: true,
                                troubleStarted: red ? window.first(where: \.lost)?.time : nil)
        }

        // Slow. Slowness alone measures fine at the normal pace; only loss needs timing to the second.
        var slow: Assessment?
        let farBaseline = s.baseline(.internet)
        let answered = recentAnswered(.internet, s)
        if answered.count >= 3, let threshold = farBaseline.slowThresholdMs,
           let current = median(answered.compactMap(\.ms)), current > threshold {
            let red = current > (farBaseline.verySlowThresholdMs ?? .infinity)
            let place = locateSlowness(s)
            let ms = place == .internet ? current : median(recentAnswered(place, s).suffix(3).compactMap(\.ms)) ?? current
            let usual = s.baseline(place).median.map { ", usually \(Format.ms($0))" } ?? ""
            let firstSlow = answered.first { ($0.ms ?? 0) > threshold }?.time
            slow = Assessment(light: red ? .red : .orange, headline: "\(subject(place, s)) is slow: \(Format.ms(ms))\(usual).",
                              detail: whereDetail(place, s, link: link), wantsFastPace: losing != nil,
                              troubleStarted: red ? firstSlow : nil)
        }

        // Whichever is worse speaks; loss wins a tie.
        if let losing, losing.light >= (slow?.light ?? .gray) { return losing }
        if let slow { return slow }

        // Yellow: trouble that is unconfirmed or has cleared.
        if trailingLost > 0 {
            return Assessment(light: .yellow, headline: "A ping to the internet went missing. Checking…",
                              detail: nil, wantsFastPace: true)
        }
        if let blip = recentBlip(s, far: far, threshold: farBaseline.slowThresholdMs) {
            let fast = blip.wasLoss && s.now.timeIntervalSince(blip.time) <= fastPaceMemory
            return Assessment(light: .yellow,
                              headline: "There was a blip \(Format.ago(s.now.timeIntervalSince(blip.time))); it looks fine now.",
                              detail: blip.what, wantsFastPace: fast)
        }

        let now = median(Array(far.compactMap(\.ms).suffix(5))) ?? 0
        return Assessment(light: .green, headline: "All good: \(Format.ms(now)) to the internet.",
                          detail: nil, wantsFastPace: false)
    }

    // MARK: - Where is it?

    /// The nearest stop whose loss beyond its usual loss is at least half the
    /// internet's loss, over the same stretch of time.
    static func locateLoss(_ s: Snapshot, since: Date) -> StopRole {
        func share(_ role: StopRole) -> Double? {
            let pings = s.probes.filter { $0.role == role && $0.time >= since }
            guard pings.count >= 2 else { return nil }
            return Double(pings.filter(\.lost).count) / Double(pings.count)
        }
        let farShare = share(.internet) ?? 0
        for stop in s.stops where stop.role != .internet {
            if let e = share(stop.role).map({ $0 - s.baseline(stop.role).usualLoss }), e > 0, e >= farShare / 2 {
                return stop.role
            }
        }
        return .internet
    }

    /// The nearest stop that is slow compared with its own normal.
    static func locateSlowness(_ s: Snapshot) -> StopRole {
        for stop in s.stops where stop.role != .internet {
            let recent = recentAnswered(stop.role, s).suffix(3).compactMap(\.ms)
            if recent.count >= 3, let slow = s.baseline(stop.role).slowThresholdMs, let m = median(recent), m > slow {
                return stop.role
            }
        }
        return .internet
    }

    static func recentAnswered(_ role: StopRole, _ s: Snapshot) -> [Probe] {
        Array(s.probes.filter { $0.role == role && !$0.lost && s.now.timeIntervalSince($0.time) <= latencySpan }.suffix(5))
    }

    // MARK: - Wording

    /// Numbers in a headline describe the place it names.
    static func subject(_ role: StopRole, _ s: Snapshot) -> String {
        switch role {
        case .router: s.connection == .hotspot ? "Your connection to the phone" : "Your connection to the router"
        case .upstream: "The link to the upstream router"
        case .isp: "Your ISP's line"
        case .internet: "The internet"
        }
    }

    static func downHeadline(_ role: StopRole, _ s: Snapshot) -> String {
        switch role {
        case .router: s.connection == .hotspot ? "Can't reach your phone." : "Can't reach your router."
        case .upstream: "Your router can't reach the upstream router."
        case .isp: "Your ISP's line looks down."
        case .internet: s.stops.contains { $0.role == .isp } ? "Nothing beyond your ISP is answering." : "The internet isn't answering."
        }
    }

    static func whereDetail(_ role: StopRole, _ s: Snapshot, link: String) -> String {
        switch role {
        case .router:
            // A silent or slow router can't tell the Mac's own link from the
            // router or, in a mesh, the node relaying for it.
            "Either your \(link) connection or the router itself. In a mesh, that includes the node this Mac connects through."
        case .upstream:
            "Your \(link) and router are fine. Likely the cable to the upstream router, or the router itself."
        case .isp:
            "Your \(link) and router are fine."
        case .internet:
            s.stops.contains { $0.role == .isp } ? "Your \(link), router and ISP's line look fine." : "Your \(link) and router look fine."
        }
    }

    static func lossRuns(_ probes: [Probe]) -> Int {
        zip([Probe?.none] + probes.map(Optional.some), probes).filter { prev, p in p.lost && !(prev?.lost ?? false) }.count
    }

    struct Blip {
        let time: Date
        let what: String
        var wasLoss = true
    }

    /// The most significant trouble inside the yellow memory window.
    static func recentBlip(_ s: Snapshot, far: [Probe], threshold: Double?) -> Blip? {
        let window = { (t: Date) in s.now.timeIntervalSince(t) <= memory }
        if let o = s.outage, let end = o.end, window(end) {
            return Blip(time: end, what: "Trouble lasted \(Format.duration(o.duration(asOf: end))).")
        }
        if let lost = far.last(where: { $0.lost && window($0.time) }) {
            return Blip(time: lost.time, what: "A few pings to the internet were lost.")
        }
        if let threshold, let spike = far.last(where: { ($0.ms ?? 0) > threshold && window($0.time) }) {
            return Blip(time: spike.time, what: "Latency spiked to \(Format.ms(spike.ms!)).", wasLoss: false)
        }
        if let lost = s.probes.last(where: { $0.role == .router && $0.lost && window($0.time) }) {
            return Blip(time: lost.time, what: "A ping to your router was lost.")
        }
        if let burst = s.traffic.last(where: { $0.isResendBurst && window($0.time) }) {
            return Blip(time: burst.time, what: "Your apps had to resend data on several connections at once.")
        }
        return nil
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

public enum Format {
    public static func ms(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : "\(Int(value.rounded())) ms"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    public static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 15 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        let m = Int(seconds / 60)
        return m == 1 ? "a minute ago" : "\(m) minutes ago"
    }
}
