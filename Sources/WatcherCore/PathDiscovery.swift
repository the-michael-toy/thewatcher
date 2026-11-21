import CNetStat
import Darwin
import Foundation
import SystemConfiguration

public enum PathDiscovery {
    /// The far hosts. TheWatcher alternates between them and treats the
    /// internet as down only when both stop answering.
    public static let farHosts: [IPv4] = [IPv4("1.1.1.1")!, IPv4("8.8.8.8")!]

    /// The Mac's current IPv4 router and the interface that reaches it.
    public static func currentRouter() -> (router: IPv4, interface: String)? {
        guard let store = SCDynamicStoreCreate(nil, "TheWatcher" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let routerText = value["Router"] as? String,
              let router = IPv4(routerText),
              let interface = value["PrimaryInterface"] as? String
        else { return nil }
        return (router, interface)
    }

    public static func hardwareAddress(of address: IPv4) -> String? {
        var mac = [UInt8](repeating: 0, count: 6)
        let addr = in_addr(s_addr: address.value.bigEndian)
        let rc = mac.withUnsafeMutableBufferPointer { cn_arp_lookup(addr, $0.baseAddress) }
        guard rc == 0 else { return nil }
        return mac.map { String(format: "%02x", $0) }.joined(separator: ":")
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
        guard let (router, interface) = currentRouter() else { return nil }
        var fingerprint = hardwareAddress(of: router)
        if fingerprint == nil, let pinger = try? Pinger() {
            // An ARP entry exists only after recent traffic to the router.
            _ = await pinger.ping(router, timeout: 1)
            fingerprint = hardwareAddress(of: router)
        }
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
