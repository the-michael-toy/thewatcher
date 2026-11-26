import Foundation
import Testing
@testable import WatcherCore

/// Drives the real `Watch` through simulated seconds. Each ping it asks for is
/// answered by `network(time, role)`: a round trip in ms, or nil for lost,
/// delivered after that delay (or after a 2-second timeout when lost), the
/// way Monitor would deliver it.
private struct Run {
    var watch = Watch()
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var network: (Date, StopRole) -> Double? = { _, _ in 18 }
    var log: [(time: Date, action: Watch.Action)] = []
    private var inFlight: [(due: Date, event: Watch.Event)] = []

    mutating func send(_ event: Watch.Event) {
        for action in watch.handle(event) {
            log.append((now, action))
            if case .ping(let stop, let sentAt, let net) = action {
                let ms = network(sentAt, stop.role)
                let due = sentAt.addingTimeInterval(ms.map { $0 / 1000 } ?? 2)
                inFlight.append((due, .probe(Probe(time: sentAt, role: stop.role, ms: ms), network: net, at: due)))
            }
        }
    }

    mutating func run(_ seconds: Int) {
        for _ in 0..<seconds {
            now = now.addingTimeInterval(1)
            let ready = inFlight.filter { $0.due <= now }
            inFlight.removeAll { $0.due <= now }
            for r in ready { send(r.event) }
            send(.tick(now))
        }
    }

    mutating func join(_ path: NetworkPath, place: Place? = nil, farSeed: [Double] = []) {
        send(.pathChanged(satisfied: true, connection: path.connection, signature: path.fingerprint ?? "", at: now))
        send(.discovered(path, place: place, seeds: [.internet: farSeed], at: now))
    }

    func actions(since: Date? = nil, where match: (Watch.Action) -> Bool) -> [Watch.Action] {
        log.filter { $0.time >= (since ?? .distantPast) && match($0.action) }.map(\.action)
    }

    func internetPings(since: Date? = nil) -> Int {
        actions(since: since) { if case .ping(let s, _, _) = $0 { s.role == .internet } else { false } }.count
    }
}

private let home = NetworkPath(connection: .wifi, interface: "en0", router: IPv4("192.168.4.1")!, fingerprint: "home-router",
                               stops: [Stop(role: .router, address: IPv4("192.168.4.1")), Stop(role: .upstream, address: IPv4("192.168.1.254")),
                                       Stop(role: .isp, address: IPv4("203.0.113.1")), Stop(role: .internet, address: nil)])
private let cafe = NetworkPath(connection: .wifi, interface: "en0", router: IPv4("10.0.0.1")!, fingerprint: "cafe-router",
                               stops: [Stop(role: .router, address: IPv4("10.0.0.1")), Stop(role: .isp, address: IPv4("68.1.2.3")),
                                       Stop(role: .internet, address: nil)])
private let homePlace = Place(id: 1, fingerprint: "home-router", name: "Home")
private let fiberSeed = (0..<200).map { 15 + Double($0 % 6) }

struct WatchTests {
    @Test func wakingOnADifferentNetworkStartsOver() {
        var r = Run()
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(60)
        r.send(.sleep(r.now))
        r.now = r.now.addingTimeInterval(3600)
        r.send(.wake(r.now))
        #expect(r.watch.path == nil && r.watch.place == nil && r.watch.probes.isEmpty)

        // A ping sent at home, answered once the café is known, must not land anywhere.
        let wokeAt = r.now
        r.join(cafe)
        r.send(.probe(Probe(time: wokeAt, role: .internet, ms: 20), network: "home-router", at: wokeAt))
        r.run(120)
        #expect(r.watch.place == nil)
        #expect(r.actions(since: wokeAt) { if case .recordProbe = $0 { true } else { false } }.isEmpty)
        #expect(r.watch.probes.allSatisfy { $0.time > wokeAt })
        #expect(r.watch.assessment.light == .green)
    }

    @Test func aLinkThatIsAlwaysSlowBecomesItsOwnNormal() {
        var r = Run()
        r.network = { _, role in role == .internet ? 600 : 5 }
        r.join(cafe)
        r.run(600)
        #expect(r.watch.assessment.light == .green)
        // Ten minutes at the normal pace is 60 pings; once a second would be 600.
        #expect(r.internetPings() <= 65)
    }

    @Test func aNewPlaceLearnsItsNormalEvenWhileLosingPings() {
        var r = Run()
        var count = 0
        r.network = { _, role in
            guard role == .internet else { return 5 }
            count += 1
            return count % 5 == 0 ? nil : 40
        }
        r.join(cafe)
        r.run(5 * 60)
        #expect(r.watch.assessment.light == .orange)
        #expect(r.watch.farBaseline.isLearned)
    }

    @Test func onceASecondPingingStopsAtTheCapEvenIfLossContinues() {
        var r = Run()
        var count = 0
        r.network = { _, role in
            guard role == .internet else { return 5 }
            count += 1
            return count % 5 == 0 ? nil : 18
        }
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(4 * 60)
        #expect(r.watch.assessment.light == .orange)
        let afterCap = r.now
        r.run(10 * 60)
        #expect(r.internetPings(since: afterCap) <= 62)
        #expect(r.watch.assessment.light == .orange)
    }

    @Test func anOutageIsTimedToTheSecondAndReportedOnce() {
        var r = Run()
        let start = r.now
        let downFrom = start.addingTimeInterval(60), backAt = start.addingTimeInterval(150)
        r.network = { t, role in
            role == .internet && t >= downFrom && t < backAt ? nil : (role == .internet ? 18 : 5)
        }
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(240)
        let ended = r.actions { if case .outageEnded = $0 { true } else { false } }
        let recorded = r.actions { if case .recordOutage = $0 { true } else { false } }
        #expect(ended.count == 1)
        #expect(recorded.count == 1)
        guard case .outageEnded(let o) = ended.first else { return }
        #expect(abs(o.end!.timeIntervalSince(backAt)) <= 1.5)
        #expect(o.startEarliest <= downFrom && o.startLatest >= downFrom)
        #expect(r.actions { if case .lightChanged(let a) = $0 { a.light == .red } else { false } }.count == 1)
    }

    /// Runs of lost pings with a few answers between them are one stretch of
    /// trouble: one outage, one notification.
    @Test func repeatedDropoutsAreOneOutage() {
        var r = Run()
        let start = r.now
        let badFrom = start.addingTimeInterval(60), badUntil = start.addingTimeInterval(15 * 60)
        r.network = { t, role in
            let cycle = Int(t.timeIntervalSince(start)) % 8
            return t >= badFrom && t < badUntil && cycle < 5 ? nil : (role == .internet ? 18 : 5)
        }
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(16 * 60)
        // Once the loss stops, red stops within about five pings at the normal pace.
        #expect(r.watch.assessment.light < .red)
        r.run(9 * 60)
        let ended = r.actions { if case .outageEnded = $0 { true } else { false } }
        #expect(ended.count == 1)
        #expect(r.actions { if case .recordOutage = $0 { true } else { false } }.count == 1)
        guard case .outageEnded(let o) = ended.first else { return }
        #expect(o.startLatest >= badFrom && o.startEarliest < badFrom.addingTimeInterval(30))
        #expect(abs(o.end!.timeIntervalSince(badUntil)) <= 20)
        #expect(r.watch.assessment.light == .green)
    }

    @Test func anOutageFromSlownessEndsWhenLatencyRecovers() {
        var r = Run()
        let start = r.now
        let slowFrom = start.addingTimeInterval(60), slowUntil = start.addingTimeInterval(660)
        r.network = { t, role in role == .internet && t >= slowFrom && t < slowUntil ? 900 : (role == .internet ? 18 : 5) }
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(15 * 60)
        let ended = r.actions { if case .outageEnded = $0 { true } else { false } }
        #expect(ended.count == 1)
        guard case .outageEnded(let o) = ended.first else { return }
        #expect(abs(o.end!.timeIntervalSince(slowUntil)) <= 15)
        #expect(o.duration(asOf: o.end!) > 9 * 60)
    }

    @Test func aNewOutageDoesNotStartInsideTheLastOne() {
        var r = Run()
        let start = r.now
        let down: [(TimeInterval, TimeInterval)] = [(120, 420), (520, 560)]
        r.network = { t, role in
            let s = t.timeIntervalSince(start)
            return role == .internet && down.contains { s >= $0.0 && s < $0.1 } ? nil : (role == .internet ? 18 : 5)
        }
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(15 * 60)
        let outages = r.actions { if case .recordOutage = $0 { true } else { false } }.compactMap {
            if case .recordOutage(let o, _) = $0 { o } else { nil }
        }
        #expect(outages.count == 2)
        guard outages.count == 2 else { return }
        #expect(outages[1].startEarliest >= outages[0].end!)
        #expect(outages[1].duration(asOf: outages[1].end!) < 60)
    }

    /// Joining a network that is already down must not learn the outage as normal loss.
    @Test func lossDuringTroubleIsNotLearnedAsNormal() {
        var r = Run()
        var routerCount = 0
        r.network = { _, role in
            switch role {
            case .internet: return nil
            case .router:
                routerCount += 1
                return routerCount % 97 == 0 ? nil : 5
            default: return 9
            }
        }
        r.join(cafe)
        r.run(5 * 60)
        #expect(r.watch.assessment.headline == "Nothing beyond your ISP is answering.")
    }

    @Test func sleepingDuringAnOutageRecordsItWithoutAnnouncingItsEnd() {
        var r = Run()
        let downFrom = r.now.addingTimeInterval(60)
        r.network = { t, role in role == .internet && t >= downFrom ? nil : 18 }
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(120)
        #expect(r.watch.assessment.light == .red)
        r.send(.sleep(r.now))
        #expect(r.actions { if case .recordOutage = $0 { true } else { false } }.count == 1)
        #expect(r.actions { if case .outageEnded = $0 { true } else { false } }.isEmpty)
    }

    @Test func relearnAcceptsAPermanentlyWorseNormal() {
        var r = Run()
        r.network = { _, role in role == .internet ? 90 : 5 }
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(300)
        #expect(r.watch.assessment.light == .orange)
        // Slowness alone never brings on once-a-second pinging.
        #expect(r.internetPings() <= 32)
        r.send(.relearn(homePlace.id, at: r.now))
        r.run(300)
        #expect(r.watch.assessment.light == .green)
    }

    @Test func historyIsRecordedOnlyAtKeptPlaces() {
        var r = Run()
        r.join(cafe)
        r.run(180)
        #expect(r.actions { if case .recordMinute = $0 { true } else { false } }.isEmpty)
        r.join(home, place: homePlace, farSeed: fiberSeed)
        r.run(180)
        let minutes = r.actions { if case .recordMinute = $0 { true } else { false } }
        #expect(minutes.count >= 2)
    }

    @Test func aLoginPageShowsGrayAndStopsFastPinging() {
        var r = Run()
        r.network = { _, role in role == .router ? 5 : nil }
        r.join(cafe)
        r.run(40)
        #expect(r.watch.assessment.light == .red)
        #expect(!r.actions { $0 == .checkCaptive }.isEmpty)
        r.send(.captive(true, at: r.now))
        let caught = r.now
        r.run(120)
        #expect(r.watch.assessment.light == .gray)
        #expect(r.watch.assessment.headline == "Waiting for network login.")
        #expect(r.internetPings(since: caught) <= 13)
    }
}
