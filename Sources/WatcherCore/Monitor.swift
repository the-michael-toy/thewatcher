import Foundation
import Network
import Observation
import os

private let log = Logger(subsystem: "local.thewatcher.TheWatcher", category: "monitor")

/// Connects `Watch` to the world: a one-second clock, network-change
/// notices, the pinger, path discovery, the Mac's traffic statistics, and the
/// history store. All decisions are made by `Watch`.
@MainActor
@Observable
public final class Monitor {
    public static let liveWindow = Watch.liveWindow

    public private(set) var watch = Watch()
    public private(set) var places: [Place] = []
    public private(set) var trafficAvailable = false

    public var assessment: Assessment { watch.assessment }
    public var path: NetworkPath? { watch.path }
    public var place: Place? { watch.place }
    public var probes: [Probe] { watch.probes }
    public var traffic: [TrafficSample] { watch.traffic }
    public var baselines: [StopRole: Baseline] { watch.baselines }
    public var farBaseline: Baseline { watch.farBaseline }

    /// Called when an outage ends while still on the same network.
    @ObservationIgnored public var onOutageEnded: ((Outage) -> Void)?
    @ObservationIgnored public let store: HistoryStore?

    @ObservationIgnored private let pinger: Pinger?
    @ObservationIgnored private var trafficMonitor: TrafficMonitor?
    /// A cancelled NWPathMonitor never reports again, so each start gets a new one.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var farTurn = 0
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private var running = false

    public init(store: HistoryStore?) {
        self.store = store
        self.pinger = try? Pinger()
        places = store?.places() ?? []
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        dispatch(.wake(Date()))
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] nwPath in
            let update = PathUpdate(nwPath)
            Task { @MainActor in
                self?.dispatch(.pathChanged(satisfied: update.satisfied, connection: update.connection,
                                            signature: update.signature, at: Date()))
            }
        }
        monitor.start(queue: DispatchQueue(label: "TheWatcher.Path"))
        pathMonitor = monitor
        if trafficMonitor == nil {
            trafficMonitor = TrafficMonitor { [weak self] sample in
                Task { @MainActor in self?.dispatch(.traffic(sample)) }
            }
            trafficAvailable = trafficMonitor != nil
        }
        trafficMonitor?.start()
        tickTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Before sleep.
    public func pause() {
        guard running else { return }
        running = false
        tickTask?.cancel()
        tickTask = nil
        discoveryTask?.cancel()
        trafficMonitor?.stop()
        pathMonitor?.cancel()
        pathMonitor = nil
        dispatch(.sleep(Date()))
    }

    /// After wake: possibly somewhere else now, so the path is found again.
    public func resume() {
        start()
    }

    // MARK: - Places

    public func keepHistoryHere(name: String) {
        guard let store, let fingerprint = path?.fingerprint,
              let kept = store.addPlace(fingerprint: fingerprint, name: name) else { return }
        places = store.places()
        dispatch(.placeKept(kept, at: Date()))
    }

    public func rename(_ p: Place, to name: String) {
        store?.rename(p, to: name)
        places = store?.places() ?? []
        if let renamed = places.first(where: { $0.id == p.id }) { dispatch(.placeRenamed(renamed)) }
    }

    public func forget(_ p: Place) {
        store?.forget(p)
        places = store?.places() ?? []
        dispatch(.placeForgotten(p.id))
    }

    /// Forget what's normal at a place; the next samples there define it again.
    public func relearn(_ p: Place) {
        let now = Date()
        store?.setBaselineSince(now, for: p)
        places = store?.places() ?? []
        dispatch(.relearn(p.id, at: now))
    }

    // MARK: - Performing what Watch decides

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastPrune) > 6 * 3600 {
            lastPrune = now
            store?.pruneRaw(now: now)
        }
        dispatch(.tick(now))
    }

    private func dispatch(_ event: Watch.Event) {
        for action in watch.handle(event) { perform(action) }
    }

    private func perform(_ action: Watch.Action) {
        switch action {
        case .ping(let stop, let sentAt, let network):
            ping(stop, sentAt: sentAt, network: network)
        case .discover(let connection):
            discover(connection)
        case .checkCaptive:
            Task {
                let captive = await CaptivePortal.check()
                self.dispatch(.captive(captive, at: Date()))
            }
        case .recordProbe(let probe, let place):
            store?.record(probe: probe, place: place)
        case .recordTraffic(let sample, let place):
            store?.record(traffic: sample, place: place)
        case .recordMinute(let summary, let place):
            store?.record(minute: summary, place: place)
        case .recordOutage(let outage, let place):
            store?.record(outage: outage, place: place)
        case .outageEnded(let outage):
            onOutageEnded?(outage)
        case .lightChanged(let a):
            log.notice("light \(String(describing: a.light), privacy: .public): \(a.headline, privacy: .public) \(a.detail ?? "", privacy: .public)")
        }
    }

    private func ping(_ stop: Stop, sentAt: Date, network: String?) {
        guard let pinger else { return }
        if let address = stop.address {
            Task {
                let ms = await pinger.ping(address).replyMs
                self.dispatch(.probe(Probe(time: sentAt, role: stop.role, ms: ms), network: network, at: Date()))
            }
        } else {
            // Take turns between the far hosts; the internet is down only when both are.
            let hosts = PathDiscovery.farHosts
            let first = hosts[farTurn % hosts.count]
            let second = hosts[(farTurn + 1) % hosts.count]
            farTurn += 1
            Task {
                var ms = await pinger.ping(first).replyMs
                if ms == nil { ms = await pinger.ping(second).replyMs }
                self.dispatch(.probe(Probe(time: sentAt, role: .internet, ms: ms), network: network, at: Date()))
            }
        }
    }

    private func discover(_ connection: Connection) {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            let found = await PathDiscovery.discover(connection: connection)
            guard !Task.isCancelled, let self else { return }
            let kept = found?.fingerprint.flatMap { self.store?.place(fingerprint: $0) }
            var seeds: [StopRole: [Double?]] = [:]
            if let kept, let store = self.store {
                for role in StopRole.allCases {
                    seeds[role] = store.recentPings(place: kept, role: role, limit: Baseline.capacity)
                }
            }
            self.dispatch(.discovered(found, place: kept, seeds: seeds, at: Date()))
            if let found {
                let stops = found.stops.map { "\($0.role)=\($0.address?.description ?? "far")" }.joined(separator: " ")
                log.notice("path: \(found.connection.rawValue, privacy: .public) via \(found.interface, privacy: .public), place \(kept?.name ?? "unknown", privacy: .public): \(stops, privacy: .public)")
            } else {
                log.notice("path: none found")
            }
        }
    }

    private struct PathUpdate: Sendable {
        let satisfied: Bool
        let connection: Connection
        let signature: String

        init(_ p: NWPath) {
            satisfied = p.status == .satisfied
            if p.usesInterfaceType(.wifi) {
                connection = p.isExpensive ? .hotspot : .wifi
            } else if p.usesInterfaceType(.wiredEthernet) {
                connection = p.isExpensive ? .hotspot : .ethernet
            } else if p.usesInterfaceType(.cellular) {
                connection = .hotspot
            } else {
                connection = .other
            }
            signature = "\(p.status) \(p.availableInterfaces.map(\.name)) \(p.gateways.map(\.debugDescription))"
        }
    }
}

enum CaptivePortal {
    /// True when a web request is answered by something other than the real
    /// page, which is what a login page intercepting traffic looks like.
    static func check() async -> Bool {
        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              response is HTTPURLResponse
        else { return false }
        return !(String(data: data, encoding: .utf8) ?? "").contains("Success")
    }
}
