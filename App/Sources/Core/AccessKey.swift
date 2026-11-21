import Foundation

/// One text a person can send or show as a QR code: `ipbrowser://add?...` carrying the server's
/// name, its exit address and its share links. Plain `hy2://` and `vless://` links (one per line)
/// are accepted as well.
///
/// Only masked kinds are accepted, the two the server installer sets up: Hysteria 2 with
/// Salamander obfuscation, and VLESS Encryption over XHTTP behind TLS. A plain Hysteria 2 or VLESS
/// link is refused with its reason: its traffic is recognisable on the wire.
enum AccessKey {
    enum Problem: LocalizedError, Equatable {
        case invalid
        case unmasked(String)

        var errorDescription: String? {
            switch self {
            case .invalid: return L("key.invalid")
            case .unmasked: return L("key.unmasked")
            }
        }
    }

    static func encode(name: String, exit: String?, links: [String]) -> String {
        var c = URLComponents()
        c.scheme = "ipbrowser"
        c.host = "add"
        let blob = Data(links.joined(separator: "\n").utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        c.queryItems =
            [URLQueryItem(name: "n", value: name), URLQueryItem(name: "l", value: blob)]
            + (exit.map { [URLQueryItem(name: "ip", value: $0)] } ?? [])
        return c.string ?? ""
    }

    /// The links and the named exit of a key, before the core looks at them (unit-tested).
    static func parse(_ text: String) throws -> (name: String?, exit: String?, links: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ipbrowser://") {
            guard let c = URLComponents(string: trimmed) else { throw Problem.invalid }
            let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            var b64 = (q["l"] ?? "").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64), let joined = String(data: data, encoding: .utf8) else {
                throw Problem.invalid
            }
            let links = joined.split(separator: "\n").map(String.init)
            guard !links.isEmpty else { throw Problem.invalid }
            try requireMasked(links)
            let name = (q["n"] ?? "").replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
            let exit = q["ip"].flatMap { $0.isEmpty ? nil : $0 }
            return (name.isEmpty ? nil : name, exit, links)
        }
        let links = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("hy2://") || $0.hasPrefix("hysteria2://") || $0.hasPrefix("vless://") }
        guard !links.isEmpty else { throw Problem.invalid }
        try requireMasked(links)
        return (links.first.flatMap { Link($0)?.fragment }, nil, links)
    }

    /// A key as a profile: parsed, masked, and every link buildable by the core itself.
    static func decode(_ text: String) throws -> ServerProfile {
        let key = try parse(text)
        try XrayEngine.validate(links: key.links)
        return ServerProfile(
            name: key.name ?? L("server.default"), links: key.links, exitIPv4: key.exit,
            origin: .imported)
    }

    /// The parts of a share link this check needs. Not URLComponents: a HOP link's port is a list
    /// with a range (`host:443,20000-29999`), which is not a URL port.
    struct Link {
        let scheme: String
        let query: [String: String]
        let fragment: String?

        init?(_ text: String) {
            guard let schemeEnd = text.range(of: "://") else { return nil }
            scheme = text[..<schemeEnd.lowerBound].lowercased()
            var rest = Substring(text[schemeEnd.upperBound...])
            if let hash = rest.firstIndex(of: "#") {
                fragment = String(rest[rest.index(after: hash)...]).removingPercentEncoding
                rest = rest[..<hash]
            } else {
                fragment = nil
            }
            var query: [String: String] = [:]
            if let mark = rest.firstIndex(of: "?") {
                for pair in rest[rest.index(after: mark)...].split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    let name = (parts[0].removingPercentEncoding ?? parts[0]).lowercased()
                    let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
                    if query[name] == nil { query[name] = value }
                }
            }
            self.query = query
        }
    }

    /// Every link must be one of the masked kinds.
    static func requireMasked(_ links: [String]) throws {
        for link in links {
            guard let parsed = Link(link) else { throw Problem.invalid }
            let q = parsed.query
            switch parsed.scheme {
            case "hy2", "hysteria2":
                guard q["obfs"]?.lowercased() == "salamander", !(q["obfs-password"] ?? "").isEmpty else {
                    throw Problem.unmasked("hop")
                }
            case "vless":
                let encryption = (q["encryption"] ?? "").lowercased()
                guard q["type"]?.lowercased() == "xhttp", q["security"]?.lowercased() == "tls" else {
                    throw Problem.unmasked("xhttp")
                }
                guard !encryption.isEmpty, encryption != "none" else {
                    throw Problem.unmasked("encryption")
                }
            default:
                throw Problem.invalid
            }
        }
    }
}
