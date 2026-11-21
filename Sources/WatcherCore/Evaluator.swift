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
    public var farBaseline: Baseline
    public var routerBaseline: Baseline
    /// The ongoing outage, or the most recent one.
    public var outage: Outage?

    public init(now: Date, connected: Bool = true, captive: Bool = false, connection: Connection = .wifi,
                stops: [Stop] = [], probes: [Probe] = [], traffic: [TrafficSample] = [],
                farBaseline: Baseline = Baseline(), routerBaseline: Baseline = Baseline(), outage: Outage? = nil) {
        self.now = now
        self.connected = connected
        self.captive = captive
        self.connection = connection
        self.stops = stops
        self.probes = probes
        self.traffic = traffic
        self.farBaseline = farBaseline
        self.routerBaseline = routerBaseline
        self.outage = outage
    }
}

public struct Assessment: Equatable, Sendable {
    public let light: Light
    public let headline: String
    public let detail: String?
    /// Ping once a second until things settle.
    public let wantsFastPace: Bool
}

/// Turns recent measurements into the dot's color and the sentence that
/// explains it. Only the far hosts set the color; the stops in between
/// explain where a problem starts.
public enum Evaluator {
    /// Consecutive lost internet pings that mean nothing is getting through.
    static let outageRun = 3
    /// How long a cleared problem keeps the dot yellow.
    static let memory: TimeInterval = 5 * 60
    /// How long after a lost ping to keep pinging once a second.
    static let fastPaceMemory: TimeInterval = 30

    public static func assess(_ s: Snapshot) -> Assessment {
        let far = s.probes.filter { $0.role == .internet }
        let link = s.connection == .hotspot ? "hotspot" : s.connection.rawValue
        let threshold = s.farBaseline.slowThresholdMs

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

        // Red: nothing gets through.
        let trailingLost = far.reversed().prefix { $0.lost }.count
        if trailingLost >= outageRun {
            let since = s.outage.flatMap { $0.end == nil ? $0.startMidpoint : nil }
                ?? far[far.count - trailingLost].time
            let down = "Down for \(Format.duration(s.now.timeIntervalSince(since)))."
            let (headline, detail) = locateOutage(s, link: link)
            return Assessment(light: .red, headline: headline, detail: "\(detail) \(down)", wantsFastPace: true)
        }

        // Orange: working, but badly, right now.
        let recentFar = Array(far.filter { s.now.timeIntervalSince($0.time) <= 180 }.suffix(20))
        let scattered = lossesOutsideOutages(recentFar)
        if scattered >= 2 {
            let oneIn = max(2, Int((Double(recentFar.count) / Double(scattered)).rounded()))
            let farRate = Double(scattered) / Double(recentFar.count)
            return Assessment(light: .orange, headline: "Losing about 1 in \(oneIn) pings to the internet.",
                              detail: locateLoss(s, since: recentFar[0].time, farRate: farRate, link: link),
                              wantsFastPace: true)
        }
        let recentOK = far.filter { !$0.lost && s.now.timeIntervalSince($0.time) <= 120 }.suffix(5).compactMap(\.ms)
        // Slowness measures fine at the normal pace; only loss needs timing to the second.
        if recentOK.count >= 3, let threshold, let current = median(recentOK), current > threshold {
            let usual = s.farBaseline.median.map { ", usually \(Format.ms($0))" } ?? ""
            return Assessment(light: .orange, headline: "The internet is slow: \(Format.ms(current))\(usual).",
                              detail: locateSlowness(s, link: link), wantsFastPace: false)
        }

        // Yellow: trouble that is unconfirmed or has cleared.
        if trailingLost > 0 {
            return Assessment(light: .yellow, headline: "A ping to the internet went missing. Checking…",
                              detail: nil, wantsFastPace: true)
        }
        if let blip = recentBlip(s, far: far, threshold: threshold, link: link) {
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

    static func locateOutage(_ s: Snapshot, link: String) -> (String, String) {
        if failing(s, .router) {
            return ("Can't reach your router.", "The problem is your \(link) connection.")
        }
        if failing(s, .upstream) {
            return ("Your router can't reach the upstream router.",
                    "Likely the cable between them or the ISP's box.")
        }
        if failing(s, .isp) {
            return ("Your ISP's line looks down.", "Your \(link) and router are fine.")
        }
        return ("Nothing beyond your ISP is answering.", "Your \(link), router and ISP's line look fine.")
    }

    /// The nearest stop losing pings at a comparable rate over the same stretch
    /// of time is where the loss starts.
    static func locateLoss(_ s: Snapshot, since: Date, farRate: Double, link: String) -> String {
        for stop in s.stops where stop.role != .internet {
            let window = s.probes.filter { $0.role == stop.role && $0.time >= since }
            let lost = window.filter(\.lost).count
            if window.count >= 3, lost > 0, Double(lost) / Double(window.count) >= farRate / 2 {
                switch stop.role {
                case .router: return "It starts at your \(link) connection."
                case .upstream: return "It starts between your router and the upstream router."
                case .isp: return "It starts at your ISP's line. Your \(link) and router look fine."
                case .internet: break
                }
            }
        }
        return "Your \(link) and router look fine."
    }

    static func locateSlowness(_ s: Snapshot, link: String) -> String {
        let routerOK = s.probes.filter { $0.role == .router && !$0.lost }.suffix(3).compactMap(\.ms)
        if routerOK.count >= 3, let m = median(routerOK), let slow = s.routerBaseline.slowThresholdMs, m > slow {
            return "Your \(link) link to the router is slow too, so it starts there."
        }
        return "Your \(link) and router look fine."
    }

    /// Fraction of a stop's last ten pings in the past minute that were lost;
    /// nil when there are too few to judge.
    static func lossRate(_ s: Snapshot, _ role: StopRole) -> Double? {
        let recent = s.probes.filter { $0.role == role && s.now.timeIntervalSince($0.time) <= 60 }.suffix(10)
        guard recent.count >= 3 else { return nil }
        return Double(recent.filter(\.lost).count) / Double(recent.count)
    }

    static func failing(_ s: Snapshot, _ role: StopRole) -> Bool {
        lossRate(s, role).map { $0 >= 0.5 } ?? false
    }

    /// Lost pings in short runs that have ended. A long run is an outage, and
    /// a run still going is unconfirmed: it ends as a blip or becomes an outage.
    static func lossesOutsideOutages(_ probes: [Probe]) -> Int {
        var total = 0, run = 0
        for p in probes {
            if p.lost { run += 1 } else {
                if run < outageRun { total += run }
                run = 0
            }
        }
        return total
    }

    struct Blip {
        let time: Date
        let what: String
        var wasLoss = true
    }

    /// The most significant trouble inside the yellow memory window.
    static func recentBlip(_ s: Snapshot, far: [Probe], threshold: Double?, link: String) -> Blip? {
        let window = { (t: Date) in s.now.timeIntervalSince(t) <= memory }
        if let o = s.outage, let end = o.end, window(end) {
            return Blip(time: end, what: "The connection was down for \(Format.duration(o.duration(asOf: end))).")
        }
        if let lost = far.last(where: { $0.lost && window($0.time) }) {
            return Blip(time: lost.time, what: "A few pings to the internet were lost.")
        }
        if let threshold, let spike = far.last(where: { ($0.ms ?? 0) > threshold && window($0.time) }) {
            return Blip(time: spike.time, what: "Latency spiked to \(Format.ms(spike.ms!)).", wasLoss: false)
        }
        if let lost = s.probes.last(where: { $0.role == .router && $0.lost && window($0.time) }) {
            return Blip(time: lost.time, what: "Your \(link) connection dropped a ping.")
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
