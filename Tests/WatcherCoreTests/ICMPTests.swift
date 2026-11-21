import Testing
@testable import WatcherCore

struct ICMPTests {
    @Test func echoPacketChecksumVerifies() {
        let p = ICMP.echoPacket(identifier: 0x1234, sequence: 7)
        #expect(ICMP.checksum(p) == 0)
    }

    @Test func parsesReplyBehindIPHeader() {
        var reply = ICMP.echoPacket(identifier: 0xBEEF, sequence: 42)
        reply[0] = ICMP.echoReply
        let datagram = ipHeader() + reply
        #expect(ICMP.parse(datagram) == .init(kind: .reply, identifier: 0xBEEF, sequence: 42))
    }

    @Test func parsesTimeExceededQuotingOurRequest() {
        var quotedHeader = ipHeader()
        quotedHeader[16...19] = [1, 1, 1, 1]
        let original = quotedHeader + Array(ICMP.echoPacket(identifier: 0xBEEF, sequence: 3).prefix(8))
        let error: [UInt8] = [ICMP.timeExceeded, 0, 0, 0, 0, 0, 0, 0] + original
        #expect(ICMP.parse(ipHeader() + error)
            == .init(kind: .timeExceeded, identifier: 0xBEEF, sequence: 3, quotedDestination: IPv4("1.1.1.1")))
    }

    @Test func rejectsQuotedHeaderTooShortToHoldADestination() {
        let quoted: [UInt8] = [0x40, 0, 0, 0, 0, 0, 0, 0] + Array(ICMP.echoPacket(identifier: 1, sequence: 1).prefix(8))
        #expect(ICMP.parse(ipHeader() + [ICMP.timeExceeded, 0, 0, 0, 0, 0, 0, 0] + quoted) == nil)
    }

    @Test func ignoresOtherICMP() {
        #expect(ICMP.parse(ipHeader() + [5, 0, 0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test func classifiesPrivateAddresses() {
        #expect(IPv4("192.168.4.1")!.isPrivate)
        #expect(IPv4("172.16.0.1")!.isPrivate)
        #expect(!IPv4("172.15.0.1")!.isPrivate)
        #expect(!IPv4("1.1.1.1")!.isPrivate)
        #expect(IPv4("10.0.0.1")!.description == "10.0.0.1")
    }

    private func ipHeader() -> [UInt8] { [0x45] + [UInt8](repeating: 0, count: 19) }
}
