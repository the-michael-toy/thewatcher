import Foundation
import SQLite3

public struct Place: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let fingerprint: String
    public var name: String
    /// Latency before this moment no longer says what's normal here.
    public var baselineSince: Date?
}

/// One minute of watching at a place.
public struct MinuteSummary: Equatable, Sendable {
    public let minute: Int64          // seconds since 1970 / 60
    public let farSent: Int
    public let farLost: Int
    public let farMedianMs: Double?
    public let farMaxMs: Double?
    public let resentBytes: Int
    public let worstLight: Light

    public init(minute: Int64, farSent: Int, farLost: Int, farMedianMs: Double?, farMaxMs: Double?, resentBytes: Int, worstLight: Light) {
        self.minute = minute
        self.farSent = farSent
        self.farLost = farLost
        self.farMedianMs = farMedianMs
        self.farMaxMs = farMaxMs
        self.resentBytes = resentBytes
        self.worstLight = worstLight
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }
}

public struct Reliability: Equatable, Sendable {
    public let watchedSeconds: TimeInterval
    public let downSeconds: TimeInterval
    public let outages: [Outage]

    public var uptime: Double { watchedSeconds > 0 ? max(0, 1 - downSeconds / watchedSeconds) : 1 }
    public var longest: TimeInterval { outages.map { $0.duration(asOf: $0.end ?? $0.startLatest) }.max() ?? 0 }
}

/// History for the places the user chose to keep it for. Every ping is kept
/// for a week; one-minute summaries and outages are kept forever.
public final class HistoryStore: @unchecked Sendable {
    public static let rawRetention: TimeInterval = 7 * 24 * 3600
    private var db: OpaquePointer?
    private let lock = NSLock()

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TheWatcher", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    public init(url: URL = HistoryStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "TheWatcher.History", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't open \(url.path)"])
        }
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS places (
                id INTEGER PRIMARY KEY, fingerprint TEXT UNIQUE NOT NULL, name TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS probes (place INTEGER NOT NULL, ts REAL NOT NULL, role INTEGER NOT NULL, ms REAL);
            CREATE INDEX IF NOT EXISTS probes_place_ts ON probes (place, ts);
            -- retx columns hold resent bytes, the unit the kernel counts in.
            CREATE TABLE IF NOT EXISTS traffic (
                place INTEGER NOT NULL, ts REAL NOT NULL, tx INTEGER NOT NULL, retx INTEGER NOT NULL, resending INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS traffic_place_ts ON traffic (place, ts);
            CREATE TABLE IF NOT EXISTS minutes (
                place INTEGER NOT NULL, minute INTEGER NOT NULL, far_sent INTEGER NOT NULL, far_lost INTEGER NOT NULL,
                far_p50 REAL, far_max REAL, retx INTEGER NOT NULL, light INTEGER NOT NULL, PRIMARY KEY (place, minute));
            CREATE TABLE IF NOT EXISTS outages (
                place INTEGER NOT NULL, start_lo REAL NOT NULL, start_hi REAL NOT NULL, end REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS outages_place_end ON outages (place, end);
            """)
        if !columns("places").contains("baseline_since") {
            try exec("ALTER TABLE places ADD COLUMN baseline_since REAL")
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Places

    public func places() -> [Place] {
        query("SELECT id, fingerprint, name, baseline_since FROM places ORDER BY created") { st in
            placeRow(st)
        }
    }

    public func place(fingerprint: String) -> Place? {
        query("SELECT id, fingerprint, name, baseline_since FROM places WHERE fingerprint = ?", [.text(fingerprint)]) { st in
            placeRow(st)
        }.first
    }

    @discardableResult
    public func addPlace(fingerprint: String, name: String) -> Place? {
        run("INSERT OR IGNORE INTO places (fingerprint, name, created) VALUES (?, ?, ?)",
            [.text(fingerprint), .text(name), .real(Date().timeIntervalSince1970)])
        return place(fingerprint: fingerprint)
    }

    public func rename(_ place: Place, to name: String) {
        run("UPDATE places SET name = ? WHERE id = ?", [.text(name), .int(place.id)])
    }

    public func setBaselineSince(_ date: Date, for place: Place) {
        run("UPDATE places SET baseline_since = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .int(place.id)])
    }

    public func forget(_ place: Place) {
        for table in ["probes", "traffic", "minutes", "outages"] {
            run("DELETE FROM \(table) WHERE place = ?", [.int(place.id)])
        }
        run("DELETE FROM places WHERE id = ?", [.int(place.id)])
    }

    // MARK: - Recording

    public func record(probe: Probe, place: Place) {
        run("INSERT INTO probes (place, ts, role, ms) VALUES (?, ?, ?, ?)",
            [.int(place.id), .real(probe.time.timeIntervalSince1970), .int(Int64(probe.role.rawValue)),
             probe.ms.map { .real($0) } ?? .null])
    }

    public func record(traffic t: TrafficSample, place: Place) {
        run("INSERT INTO traffic (place, ts, tx, retx, resending) VALUES (?, ?, ?, ?, ?)",
            [.int(place.id), .real(t.time.timeIntervalSince1970), .int(Int64(t.txPackets)),
             .int(Int64(t.resentBytes)), .int(Int64(t.resendingConnections))])
    }

    public func record(minute m: MinuteSummary, place: Place) {
        run("""
            INSERT OR REPLACE INTO minutes (place, minute, far_sent, far_lost, far_p50, far_max, retx, light)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.int(place.id), .int(m.minute), .int(Int64(m.farSent)), .int(Int64(m.farLost)),
             m.farMedianMs.map { .real($0) } ?? .null, m.farMaxMs.map { .real($0) } ?? .null,
             .int(Int64(m.resentBytes)), .int(Int64(m.worstLight.rawValue))])
    }

    public func record(outage o: Outage, place: Place) {
        guard let end = o.end else { return }
        run("INSERT INTO outages (place, start_lo, start_hi, end) VALUES (?, ?, ?, ?)",
            [.int(place.id), .real(o.startEarliest.timeIntervalSince1970),
             .real(o.startLatest.timeIntervalSince1970), .real(end.timeIntervalSince1970)])
    }

    public func pruneRaw(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.rawRetention).timeIntervalSince1970
        run("DELETE FROM probes WHERE ts < ?", [.real(cutoff)])
        run("DELETE FROM traffic WHERE ts < ?", [.real(cutoff)])
    }

    // MARK: - Reading

    public func probes(place: Place, role: StopRole? = nil, from: Date, to: Date) -> [Probe] {
        var sql = "SELECT ts, role, ms FROM probes WHERE place = ? AND ts >= ? AND ts < ?"
        var args: [Value] = [.int(place.id), .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
        if let role {
            sql += " AND role = ?"
            args.append(.int(Int64(role.rawValue)))
        }
        return query(sql + " ORDER BY ts", args) { st in
            Probe(time: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)),
                  role: StopRole(rawValue: Int(sqlite3_column_int(st, 1))) ?? .internet,
                  ms: sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : sqlite3_column_double(st, 2))
        }
    }

    /// The most recent pings to one stop since the place's baseline was last
    /// reset, oldest first: round trips, nil for lost. Pings from minutes that
    /// were orange or red are left out; trouble isn't what's normal here.
    public func recentPings(place: Place, role: StopRole, limit: Int) -> [Double?] {
        let since = place.baselineSince?.timeIntervalSince1970 ?? 0
        return query("""
            SELECT ms FROM probes p WHERE place = ? AND role = ? AND ts >= ?
              AND NOT EXISTS (SELECT 1 FROM minutes m
                              WHERE m.place = p.place AND m.minute = CAST(p.ts / 60 AS INTEGER) AND m.light >= ?)
            ORDER BY ts DESC LIMIT ?
            """,
              [.int(place.id), .int(Int64(role.rawValue)), .real(since), .int(Int64(Light.orange.rawValue)),
               .int(Int64(limit))]) { st in
            sqlite3_column_type(st, 0) == SQLITE_NULL ? nil : sqlite3_column_double(st, 0)
        }.reversed()
    }

    public func minutes(place: Place, from: Date, to: Date) -> [MinuteSummary] {
        query("""
            SELECT minute, far_sent, far_lost, far_p50, far_max, retx, light FROM minutes
            WHERE place = ? AND minute >= ? AND minute < ? ORDER BY minute
            """,
              [.int(place.id), .int(Int64(from.timeIntervalSince1970 / 60)), .int(Int64(to.timeIntervalSince1970 / 60))]) { st in
            MinuteSummary(
                minute: sqlite3_column_int64(st, 0),
                farSent: Int(sqlite3_column_int(st, 1)),
                farLost: Int(sqlite3_column_int(st, 2)),
                farMedianMs: sqlite3_column_type(st, 3) == SQLITE_NULL ? nil : sqlite3_column_double(st, 3),
                farMaxMs: sqlite3_column_type(st, 4) == SQLITE_NULL ? nil : sqlite3_column_double(st, 4),
                resentBytes: Int(sqlite3_column_int(st, 5)),
                worstLight: Light(rawValue: Int(sqlite3_column_int(st, 6))) ?? .green)
        }
    }

    public func outages(place: Place, from: Date, to: Date) -> [Outage] {
        query("SELECT start_lo, start_hi, end FROM outages WHERE place = ? AND end >= ? AND start_lo < ? ORDER BY start_lo",
              [.int(place.id), .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { st in
            Outage(startEarliest: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)),
                   startLatest: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                   end: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)))
        }
    }

    /// Uptime measured only over the time TheWatcher was actually watching this place.
    public func reliability(place: Place, from: Date, to: Date) -> Reliability {
        let watchedMinutes = query("SELECT COUNT(*) FROM minutes WHERE place = ? AND minute >= ? AND minute < ?",
                                   [.int(place.id), .int(Int64(from.timeIntervalSince1970 / 60)),
                                    .int(Int64(to.timeIntervalSince1970 / 60))]) { sqlite3_column_int64($0, 0) }.first ?? 0
        let outages = outages(place: place, from: from, to: to)
        let down = outages.reduce(0.0) { sum, o in
            let start = max(o.startMidpoint, from), end = min(o.end ?? to, to)
            return sum + max(0, end.timeIntervalSince(start))
        }
        return Reliability(watchedSeconds: TimeInterval(watchedMinutes * 60), downSeconds: down, outages: outages)
    }

    // MARK: - SQLite plumbing

    enum Value {
        case int(Int64)
        case real(Double)
        case text(String)
        case null
    }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(domain: "TheWatcher.History", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func columns(_ table: String) -> [String] {
        query("PRAGMA table_info(\(table))") { text($0, 1) }
    }

    private func run(_ sql: String, _ args: [Value] = []) {
        _ = query(sql, args) { _ in () }
    }

    private func query<T>(_ sql: String, _ args: [Value] = [], row: (OpaquePointer) -> T) -> [T] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return [] }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .real(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, transient)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        var rows: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { rows.append(row(st)) }
        return rows
    }
}

private func placeRow(_ st: OpaquePointer) -> Place {
    Place(id: sqlite3_column_int64(st, 0), fingerprint: text(st, 1), name: text(st, 2),
          baselineSince: sqlite3_column_type(st, 3) == SQLITE_NULL ? nil
              : Date(timeIntervalSince1970: sqlite3_column_double(st, 3)))
}

private func text(_ st: OpaquePointer, _ col: Int32) -> String {
    sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
}
