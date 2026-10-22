import Foundation
import Darwin

// Real ICMP echo ("ping"), like `ping 1.1.1.1` in a terminal. Darwin lets ordinary apps open SOCK_DGRAM
// ICMP sockets (no root, no entitlement; Apple's SimplePing sample does the same). One 8-byte ping a second,
// alternating Cloudflare and Google so neither one's outage, or a router hijacking 1.1.1.1, looks like ours.
final class Pinger: @unchecked Sendable {   // all state is touched on `queue` only
    /// Round-trip time of each reply, delivered on the pinger's queue.
    var onReply: ((TimeInterval) -> Void)?
    /// Once a second after each send, on the pinger's queue.
    var onTick: (() -> Void)?

    private static let targets = ["1.1.1.1", "8.8.8.8"]
    private let queue = DispatchQueue(label: "y99.ping")
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var seq: UInt16 = 0
    private var sentAt: [UInt16: Date] = [:]
    private let ident = UInt16.random(in: 1...UInt16.max)

    func start() { queue.async { self.begin() } }
    func stop() { queue.async { self.end() } }

    private func begin() {
        guard timer == nil else { return }
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        if fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let socket = fd
            r.setEventHandler { [weak self] in self?.receive() }
            r.setCancelHandler { close(socket) }
            r.resume()
            reader = r
        } else {
            DebugLog.log("ping: no ICMP socket (\(errno))")
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func end() {
        timer?.cancel(); timer = nil
        reader?.cancel(); reader = nil   // closes the socket
        fd = -1
        sentAt.removeAll()
    }

    private func tick() {
        let now = Date()
        sentAt = sentAt.filter { now.timeIntervalSince($0.value) < 10 }
        if fd >= 0 {
            seq &+= 1
            send(to: Self.targets[Int(seq) % Self.targets.count], seq: seq)
            sentAt[seq] = now
        }
        onTick?()
    }

    // Echo request: type 8, code 0, checksum, identifier, sequence, then 8 bytes of payload.
    private func send(to ip: String, seq: UInt16) {
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        packet[4] = UInt8(ident >> 8); packet[5] = UInt8(ident & 0xff)
        packet[6] = UInt8(seq >> 8); packet[7] = UInt8(seq & 0xff)
        let sum = Self.checksum(packet)
        packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xff)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 1500)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return }
            // Darwin hands datagram ICMP sockets the IPv4 header too; skip it when present.
            let start = buf[0] >> 4 == 4 ? Int(buf[0] & 0x0f) * 4 : 0
            guard n >= start + 8, buf[start] == 0 else { continue }   // type 0: echo reply
            let s = UInt16(buf[start + 6]) << 8 | UInt16(buf[start + 7])
            if let t = sentAt.removeValue(forKey: s) { onReply?(Date().timeIntervalSince(t)) }
        }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[i]) << 8 | UInt32(i + 1 < bytes.count ? bytes[i + 1] : 0)
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
