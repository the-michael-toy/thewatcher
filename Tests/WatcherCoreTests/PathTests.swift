import Testing
@testable import WatcherCore

struct PathTests {
    let router = IPv4("192.168.4.1")!

    @Test func homeWithMeshBehindISPRouter() {
        let hops: [IPv4?] = [IPv4("192.168.4.1"), IPv4("192.168.1.254"), IPv4("203.0.113.1"), IPv4("198.51.100.7"), nil, IPv4("1.1.1.1")]
        let stops = PathDiscovery.selectStops(router: router, hops: hops)
        #expect(stops.map(\.role) == [.router, .upstream, .isp, .internet])
        #expect(stops[1].address == IPv4("192.168.1.254"))
        #expect(stops[2].address == IPv4("203.0.113.1"))
    }

    @Test func cafeRouterStraightToISP() {
        let hops: [IPv4?] = [IPv4("192.168.4.1"), nil, IPv4("68.1.2.3"), IPv4("1.1.1.1")]
        let stops = PathDiscovery.selectStops(router: router, hops: hops)
        #expect(stops.map(\.role) == [.router, .isp, .internet])
    }

    @Test func nothingAnswersBeyondRouter() {
        let stops = PathDiscovery.selectStops(router: router, hops: [router, nil, nil])
        #expect(stops.map(\.role) == [.router, .internet])
    }

    @Test func privateHopAfterPublicIsNotUpstream() {
        let hops: [IPv4?] = ["192.168.4.1", "68.1.2.3", "10.9.9.9", "1.1.1.1"].map { IPv4($0) }
        #expect(PathDiscovery.selectStops(router: router, hops: hops).map(\.role) == [.router, .isp, .internet])
    }

    @Test func labelsFollowTheConnection() {
        let r = Stop(role: .router, address: router)
        #expect(r.label(connection: .wifi) == "Wi-Fi → router")
        #expect(r.label(connection: .ethernet) == "Ethernet → router")
        #expect(r.label(connection: .hotspot) == "Hotspot → phone")
    }
}
