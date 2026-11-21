import CNetStat
import Foundation

/// Samples this Mac's own TCP traffic once a second from the kernel's
/// connection statistics. Adds no network traffic of its own.
public final class TrafficMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TheWatcher.Traffic")
    private var ctx: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private let onSample: @Sendable (TrafficSample) -> Void

    /// Nil when the kernel refuses access; TheWatcher then relies on pings alone.
    public init?(onSample: @escaping @Sendable (TrafficSample) -> Void) {
        var err: Int32 = 0
        guard let ctx = cn_open(&err) else { return nil }
        self.ctx = ctx
        self.onSample = onSample
    }

    deinit {
        timer?.cancel()
        // Closed on the queue so an in-flight sample finishes first.
        nonisolated(unsafe) let ctx = self.ctx
        queue.async { cn_close(ctx) }
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            var discard = cn_sample()
            _ = cn_sample_now(ctx, &discard)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        var s = cn_sample()
        guard cn_sample_now(ctx, &s) == 0 else { return }
        onSample(TrafficSample(
            time: Date(),
            txPackets: s.tx_packets,
            rxBytes: s.rx_bytes,
            resentBytes: s.resent_bytes,
            resendingConnections: Int(s.resending_connections)
        ))
    }
}
