import Foundation
import LibXray

/// The in-app tunnel core (Xray-core through libXray, both MIT/MPL-2.0).
/// It runs inside this app's process, not as a system VPN: only this browser's
/// connections enter it. The generated configuration has NO direct (freedom)
/// outbound: a destination can leave only through the profile's server, or it
/// is dropped. That is the kill switch by construction, not a toggle.
enum XrayEngine {
    /// One loopback door per masked kind of the profile (all with the same credential), each
    /// routed only to its own kind. There is no shared door and no balancer inside the core:
    /// LocalGate lets pages through a door only after that door's own exit was verified, so
    /// every kind is proven to leave from the profile's address before it carries a page.
    struct Door: Equatable {
        let kind: String
        let port: Int
    }
    struct Running {
        let doors: [Door]
        let user: String
        let password: String
        var authorization: String { "Basic " + Data("\(user):\(password)".utf8).base64EncodedString() }
    }

    private static let queue = DispatchQueue(label: "app.ipbrowser.xray")
    private(set) static var current: Running?

    /// Private, reserved and local destinations never leave the phone, even if a
    /// page names them by address. Hostnames are resolved by the server only.
    static let blockedCIDRs = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15",
        "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4", "::/0",
    ]

    #if DEBUG
    static let logLevel = "debug"
    #else
    static let logLevel = "warning"
    #endif

    static func invoke(_ method: String, _ payload: [String: Any]? = nil) throws -> Any? {
        var request: [String: Any] = ["apiVersion": 3, "method": method]
        if let payload { request["payload"] = payload }
        let text = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let reply = LibXrayInvoke(text)
        guard let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
            throw AppError.message("core: invalid reply")
        }
        guard object["success"] as? Bool == true else {
            throw AppError.message((object["error"] as? String) ?? "core error")
        }
        return object["data"]
    }

    static var version: String {
        ((try? invoke("xrayVersion")) as? [String: Any])?["version"] as? String ?? "?"
    }

    /// Share links -> Xray outbounds (libXray's own parser; it refuses insecure TLS).
    static func outbounds(for links: [String]) throws -> [[String: Any]] {
        guard
            let data = try invoke("convertShareLinksToXrayJson", ["text": links.joined(separator: "\n")])
                as? [String: Any],
            let list = data["outbounds"] as? [[String: Any]], !list.isEmpty
        else {
            throw AppError.message(L("key.invalid"))
        }
        return list
    }

    static func kind(of link: String) -> String { link.hasPrefix("vless://") ? "XHTTP (TCP)" : "HOP (UDP)" }

    static func configuration(links: [String], user: String, password: String, doorPorts: [Int]) throws -> String {
        // On an IPv6-only network the server's IPv4 address is dialed through its synthesized IPv6 (NAT64).
        var outbounds = try outbounds(for: links).map { NAT64.rewrite($0, resolve: NAT64.address(for:)) }
        guard doorPorts.count == outbounds.count else { throw AppError.message("core: no free port") }
        var tags: [String] = []
        for i in outbounds.indices {
            let tag = "exit\(i)"
            outbounds[i]["tag"] = tag
            tags.append(tag)
            // HOP on a phone: keep the carrier's UDP NAT mapping alive and notice a dead path
            // quickly (the client keeps one QUIC connection and does not migrate it when the
            // phone changes networks; by default it has no keep-alive and a 30 s idle timeout).
            if outbounds[i]["protocol"] as? String == "hysteria",
                var stream = outbounds[i]["streamSettings"] as? [String: Any]
            {
                var mask = stream["finalmask"] as? [String: Any] ?? [:]
                var quic = mask["quicParams"] as? [String: Any] ?? [:]
                quic["keepAlivePeriod"] = quic["keepAlivePeriod"] ?? 10
                quic["maxIdleTimeout"] = quic["maxIdleTimeout"] ?? 20
                mask["quicParams"] = quic
                stream["finalmask"] = mask
                outbounds[i]["streamSettings"] = stream
            }
        }
        outbounds.append(["tag": "block", "protocol": "blackhole", "settings": [:]])
        var rules: [[String: Any]] = [
            ["type": "field", "ip": blockedCIDRs, "outboundTag": "block"],
            ["type": "field", "port": "25", "outboundTag": "block"],
            ["type": "field", "network": "udp", "outboundTag": "block"],
        ]
        var inbounds: [[String: Any]] = []
        for (i, port) in doorPorts.enumerated() {
            inbounds.append([
                "tag": "door\(i)", "listen": "127.0.0.1", "port": port, "protocol": "http",
                "settings": ["accounts": [["user": user, "pass": password]], "allowTransparent": false],
                "sniffing": ["enabled": false],
            ])
            rules.append(["type": "field", "inboundTag": ["door\(i)"], "outboundTag": tags[i]])
        }
        let config: [String: Any] = [
            "log": ["loglevel": logLevel, "access": "none", "dnsLog": false],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "AsIs", "rules": rules],
            "policy": ["levels": ["0": ["handshake": 8, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5]]],
        ]
        // No "dns" block, no freedom outbound, no observatory pinging third parties: the phone
        // resolves nothing for websites and the core talks only to the profile's server.
        return String(
            data: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), encoding: .utf8)!
    }

    /// libXray's own parser must turn every link into a buildable outbound. (Its
    /// testXray is meant for a separate process and refuses inside the app.)
    static func validate(links: [String]) throws {
        let parsed = try outbounds(for: links)
        guard parsed.count == links.count else { throw AppError.message(L("key.invalid")) }
    }

    static func start(links: [String], completion: @escaping (Result<Running, Error>) -> Void) {
        queue.async {
            do {
                _ = try? invoke("stopXray")
                current = nil
                guard
                    let ports = (try invoke("getFreePorts", ["count": links.count]) as? [String: Any])?["ports"]
                        as? [Int],
                    ports.count == links.count
                else { throw AppError.message("core: no free port") }
                let user = "g" + UUID().uuidString.prefix(8).lowercased()
                let password = UUID().uuidString + UUID().uuidString
                let json = try configuration(links: links, user: user, password: password, doorPorts: ports)
                _ = try invoke("runXray", ["xrayJson": json])
                let running = Running(
                    doors: zip(links, ports).map { Door(kind: kind(of: $0.0), port: $0.1) }, user: user,
                    password: password)
                current = running
                DispatchQueue.main.async { completion(.success(running)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    static func stop() {
        queue.sync {
            _ = try? invoke("stopXray")
            current = nil
        }
    }
}
