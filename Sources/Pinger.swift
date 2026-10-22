import Foundation
import Darwin

// Real ICMP echo ("ping"), like `ping 1.1.1.1` in a terminal. Darwin lets ordinary apps open SOCK_DGRAM
// ICMP sockets (no root, no entitlement; Apple's SimplePing sample does the same). One 8-byte ping a second,
// alternating Cloudflare and Google so neither one's outage, or a router hijacking 1.1.1.1, looks like ours.
final class Pinger: @unchecked Sendable {   // all state is touched on `queue` only
    /// Each ping's outcome, on the pinger's queue: its number and round-trip time, or nil when no reply
    /// came within `timeout` (a reply after that is ignored). Pings go out every second regardless.
    var onResult: ((_ seq: Int, _ rtt: TimeInterval?) -> Void)?
    static let timeout: TimeInterval = 1

    private static let targets = ["1.1.1.1", "8.8.8.8"]
    private let queue = DispatchQueue(label: "y99.ping")
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var count = 0                       // pings sent since start; the wire carries its low 16 bits
    private var sentAt: [UInt16: (count: Int, at: Date)] = [:]
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
        count = 0
    }

    private func tick() {
        guard fd >= 0 else { return }
        let n = count
        count += 1
        let seq = UInt16(truncatingIfNeeded: n)
        sentAt[seq] = (n, Date())
        send(to: Self.targets[n % Self.targets.count], seq: seq)
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, let sent = self.sentAt[seq], sent.count == n else { return }
            self.sentAt[seq] = nil
            self.onResult?(n, nil)
        }
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
            if let sent = sentAt.removeValue(forKey: s) { onResult?(sent.count, Date().timeIntervalSince(sent.at)) }
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
