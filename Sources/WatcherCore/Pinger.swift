import Darwin
import Foundation

public enum PingOutcome: Equatable, Sendable {
    /// The target answered; round trip in milliseconds.
    case reply(ms: Double, from: IPv4)
    /// A router along the way reported the packet's hop limit ran out.
    case timeExceeded(ms: Double, from: IPv4)
    case unreachable(from: IPv4)
    case timeout
    case sendFailed(errno: Int32)

    public var replyMs: Double? {
        if case .reply(let ms, _) = self { return ms }
        return nil
    }
}

/// Sends ICMP echo requests from an unprivileged datagram socket and matches
/// replies by identifier and sequence. Each instance owns one socket; probes
/// that need a custom hop limit should use their own instance.
public final class Pinger: @unchecked Sendable {
    private let fd: Int32
    private let identifier: UInt16
    private let queue = DispatchQueue(label: "TheWatcher.Pinger")
    private var readSource: DispatchSourceRead?
    private var sequence: UInt16 = 0
    private var pending: [UInt16: Pending] = [:]

    private struct Pending {
        let target: IPv4
        let sentAt: UInt64
        let continuation: CheckedContinuation<PingOutcome, Never>
        let timeout: DispatchWorkItem
    }

    public init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        identifier = UInt16.random(in: 1...UInt16.max)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        readSource = source
    }

    deinit {
        readSource?.cancel()
    }

    public func ping(_ target: IPv4, ttl: Int32? = nil, timeout: TimeInterval = 2) async -> PingOutcome {
        await withCheckedContinuation { continuation in
            queue.async { self.send(target, ttl: ttl, timeout: timeout, continuation: continuation) }
        }
    }

    private func send(_ target: IPv4, ttl: Int32?, timeout: TimeInterval, continuation: CheckedContinuation<PingOutcome, Never>) {
        sequence &+= 1
        let seq = sequence
        if let existing = pending.removeValue(forKey: seq) {
            existing.timeout.cancel()
            existing.continuation.resume(returning: .timeout)
        }
        var hops = ttl ?? 64
        setsockopt(fd, IPPROTO_IP, IP_TTL, &hops, socklen_t(MemoryLayout<Int32>.size))

        let packet = ICMP.echoPacket(identifier: identifier, sequence: seq)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = target.value.bigEndian
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            continuation.resume(returning: .sendFailed(errno: errno))
            return
        }
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, let p = self.pending.removeValue(forKey: seq) else { return }
            p.continuation.resume(returning: .timeout)
        }
        pending[seq] = Pending(target: target, sentAt: DispatchTime.now().uptimeNanoseconds, continuation: continuation, timeout: expiry)
        queue.asyncAfter(deadline: .now() + timeout, execute: expiry)
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &fromLen)
                    }
                }
            }
            if n <= 0 { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let responder = IPv4(UInt32(bigEndian: from.sin_addr.s_addr))
            // Anyone who sees our pings can guess identifier and sequence, so a
            // reply also has to come from, or quote, the address we pinged.
            guard let response = ICMP.parse(Array(buffer[0..<n])),
                  response.identifier == identifier,
                  let p = pending[response.sequence],
                  response.kind == .reply ? responder == p.target : response.quotedDestination == p.target
            else { continue }
            pending[response.sequence] = nil
            p.timeout.cancel()
            let ms = Double(now - p.sentAt) / 1_000_000
            switch response.kind {
            case .reply: p.continuation.resume(returning: .reply(ms: ms, from: responder))
            case .timeExceeded: p.continuation.resume(returning: .timeExceeded(ms: ms, from: responder))
            case .unreachable: p.continuation.resume(returning: .unreachable(from: responder))
            }
        }
    }
}
