import Charts
import SwiftUI
import WatcherCore

/// History for one place: how reliable it has been, a day-by-hour grid that
/// makes daily patterns visible, and any hour opened up as a timeline.
struct DetailsView: View {
    let monitor: Monitor
    @State private var placeID: Int64?
    @State private var rows: [DayRow] = []
    @State private var reliability: Reliability?
    @State private var selected: HourCell?
    @State private var hourProbes: [Probe] = []
    @State private var hourMinutes: [MinuteSummary] = []

    static let days = 30

    private var place: Place? {
        monitor.places.first { $0.id == placeID } ?? monitor.place ?? monitor.places.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Place", selection: Binding(get: { place?.id }, set: { placeID = $0; load() })) {
                    ForEach(monitor.places) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(width: 240)
                Spacer()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            if let reliability { summary(reliability) }
            grid
            if let selected { hourDetail(selected) }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 640)
        .onAppear(perform: load)
    }

    private func summary(_ r: Reliability) -> some View {
        let hours = Int(r.watchedSeconds / 3600)
        let uptime = String(format: "%.2f%%", r.uptime * 100)
        let outages = r.outages.isEmpty ? "no outages"
            : "\(r.outages.count) outage\(r.outages.count == 1 ? "" : "s"), longest \(Format.duration(r.longest))"
        return VStack(alignment: .leading, spacing: 4) {
            Text(hours == 0 ? "Not enough watched time yet." : "\(uptime) up across \(hours) watched hours · \(outages)")
                .font(.title3.weight(.semibold))
            Text("Last \(Self.days) days. Time away counts as unwatched, never as up or down.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text("").frame(width: 70)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 3 == 0 ? hourLabel(h) : "")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        HStack(spacing: 2) {
                            Text(row.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            ForEach(row.hours) { cell in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(fill(cell))
                                    .overlay(RoundedRectangle(cornerRadius: 2)
                                        .stroke(selected?.id == cell.id ? Color.primary : .clear, lineWidth: 1.5))
                                    .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                                    .help(tooltip(cell))
                                    .onTapGesture { select(cell) }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 330)
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(.green, "normal")
            swatch(.yellow, "slower than usual or a lost ping")
            swatch(.orange, "much slower or losing pings")
            swatch(.red, "outage")
            swatch(.secondary.opacity(0.1), "not watching")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }

    private func hourDetail(_ cell: HourCell) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cell.start, format: .dateTime.weekday(.wide).month().day().hour())
                .font(.headline)
            Chart {
                if !hourProbes.isEmpty {
                    ForEach(Array(hourProbes.enumerated()), id: \.offset) { _, p in
                        if let ms = p.ms {
                            LineMark(x: .value("Time", p.time), y: .value("ms", ms)).foregroundStyle(.blue)
                        } else {
                            PointMark(x: .value("Time", p.time), y: .value("ms", 0)).foregroundStyle(.red).symbolSize(20)
                        }
                    }
                } else {
                    ForEach(hourMinutes, id: \.minute) { m in
                        if let max = m.farMaxMs {
                            AreaMark(x: .value("Time", m.date), yStart: .value("ms", m.farMedianMs ?? max), yEnd: .value("ms", max))
                                .foregroundStyle(.blue.opacity(0.15))
                        }
                        if let med = m.farMedianMs {
                            LineMark(x: .value("Time", m.date), y: .value("ms", med)).foregroundStyle(.blue)
                        }
                        if m.farLost > 0 {
                            PointMark(x: .value("Time", m.date), y: .value("ms", 0)).foregroundStyle(.red).symbolSize(20)
                        }
                    }
                }
            }
            .chartXScale(domain: cell.start...cell.start.addingTimeInterval(3600))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) ms") } }
                }
            }
            .frame(height: 140)
            Text(hourProbes.isEmpty ? "Per-minute typical and worst latency; red marks lost pings."
                                    : "Every ping to the internet; red marks lost pings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fill(_ cell: HourCell) -> Color {
        guard let light = cell.light else { return .secondary.opacity(0.1) }
        return Color(nsColor: Dot.color(light)).opacity(light == .green ? 0.55 : 0.9)
    }

    private func tooltip(_ cell: HourCell) -> String {
        guard cell.light != nil else { return "Not watching" }
        var parts = [cell.medianMs.map { "typical \(Format.ms($0))" } ?? "no replies"]
        if cell.lost > 0 { parts.append("\(cell.lost) of \(cell.sent) pings lost") }
        if cell.hadOutage { parts.append("outage") }
        parts.append("watched \(cell.watchedMinutes) min")
        return parts.joined(separator: " · ")
    }

    private func hourLabel(_ h: Int) -> String {
        h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p"
    }

    private func load() {
        guard let store = monitor.store, let place else { return }
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(Self.days - 1), to: Calendar.current.startOfDay(for: now))!
        rows = HistoryGrid.build(minutes: store.minutes(place: place, from: from, to: now),
                                 outages: store.outages(place: place, from: from, to: now),
                                 days: Self.days, endingAt: now)
        reliability = store.reliability(place: place, from: from, to: now)
        if let selected { select(selected) }
    }

    private func select(_ cell: HourCell) {
        guard let store = monitor.store, let place, cell.light != nil else { return }
        selected = cell
        let end = cell.start.addingTimeInterval(3600)
        hourProbes = store.probes(place: place, role: .internet, from: cell.start, to: end)
        hourMinutes = store.minutes(place: place, from: cell.start, to: end)
    }
}
