import Foundation
import Testing
@testable import WatcherCore

struct EvaluatorTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let stops = [Stop(role: .router, address: IPv4("192.168.4.1")), Stop(role: .upstream, address: IPv4("192.168.1.254")),
                 Stop(role: .isp, address: IPv4("203.0.113.1")), Stop(role: .internet, address: nil)]
    let fiber = Baseline(samples: (0..<100).map { 15 + Double($0 % 5) })

    /// Probes to `role`, one per `every` seconds, ending at `now`; `ms` nil = lost.
    func series(_ role: StopRole, _ ms: [Double?], every: TimeInterval = 1) -> [Probe] {
        ms.enumerated().map { i, v in Probe(time: now.addingTimeInterval(-Double(ms.count - 1 - i) * every), role: role, ms: v) }
    }

    func snapshot(_ probes: [Probe], baseline: Baseline? = nil, traffic: [TrafficSample] = [], outage: Outage? = nil,
                  baselines: [StopRole: Baseline] = [:]) -> Snapshot {
        let usual: [StopRole: Baseline] = [.internet: baseline ?? fiber, .router: Baseline(samples: Array(repeating: 3, count: 50))]
        return Snapshot(now: now, stops: stops, probes: probes.sorted { $0.time < $1.time }, traffic: traffic,
                        baselines: usual.merging(baselines) { $1 }, outage: outage)
    }

    @Test func steadyIsGreen() {
        let a = Evaluator.assess(snapshot(series(.internet, Array(repeating: 17, count: 30), every: 10)))
        #expect(a.light == .green)
        #expect(a.headline == "All good: 17 ms to the internet.")
        #expect(!a.wantsFastPace)
    }

    @Test func notConnectedIsGray() {
        var s = snapshot([])
        s.connected = false
        #expect(Evaluator.assess(s).light == .gray)
    }

    @Test func oneMissingPingIsYellowAndSpeedsUp() {
        let a = Evaluator.assess(snapshot(series(.internet, Array(repeating: 17, count: 10) + [nil], every: 10)))
        #expect(a.light == .yellow)
        #expect(a.wantsFastPace)
    }

    @Test func twoMissingPingsAreStillUnconfirmed() {
        let a = Evaluator.assess(snapshot(series(.internet, Array(repeating: 17, count: 10) + [nil, nil])))
        #expect(a.light == .yellow)
    }

    @Test func threeInARowIsRedAndLocatedAtISP() {
        let probes = series(.internet, [17, 17, 17, nil, nil, nil])
            + series(.router, [3, 3, 3, 3, 3, 3])
            + series(.upstream, [5, 5, 5, 5, 5, 5])
            + series(.isp, [9, 9, 9, nil, nil, nil])
        let a = Evaluator.assess(snapshot(probes))
        #expect(a.light == .red)
        #expect(a.headline == "Your ISP's line looks down.")
        #expect(a.detail?.contains("Wi-Fi and router are fine") == true)
    }

    @Test func redLocatedAtRouter() {
        let probes = series(.internet, [nil, nil, nil, nil]) + series(.router, [nil, nil, nil, nil])
        #expect(Evaluator.assess(snapshot(probes)).headline == "Can't reach your router.")
    }

    @Test func goodPingsBeforeTheOutageDoNotHideTheRouter() {
        let before: [Double?] = Array(repeating: 3, count: 7)
        let probes = series(.internet, Array(repeating: 17, count: 7) + [nil, nil, nil])
            + series(.router, before + [nil, nil, nil])
            + series(.upstream, before + [nil, nil, nil])
            + series(.isp, before + [nil, nil, nil])
        #expect(Evaluator.assess(snapshot(probes)).headline == "Can't reach your router.")
    }

    @Test func unreachableRouterDoesNotBlameWiFiAlone() {
        let probes = series(.internet, [nil, nil, nil, nil]) + series(.router, [nil, nil, nil, nil])
        let detail = Evaluator.assess(snapshot(probes)).detail ?? ""
        #expect(detail.contains("Wi-Fi"))
        #expect(detail.contains("router itself"))
    }

    @Test func pingsComingBackEndRedAtOnce() {
        let probes = series(.internet, [17, nil, nil, nil, nil, 17])
        let outage = Outage(startEarliest: now.addingTimeInterval(-5), startLatest: now.addingTimeInterval(-4), end: now)
        let a = Evaluator.assess(snapshot(probes, outage: outage))
        #expect(a.light == .yellow)
        #expect(a.detail?.hasPrefix("Trouble lasted") == true)
    }

    @Test func scatteredLossIsOrange() {
        let ms: [Double?] = [17, nil, 17, 17, 17, nil, 17, 17, 17, 17, 17, nil, 17, 17, 17, 17]
        let a = Evaluator.assess(snapshot(series(.internet, ms) + series(.isp, ms.map { $0.map { _ in 9 } })))
        #expect(a.light == .orange)
        #expect(a.headline == "Your ISP's line is losing 3 of the last 16 pings.")
    }

    /// Heavy loss comes in runs of several pings; every lost ping counts.
    @Test func heavyLossInRunsIsRedWithTheRealCount() {
        let ms: [Double?] = [17, nil, 17, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 17, nil, 17, 17]
        let probes = series(.internet, ms) + series(.router, ms.map { $0.map { _ in 3 } })
        let a = Evaluator.assess(snapshot(probes))
        #expect(a.light == .red)
        #expect(a.headline == "Your connection to the router is losing 15 of the last 20 pings.")
        #expect(a.detail?.contains("mesh") == true)
    }

    @Test func aStopsUsualLossIsNotBlamed() {
        let far: [Double?] = [17, nil, 17, 17, 17, nil, 17, 17, 17, 17, nil, 17, 17, 17, 17, 17, nil, 17, 17, 17]
        let isp: [Double?] = [9, 9, 9, nil, 9, 9, 9]
        let dropsPingsWhenBusy = Baseline(pings: (0..<100).map { $0 % 10 == 0 ? nil : 9 })
        let a = Evaluator.assess(snapshot(series(.internet, far) + series(.isp, isp, every: 3),
                                          baselines: [.isp: dropsPingsWhenBusy]))
        #expect(a.headline == "The internet is losing 4 of the last 20 pings.")
    }

    @Test func sustainedSlownessIsOrange() {
        let a = Evaluator.assess(snapshot(series(.internet, Array(repeating: 17, count: 20) + [120, 130, 115, 140, 125])))
        #expect(a.light == .orange)
        #expect(a.headline == "The internet is slow: 125 ms, usually 17 ms.")
    }

    @Test func tenTimesUsualLatencyIsRed() {
        let a = Evaluator.assess(snapshot(series(.internet, Array(repeating: 17, count: 20) + [420, 600, 410, 430, 426])))
        #expect(a.light == .red)
    }

    @Test func severeSlownessIsNotHiddenByMildLoss() {
        let ms: [Double?] = Array(repeating: 17, count: 12) + [nil, 420, 600, nil, 410, 430, 426, 415]
        let a = Evaluator.assess(snapshot(series(.internet, ms)))
        #expect(a.light == .red)
        #expect(a.headline.hasPrefix("The internet is slow"))
        #expect(a.wantsFastPace)
    }

    @Test func slownessIsPlacedAtTheNearestStopSlowForItself() {
        let probes = series(.internet, Array(repeating: 17, count: 20) + [210, 220, 205, 215, 212])
            + series(.router, Array(repeating: 3, count: 25))
            + series(.upstream, Array(repeating: 5, count: 25))
            + series(.isp, Array(repeating: 9, count: 20) + [200, 205, 199, 210, 204])
        let a = Evaluator.assess(snapshot(probes, baselines: [.upstream: Baseline(samples: Array(repeating: 5, count: 50)),
                                                              .isp: Baseline(samples: Array(repeating: 9, count: 50))]))
        #expect(a.headline == "Your ISP's line is slow: 204 ms, usually 9.0 ms.")
    }

    @Test func satelliteSwingIsNormalThere() {
        let satellite = Baseline(samples: (0..<200).map { 40 + Double($0 % 40) })
        let a = Evaluator.assess(snapshot(series(.internet, [55, 70, 78, 62, 75]), baseline: satellite))
        #expect(a.light == .green)
    }

    @Test func singleSpikeIsYellowNotOrange() {
        let a = Evaluator.assess(snapshot(series(.internet, Array(repeating: 17, count: 10) + [400] + Array(repeating: 17, count: 5))))
        #expect(a.light == .yellow)
        #expect(a.detail == "Latency spiked to 400 ms.")
    }

    @Test func blipFadesAfterFiveMinutes() {
        let old = Probe(time: now.addingTimeInterval(-6 * 60), role: .internet, ms: nil)
        let a = Evaluator.assess(snapshot([old] + series(.internet, Array(repeating: 17, count: 20), every: 10)))
        #expect(a.light == .green)
    }

    @Test func resendBurstIsYellow() {
        let burst = TrafficSample(time: now.addingTimeInterval(-20), txPackets: 200, rxBytes: 0, resentBytes: 20_000, resendingConnections: 4)
        let a = Evaluator.assess(snapshot(series(.internet, Array(repeating: 17, count: 10), every: 10), traffic: [burst]))
        #expect(a.light == .yellow)
    }

    @Test func fewResentPacketsAcrossConnectionsAreRoutine() {
        let small = TrafficSample(time: now.addingTimeInterval(-20), txPackets: 50, rxBytes: 9000, resentBytes: 5_777, resendingConnections: 5)
        #expect(!small.isResendBurst)
        let a = Evaluator.assess(snapshot(series(.internet, Array(repeating: 17, count: 10), every: 10), traffic: [small]))
        #expect(a.light == .green)
    }

    @Test func outageStartNarrowedByOwnTraffic() {
        let o = Outage(startEarliest: now, startLatest: now.addingTimeInterval(10))
        let traffic = [
            TrafficSample(time: now.addingTimeInterval(4), txPackets: 10, rxBytes: 5000, resentBytes: 0, resendingConnections: 0),
            TrafficSample(time: now.addingTimeInterval(6), txPackets: 10, rxBytes: 0, resentBytes: 6, resendingConnections: 2),
        ]
        let n = o.narrowed(by: traffic)
        #expect(n.startEarliest == now.addingTimeInterval(4))
        #expect(n.startLatest == now.addingTimeInterval(6))
    }

    @Test func baselineThresholds() {
        #expect(fiber.slowThresholdMs! < 80)
        #expect(Baseline().slowThresholdMs == nil)
    }
}
