import Foundation
import Network

/// One server = one exit address = one browser profile. Every outbound of a profile ends
/// on the same machine, so switching between its masked kinds never changes the exit IP.
/// Each profile is a separate browser like a Safari profile: its own website data
/// (cookies, storage, caches, service workers), tabs, favourites and history, its own
/// clock (the exit's time zone). Only the active profile has pages and a tunnel.
struct ServerProfile: Codable, Identifiable, Equatable {
    enum Origin: String, Codable { case installed, imported }

    var id = UUID()
    var name: String
    /// Share links (hy2:// = HOP, vless:// = XHTTP fallback). They contain
    /// credentials, so the whole profile list lives only in the Keychain.
    var links: [String]
    /// The exit address the browser must see before any website opens.
    /// Installed servers report it; imported keys pin the first verified one.
    var exitIPv4: String?
    var origin: Origin
    var created = Date()
    /// Management access for servers this app installed (SSH host, port,
    /// user, pinned host key, the app's own key). Nil for imported keys.
    var management: Management?
    /// The WebKit website data store of this profile (nil = the profile's own id). The
    /// profile that was active when profiles became separate keeps the old shared store,
    /// so its logins stay where the person left them.
    var storeID: UUID?

    var dataStoreID: UUID { storeID ?? id }

    /// What the profile bar shows: the person's own name, or the exit's country when the
    /// name is only an address («Финляндия», «Латвия»).
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let bare =
            trimmed.isEmpty || IPv4Address(trimmed) != nil || trimmed == management?.host
            || trimmed == L("server.default")
        if bare, let code = Region.shared.knownCountry(for: exitIPv4),
            let country = Locale.current.localizedString(forRegionCode: code)
        {
            return country
        }
        return trimmed.isEmpty ? L("server.default") : trimmed
    }

    /// The exit country's flag, or nil while the country is not known.
    var flag: String? { Region.flag(Region.shared.knownCountry(for: exitIPv4)) }

    struct Management: Codable, Equatable {
        var host: String
        var port: Int
        var user: String
        var hostKey: String  // OpenSSH public host key, pinned on first install
        var privateKeyPEM: String  // the app's own ed25519 key, added to authorized_keys
        var device: String  // this device's credential name on the server
    }

    var kinds: [String] {
        links.compactMap { link in
            if link.hasPrefix("hy2://") || link.hasPrefix("hysteria2://") { return "HOP" }
            if link.hasPrefix("vless://") { return "XHTTP" }
            return nil
        }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
