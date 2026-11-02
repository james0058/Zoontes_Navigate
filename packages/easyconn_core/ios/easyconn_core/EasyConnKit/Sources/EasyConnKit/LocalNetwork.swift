import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What the phone's own Wi-Fi interface looks like, so we can find the dash instead of guessing its address.
public enum LocalNetwork {
    public struct Wifi: Equatable {
        public var interface: String
        public var ip: String
        public var mask: String
        /// Network address + 1: how every dash seen so far (and most routers) numbers its gateway.
        public var gatewayGuess: String
    }

    /// The first IPv4 address on a Wi-Fi style interface (en0 on iPhones; en* on a Mac for tests).
    public static func wifi() -> Wifi? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let maskPtr = cur.pointee.ifa_netmask,
                  cur.pointee.ifa_flags & UInt32(IFF_UP) != 0, cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name == "en0" else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return Wifi(interface: name, ip: dotted(ip), mask: dotted(mask), gatewayGuess: dotted((ip & mask) | 1))
        }
        return nil
    }

    static func dotted(_ v: UInt32) -> String { "\((v >> 24) & 255).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }

    /// Addresses to try for the dash, most likely first: an address typed in by the rider, this network's .1,
    /// then the defaults seen so far (192.168.3.1 reported on a Zontes 368 dash, plain AP 192.168.0.1,
    /// Wi-Fi Direct group 192.168.49.1).
    public static func probeCandidates(explicit: String?, wifi: Wifi?) -> [String] {
        var out = [String]()
        for c in [explicit, wifi?.gatewayGuess, "192.168.3.1", "192.168.0.1", "192.168.49.1"] {
            if let c, !out.contains(c) { out.append(c) }
        }
        return out
    }
}
