import Foundation

/// IPv6-only networks with NAT64/DNS64 (some carriers; the network App Review uses). The tunnel core and
/// the SSH client dial literal addresses themselves, and an IPv4 literal has no route there. As Apple
/// documents («Supporting IPv6-only Networks»), getaddrinfo with AI_DEFAULT turns an IPv4 literal into the
/// IPv6 address this network synthesizes for it; on any other network it returns the IPv4 address itself,
/// and nothing changes. The TLS name and the exit the browser expects stay the IPv4 address.
enum NAT64 {
    /// The address to dial for `host` on the current network: the synthesized IPv6 address when this network
    /// has no IPv4 route, otherwise nil (dial `host` as it is). Only IPv4 literals are looked at.
    static func address(for host: String) -> String? {
        guard IPv4Literal.isValid(host) else { return nil }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_DEFAULT
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var v6: String?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if info.pointee.ai_family == AF_INET { return nil }  // an IPv4 route exists: dial as it is
            if info.pointee.ai_family == AF_INET6, v6 == nil, let sockaddr = info.pointee.ai_addr {
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var address = sin6.pointee.sin6_addr
                    _ = inet_ntop(AF_INET6, &address, &text, socklen_t(INET6_ADDRSTRLEN))
                }
                v6 = String(cString: text)
            }
            cursor = info.pointee.ai_next
        }
        return v6
    }

    /// One core outbound with every IPv4 literal it dials (`address`, the hop list `remoteIPs`) replaced
    /// by what `resolve` gives for it; the TLS name is kept (set to the original address if it was empty),
    /// so the server's certificate is checked against the same name as on any network.
    static func rewrite(_ outbound: [String: Any], resolve: (String) -> String?) -> [String: Any] {
        var original: String?
        func walk(_ value: Any, key: String) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (k, v) in dict { out[k] = walk(v, key: k) }
                return out
            }
            if let list = value as? [Any] {
                return list.map { item -> Any in
                    if key == "remoteIPs", let ip = item as? String { return resolve(ip) ?? ip }
                    return walk(item, key: "")
                }
            }
            if key == "address", let ip = value as? String, IPv4Literal.isValid(ip), let v6 = resolve(ip) {
                original = original ?? ip
                return v6
            }
            return value
        }
        guard var out = walk(outbound, key: "") as? [String: Any] else { return outbound }
        if let original, var stream = out["streamSettings"] as? [String: Any], stream["security"] as? String == "tls" {
            var tls = stream["tlsSettings"] as? [String: Any] ?? [:]
            if (tls["serverName"] as? String ?? "").isEmpty { tls["serverName"] = original }
            stream["tlsSettings"] = tls
            out["streamSettings"] = stream
        }
        return out
    }
}

enum IPv4Literal {
    static func isValid(_ text: String) -> Bool {
        var address = in_addr()
        return text.split(separator: ".").count == 4 && inet_pton(AF_INET, text, &address) == 1
    }
}
