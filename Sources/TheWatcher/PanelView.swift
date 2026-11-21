import Charts
import SwiftUI
import WatcherCore

/// "What's up": the sentence, then the last fifteen minutes, live.
struct PanelView: View {
    let monitor: Monitor
    let windows: Windows
    let close: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                header
                if let path = monitor.path {
                    Strips(monitor: monitor, path: path, now: context.date)
                    LatencyChart(probes: monitor.probes.filter { $0.role == .internet },
                                 baseline: monitor.farBaseline, now: context.date)
                }
                Divider()
                footer
            }
            .padding(16)
            .frame(width: 440)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Color(nsColor: Dot.color(monitor.assessment.light))).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.assessment.headline).font(.headline)
                if let detail = monitor.assessment.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if let place = monitor.place {
                Label(place.name, systemImage: "mappin.and.ellipse").foregroundStyle(.secondary).fixedSize()
            } else if monitor.path != nil {
                Text("Unknown network").foregroundStyle(.secondary).fixedSize()
            } else {
                Text("No network").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("More details…") {
                close()
                windows.showDetails()
            }
            .disabled(monitor.places.isEmpty)
            .fixedSize()
            Menu {
                Button("Settings…") {
                    close()
                    windows.showSettings()
                }
                Divider()
                Button("Quit TheWatcher") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.callout)
    }
}

/// One row per stop on the path, plus the Mac's own traffic.
private struct Strips: View {
    let monitor: Monitor
    let path: NetworkPath
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(path.stops) { stop in
                row(stop.label(connection: path.connection)) { ctx, size in
                    drawProbes(monitor.probes.filter { $0.role == stop.role }, role: stop.role, ctx: ctx, size: size)
                }
            }
            if monitor.trafficAvailable {
                row("Your apps") { ctx, size in drawTraffic(ctx: ctx, size: size) }
            }
            HStack {
                Spacer().frame(width: Strips.labelWidth)
                Text("−15 min")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    static let labelWidth: CGFloat = 112

    private func row(_ label: String, draw: @escaping (GraphicsContext, CGSize) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Strips.labelWidth, alignment: .leading)
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3),
                         with: .color(.secondary.opacity(0.12)))
                draw(ctx, size)
            }
            .frame(height: 12)
        }
    }

    private func x(_ t: Date, _ width: CGFloat) -> CGFloat {
        let age = now.timeIntervalSince(t)
        return width * CGFloat(1 - age / Monitor.liveWindow)
    }

    private func drawProbes(_ probes: [Probe], role: StopRole, ctx: GraphicsContext, size: CGSize) {
        let slow = (role == .internet ? monitor.farBaseline.slowThresholdMs : nil) ?? .infinity
        let longestGap: TimeInterval = role == .isp ? 35 : 15
        for (i, p) in probes.enumerated() {
            let next = i + 1 < probes.count ? probes[i + 1].time : now
            let end = min(next, p.time.addingTimeInterval(longestGap))
            let x0 = x(p.time, size.width), x1 = max(x(end, size.width), x0 + 1.5)
            guard x1 > 0 else { continue }
            let color: Color = p.lost ? .red : ((p.ms ?? 0) > slow ? .orange : .green)
            ctx.fill(Path(CGRect(x: max(0, x0), y: 0, width: x1 - max(0, x0), height: size.height)),
                     with: .color(color.opacity(p.lost ? 0.9 : 0.7)))
        }
    }

    private func drawTraffic(ctx: GraphicsContext, size: CGSize) {
        for t in monitor.traffic where t.resentBytes > 0 {
            let x0 = x(t.time.addingTimeInterval(-1), size.width)
            guard x0 + 2 > 0 else { continue }
            // A resend here and there is normal; only several connections at once is a burp.
            let color: Color = t.isResendBurst ? .orange : .secondary.opacity(0.35)
            ctx.fill(Path(CGRect(x: max(0, x0), y: 0, width: 2, height: size.height)), with: .color(color))
        }
    }
}

/// Round trips to the internet over the live window, against what's normal here.
private struct LatencyChart: View {
    let probes: [Probe]
    let baseline: Baseline
    let now: Date

    var body: some View {
        Chart {
            if let typical = baseline.median {
                RuleMark(y: .value("Usual", typical))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(Array(probes.enumerated()), id: \.offset) { _, p in
                if let ms = p.ms {
                    LineMark(x: .value("Time", p.time), y: .value("ms", ms))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                } else {
                    PointMark(x: .value("Time", p.time), y: .value("ms", 0))
                        .foregroundStyle(.red)
                        .symbolSize(18)
                }
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-Monitor.liveWindow)...now)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) ms") } }
            }
        }
        .frame(height: 90)
    }
}
