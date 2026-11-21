import Foundation

/// One hour of one day at one place, summarized for the day-by-hour grid.
public struct HourCell: Equatable, Sendable, Identifiable {
    public let start: Date
    public let watchedMinutes: Int
    public let medianMs: Double?
    public let sent: Int
    public let lost: Int
    public let hadOutage: Bool
    /// Nil when TheWatcher wasn't watching this place during the hour.
    public let light: Light?

    public var id: Date { start }
}

public struct DayRow: Equatable, Sendable, Identifiable {
    public let day: Date
    public let hours: [HourCell]
    public var id: Date { day }
}

public enum HistoryGrid {
    /// Builds one row per local day, newest first, each with 24 hour cells.
    /// Latency is judged against the place's own typical latency over the period.
    public static func build(minutes: [MinuteSummary], outages: [Outage], days: Int, endingAt now: Date,
                             calendar: Calendar = .current) -> [DayRow] {
        let typical = median(minutes.compactMap(\.farMedianMs))
        var byHour: [Date: [MinuteSummary]] = [:]
        for m in minutes {
            let hour = calendar.dateInterval(of: .hour, for: m.date)!.start
            byHour[hour, default: []].append(m)
        }
        let today = calendar.startOfDay(for: now)
        return (0..<days).map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let hours = (0..<24).map { h -> HourCell in
                let start = calendar.date(byAdding: .hour, value: h, to: day)!
                let end = calendar.date(byAdding: .hour, value: 1, to: start)!
                let ms = byHour[start] ?? []
                let outage = outages.contains { ($0.end ?? now) > start && $0.startMidpoint < end }
                    || ms.contains { $0.worstLight == .red }
                return cell(start: start, minutes: ms, hadOutage: outage, typical: typical)
            }
            return DayRow(day: day, hours: hours)
        }
    }

    static func cell(start: Date, minutes: [MinuteSummary], hadOutage: Bool, typical: Double?) -> HourCell {
        let sent = minutes.reduce(0) { $0 + $1.farSent }
        let lost = minutes.reduce(0) { $0 + $1.farLost }
        let med = median(minutes.compactMap(\.farMedianMs))
        var light: Light?
        if !minutes.isEmpty {
            let ratio = (med ?? 0) / max(typical ?? 1, 1)
            let lossFraction = sent > 0 ? Double(lost) / Double(sent) : 0
            if hadOutage { light = .red }
            else if ratio >= 2.5 || lossFraction >= 0.02 { light = .orange }
            else if ratio >= 1.5 || lost > 0 { light = .yellow }
            else { light = .green }
        }
        return HourCell(start: start, watchedMinutes: minutes.count, medianMs: med, sent: sent, lost: lost,
                        hadOutage: hadOutage, light: light)
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[s.count / 2]
    }
}
