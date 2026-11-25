import Darwin
import Foundation
import SystemConfiguration

public enum PathDiscovery {
    /// The far hosts. TheWatcher alternates between them and treats the
    /// internet as down only when both stop answering.
    public static let farHosts: [IPv4] = [IPv4("1.1.1.1")!, IPv4("8.8.8.8")!]

    /// The Mac's current IPv4 router, the interface that reaches it, and the
    /// router's hardware address. The address comes from the system's record
    /// of the primary service, because macOS hides the ARP table from apps.
    public static func currentRouter() -> (router: IPv4, interface: String, hardwareAddress: String?)? {
        guard let store = SCDynamicStoreCreate(nil, "TheWatcher" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let routerText = global["Router"] as? String,
              let router = IPv4(routerText),
              let interface = global["PrimaryInterface"] as? String
        else { return nil }
        var hardwareAddress: String?
        if let service = global["PrimaryService"] as? String,
           let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
           (ipv4["ARPResolvedIPAddress"] as? String).flatMap(IPv4.init) == router,
           let text = ipv4["ARPResolvedHardwareAddress"] as? String {
            hardwareAddress = normalizedHardwareAddress(text)
        }
        return (router, interface, hardwareAddress)
    }

    /// Six lowercase two-digit hex octets joined by colons, the form places
    /// are stored under; nil for anything else.
    static func normalizedHardwareAddress(_ text: String) -> String? {
        let octets = text.split(separator: ":", omittingEmptySubsequences: false).map { UInt8($0, radix: 16) }
        guard octets.count == 6, !octets.contains(nil) else { return nil }
        return octets.map { String(format: "%02x", $0!) }.joined(separator: ":")
    }

    /// Hop-by-hop route toward `destination`, one entry per hop limit; nil
    /// where nothing answered.
    public static func trace(to destination: IPv4, maxHops: Int = 12) async -> [IPv4?] {
        guard let pinger = try? Pinger() else { return [] }
        var hops: [IPv4?] = []
        for ttl in 1...maxHops {
            var responder: IPv4?
            var reached = false
            for _ in 0..<2 where responder == nil {
                switch await pinger.ping(destination, ttl: Int32(ttl), timeout: 1.5) {
                case .timeExceeded(_, let from): responder = from
                case .reply(_, let from): responder = from; reached = true
                case .unreachable(let from): responder = from; reached = true
                case .timeout, .sendFailed: break
                }
            }
            hops.append(responder)
            if reached { break }
        }
        return hops
    }

    /// Picks the stops worth watching from a traced route: the router, the
    /// first private router behind it (in a home, usually the ISP's box), the
    /// first public hop (the ISP's side of the line), and the internet.
    public static func selectStops(router: IPv4, hops: [IPv4?]) -> [Stop] {
        var stops = [Stop(role: .router, address: router)]
        let beyondRouter = hops.dropFirst().compactMap { $0 }.filter { $0 != router && !farHosts.contains($0) }
        let firstPublic = beyondRouter.firstIndex { !$0.isPrivate }
        if let upstream = beyondRouter[..<(firstPublic ?? beyondRouter.endIndex)].first {
            stops.append(Stop(role: .upstream, address: upstream))
        }
        if let firstPublic {
            stops.append(Stop(role: .isp, address: beyondRouter[firstPublic]))
        }
        stops.append(Stop(role: .internet, address: nil))
        return stops
    }

    public static func discover(connection: Connection) async -> NetworkPath? {
        guard let (router, interface, fingerprint) = currentRouter() else { return nil }
        let hops = await trace(to: farHosts[0])
        return NetworkPath(
            connection: connection,
            interface: interface,
            router: router,
            fingerprint: fingerprint,
            stops: selectStops(router: router, hops: hops)
        )
    }
}
