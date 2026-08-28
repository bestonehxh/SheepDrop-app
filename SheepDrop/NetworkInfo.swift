import Foundation

nonisolated enum LocalNetwork {
    /// The local IPv4 the kernel would use to reach `host` — a connected UDP
    /// socket picks the outgoing interface without sending a packet. This is
    /// the address that belongs in device-side copy commands; en0's address
    /// is useless to a switch on a different lab subnet.
    static func ipv4(toReach host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "69", &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        guard Darwin.connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            return nil
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length) == 0
            }
        }
        guard ok else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = local.sin_addr
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        let ip = String(cString: buffer)
        return ip == "0.0.0.0" ? nil : ip
    }

    /// Best-effort primary IPv4 (en0 first) for building device-side commands.
    static func primaryIPv4() -> String? {
        var addresses: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            // getifaddrs may return entries with a NULL ifa_addr (e.g. some
            // tunnel interfaces) — dereferencing one crashes.
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") {
                    addresses.append((name, ip))
                }
            }
        }
        return (addresses.first { $0.name == "en0" } ?? addresses.first)?.ip
    }
}
