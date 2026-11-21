import Foundation

/// An IPv4 address held in host byte order.
public struct IPv4: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init?(_ text: String) {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            v = v << 8 | UInt32(octet)
        }
        value = v
    }

    public var description: String {
        "\(value >> 24).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }

    /// RFC 1918 private space and link-local: addresses inside someone's home or office.
    public var isPrivate: Bool {
        let a = value >> 24, b = value >> 16 & 0xff
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
    }

    public static func < (l: IPv4, r: IPv4) -> Bool { l.value < r.value }
}

/// Builds and parses ICMP echo packets for an unprivileged SOCK_DGRAM ICMP
/// socket. macOS hands such sockets the full IP datagram on receive.
public enum ICMP {
    public static let echoRequest: UInt8 = 8
    public static let echoReply: UInt8 = 0
    public static let destinationUnreachable: UInt8 = 3
    public static let timeExceeded: UInt8 = 11

    public static func echoPacket(identifier: UInt16, sequence: UInt16, payloadSize: Int = 16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 8 + payloadSize)
        p[0] = echoRequest
        p[4] = UInt8(identifier >> 8); p[5] = UInt8(identifier & 0xff)
        p[6] = UInt8(sequence >> 8); p[7] = UInt8(sequence & 0xff)
        for i in 0..<payloadSize { p[8 + i] = UInt8(truncatingIfNeeded: 0x61 + i) }
        let sum = checksum(p)
        p[2] = UInt8(sum >> 8); p[3] = UInt8(sum & 0xff)
        return p
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    public enum Kind: Equatable, Sendable {
        case reply
        case timeExceeded
        case unreachable
    }

    /// The echo request a received datagram answers, identified by the
    /// identifier and sequence it carries (directly, or quoted inside an error).
    public struct Response: Equatable, Sendable {
        public let kind: Kind
        public let identifier: UInt16
        public let sequence: UInt16
        /// For errors, where our original request was headed.
        public var quotedDestination: IPv4? = nil
    }

    public static func parse(_ d: [UInt8]) -> Response? {
        var icmp = d[...]
        if let first = d.first, first >> 4 == 4 {
            let ipHeader = Int(first & 0x0f) * 4
            guard d.count >= ipHeader + 8 else { return nil }
            icmp = d[(d.startIndex + ipHeader)...]
        }
        guard icmp.count >= 8 else { return nil }
        let b = Array(icmp)
        func u16(_ a: [UInt8], _ i: Int) -> UInt16 { UInt16(a[i]) << 8 | UInt16(a[i + 1]) }
        switch b[0] {
        case echoReply:
            return Response(kind: .reply, identifier: u16(b, 4), sequence: u16(b, 6))
        case timeExceeded, destinationUnreachable:
            // Quoted original: IP header, then the first 8 bytes of our echo request.
            let quoted = Array(b[8...])
            guard let q0 = quoted.first, q0 >> 4 == 4 else { return nil }
            let qIP = Int(q0 & 0x0f) * 4
            guard qIP >= 20, quoted.count >= qIP + 8, quoted[qIP] == echoRequest else { return nil }
            let kind: Kind = b[0] == timeExceeded ? .timeExceeded : .unreachable
            let destination = IPv4(UInt32(quoted[16]) << 24 | UInt32(quoted[17]) << 16 | UInt32(quoted[18]) << 8 | UInt32(quoted[19]))
            return Response(kind: kind, identifier: u16(quoted, qIP + 4), sequence: u16(quoted, qIP + 6),
                            quotedDestination: destination)
        default:
            return nil
        }
    }
}
