import Foundation
import Testing
@testable import WatcherCore

struct HistoryStoreTests {
    func makeStore() throws -> HistoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)/h.sqlite")
        return try HistoryStore(url: url)
    }

    @Test func placesRoundTrip() throws {
        let store = try makeStore()
        let home = try #require(store.addPlace(fingerprint: "aa:bb", name: "Home"))
        #expect(store.place(fingerprint: "aa:bb")?.name == "Home")
        store.rename(home, to: "House")
        #expect(store.places().map(\.name) == ["House"])
        store.forget(home)
        #expect(store.places().isEmpty)
    }

    @Test func reliabilityCountsOnlyWatchedTime() throws {
        let store = try makeStore()
        let home = try #require(store.addPlace(fingerprint: "aa:bb", name: "Home"))
        let start = Date(timeIntervalSince1970: 6_000_000)
        for m in 0..<100 {
            store.record(minute: MinuteSummary(minute: Int64(start.timeIntervalSince1970 / 60) + Int64(m), farSent: 6,
                                               farLost: 0, farMedianMs: 17, farMaxMs: 20, resentBytes: 0, worstLight: .green),
                         place: home)
        }
        store.record(outage: Outage(startEarliest: start.addingTimeInterval(590), startLatest: start.addingTimeInterval(610),
                                    end: start.addingTimeInterval(900)), place: home)
        let r = store.reliability(place: home, from: start, to: start.addingTimeInterval(30 * 24 * 3600))
        #expect(r.watchedSeconds == 6000)
        #expect(r.downSeconds == 300)
        #expect(abs(r.uptime - 0.95) < 0.0001)
        #expect(r.outages.count == 1)
    }

    @Test func rawProbesArePrunedAfterAWeek() throws {
        let store = try makeStore()
        let home = try #require(store.addPlace(fingerprint: "aa:bb", name: "Home"))
        let now = Date()
        store.record(probe: Probe(time: now.addingTimeInterval(-8 * 24 * 3600), role: .internet, ms: 10), place: home)
        store.record(probe: Probe(time: now.addingTimeInterval(-60), role: .internet, ms: 12), place: home)
        store.pruneRaw(now: now)
        let left = store.probes(place: home, from: now.addingTimeInterval(-30 * 24 * 3600), to: now)
        #expect(left.map(\.ms) == [12])
        #expect(store.recentPings(place: home, role: .internet, limit: 10) == [12])
    }

    @Test func troubleIsNotSeededAsNormal() throws {
        let store = try makeStore()
        let home = try #require(store.addPlace(fingerprint: "aa:bb", name: "Home"))
        let calm = Date(timeIntervalSince1970: 6_000_000), bad = calm.addingTimeInterval(60)
        for (minute, light) in [(calm, Light.green), (bad, .red)] {
            store.record(minute: MinuteSummary(minute: Int64(minute.timeIntervalSince1970 / 60), farSent: 6, farLost: 0,
                                               farMedianMs: 17, farMaxMs: 20, resentBytes: 0, worstLight: light), place: home)
        }
        store.record(probe: Probe(time: calm.addingTimeInterval(5), role: .isp, ms: 9), place: home)
        store.record(probe: Probe(time: calm.addingTimeInterval(35), role: .isp, ms: nil), place: home)
        store.record(probe: Probe(time: bad.addingTimeInterval(5), role: .isp, ms: 400), place: home)
        store.record(probe: Probe(time: bad.addingTimeInterval(35), role: .isp, ms: nil), place: home)
        #expect(store.recentPings(place: home, role: .isp, limit: 10) == [9, nil])
    }
}
