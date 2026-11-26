import Foundation

/// The kinds of stop between this Mac and the internet, in path order.
public enum StopRole: Int, CaseIterable, Codable, Sendable, Comparable {
    case router = 0
    case upstream = 1
    case isp = 2
    case internet = 3

    public static func < (l: StopRole, r: StopRole) -> Bool { l.rawValue < r.rawValue }
}

public enum Connection: String, Sendable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case hotspot = "Hotspot"
    case other = "Network"
}

public struct Stop: Hashable, Sendable, Identifiable {
    public let role: StopRole
    /// Nil for the internet stop, which is answered by any of the far hosts.
    public let address: IPv4?
    public var id: StopRole { role }

    public init(role: StopRole, address: IPv4?) {
        self.role = role
        self.address = address
    }

    public func label(connection: Connection) -> String {
        switch role {
        case .router: connection == .hotspot ? "Hotspot → phone" : "\(connection.rawValue) → router"
        case .upstream: "Upstream router"
        case .isp: "ISP"
        case .internet: "Internet"
        }
    }
}

/// The route TheWatcher watches for the network the Mac is on right now.
public struct NetworkPath: Equatable, Sendable {
    public let connection: Connection
    public let interface: String
    public let router: IPv4
    /// The router's hardware address: stable across mesh nodes, unique to one network.
    public let fingerprint: String?
    public let stops: [Stop]

    public init(connection: Connection, interface: String, router: IPv4, fingerprint: String?, stops: [Stop]) {
        self.connection = connection
        self.interface = interface
        self.router = router
        self.fingerprint = fingerprint
        self.stops = stops
    }
}

/// One ping to one stop. `ms` is nil when the ping was lost.
public struct Probe: Equatable, Sendable {
    public let time: Date
    public let role: StopRole
    public let ms: Double?

    public init(time: Date, role: StopRole, ms: Double?) {
        self.time = time
        self.role = role
        self.ms = ms
    }

    public var lost: Bool { ms == nil }
}

/// One second of this Mac's own TCP traffic, from the kernel's connection statistics.
public struct TrafficSample: Equatable, Sendable {
    public let time: Date
    public let txPackets: UInt64
    public let rxBytes: UInt64
    public let resentBytes: UInt64
    public let resendingConnections: Int

    public init(time: Date, txPackets: UInt64, rxBytes: UInt64, resentBytes: UInt64, resendingConnections: Int) {
        self.time = time
        self.txPackets = txPackets
        self.rxBytes = rxBytes
        self.resentBytes = resentBytes
        self.resendingConnections = resendingConnections
    }

    /// About ten full-size packets: a stray resend or two is routine.
    static let burstBytes: UInt64 = 15_000

    /// Several connections resending at once means the network, not one slow server.
    public var isResendBurst: Bool { resendingConnections >= 3 && resentBytes >= Self.burstBytes }
}

/// The dot. Ordered by urgency.
public enum Light: Int, Comparable, Sendable, Codable {
    /// Not connected, or waiting for a network login page.
    case gray = 0
    case green = 1
    /// Trouble in the last few minutes that has since cleared, or is not yet confirmed.
    case yellow = 2
    /// Slow or losing pings right now.
    case orange = 3
    /// Significant problems between this Mac and the internet right now.
    case red = 4

    public static func < (l: Light, r: Light) -> Bool { l.rawValue < r.rawValue }
}

/// A stretch of significant problems (a red dot), whose start is known only
/// to within a range: between the last probe before the trouble and the
/// first probe that showed it.
public struct Outage: Equatable, Sendable {
    public var startEarliest: Date
    public var startLatest: Date
    public var end: Date?

    public init(startEarliest: Date, startLatest: Date, end: Date? = nil) {
        self.startEarliest = startEarliest
        self.startLatest = startLatest
        self.end = end
    }

    public var startMidpoint: Date {
        startEarliest.addingTimeInterval(startLatest.timeIntervalSince(startEarliest) / 2)
    }

    public func duration(asOf now: Date) -> TimeInterval {
        (end ?? now).timeIntervalSince(startMidpoint)
    }
}
