import Foundation
import Security

/// Profiles (with their credentials) are kept in the Keychain of this device
/// only: never iCloud, never a backup, never a file in the container.
final class ProfileStore {
    static let shared = ProfileStore()
    /// A profile was removed (object: the removed ServerProfile): its pages, website data,
    /// tabs, favourites and history go with it.
    static let removed = Notification.Name("ProfileStore.removed")
    /// Make this profile the active one (object: its UUID). The browser switches the pages,
    /// the website data and the tunnel together.
    static let switchRequest = Notification.Name("ProfileStore.switch")
    /// The WebKit store every page used before profiles were separate (build ≤ 16).
    static let legacyStoreID = UUID(uuidString: "5B0E8C1C-6B2E-4D57-9E0A-1F7A9C3D2B10")!
    private let service: String
    private let defaults: UserDefaults
    private let account = "v1"
    private let activeKey = "activeProfile"

    private(set) var profiles: [ServerProfile] = []
    var activeID: UUID? {
        get { defaults.string(forKey: activeKey).flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: activeKey) }
    }
    var active: ServerProfile? { profiles.first { $0.id == activeID } ?? profiles.first }

    init(service: String = "app.ipbrowser.profiles", defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        // iOS keeps Keychain items after an app is deleted; UserDefaults go with it.
        // A reinstalled app starts clean, as a person expects after «Delete App».
        if !defaults.bool(forKey: "installMarker") {
            SecItemDelete(query as CFDictionary)
            defaults.set(true, forKey: "installMarker")
        }
        // Browser identity is its UUID, never its credentials or exit address.
        // Explicit copies share a server but must survive a restart as separate browsers.
        var seen = Set<UUID>()
        profiles = ((try? load()) ?? []).filter { seen.insert($0.id).inserted }
        // Build 17: every profile became a separate browser. The profile in use until now
        // keeps the old shared website data, favourites and history; the others start clean.
        if !defaults.bool(forKey: "profilesSeparate") {
            if var a = active, !profiles.contains(where: { $0.storeID == Self.legacyStoreID }) {
                a.storeID = Self.legacyStoreID
                if (try? upsert(a)) != nil { BrowserLibrary.adoptLegacy(into: a.id) }
            }
            defaults.set(true, forKey: "profilesSeparate")
        }
    }

    /// Ask the browser to switch to a profile (pages, data and tunnel together).
    static func requestSwitch(to id: UUID) { NotificationCenter.default.post(name: switchRequest, object: id) }

    /// Import updates one profile, retaining its browser data. If there are copies on
    /// the same server, prefer the active matching profile; never merge their stores.
    func existing(for profile: ServerProfile) -> ServerProfile? {
        if let sameID = profiles.first(where: { $0.id == profile.id }) { return sameID }
        let exact = profiles.filter { Set($0.links) == Set(profile.links) }
        if !exact.isEmpty { return exact.first { $0.id == activeID } ?? exact.first }
        guard let exit = profile.exitIPv4 else { return nil }
        let sameExit = profiles.filter { $0.exitIPv4 == exit }
        return sameExit.first { $0.id == activeID } ?? sameExit.first
    }

    /// Adds or updates a profile (see existing(for:)); returns the stored profile.
    @discardableResult
    func upsert(_ profile: ServerProfile) throws -> ServerProfile {
        var list = profiles
        var stored = profile
        if let old = existing(for: profile), let i = list.firstIndex(where: { $0.id == old.id }) {
            if old.id != profile.id {
                stored.id = old.id
                stored.storeID = old.storeID
                stored.name = old.name  // the person's own name stays
                stored.created = old.created
                if stored.exitIPv4 == nil { stored.exitIPv4 = old.exitIPv4 }
                if stored.management == nil { stored.management = old.management }
            }
            list[i] = stored
        } else {
            list.append(profile)
        }
        try save(list)
        profiles = list
        return stored
    }

    /// Copy only server access, with a fresh browser identity. No website data, tabs,
    /// library, or SSH administration key is copied; deletion remains local to this copy.
    @discardableResult
    func duplicate(_ id: UUID) throws -> ServerProfile {
        guard let source = profiles.first(where: { $0.id == id }) else {
            throw AppError.message(L("profiles.missing"))
        }
        let base = String(format: L("profiles.copy.name"), source.title)
        var name = base
        var suffix = 2
        while profiles.contains(where: { $0.title == name }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        let copy = source.isolatedCopy(named: name)
        let list = profiles + [copy]
        try save(list)  // deliberately not upsert: equal credentials must not merge copies
        profiles = list
        return copy
    }

    func remove(_ id: UUID) throws {
        guard let gone = profiles.first(where: { $0.id == id }) else { return }
        let list = profiles.filter { $0.id != id }
        try save(list)
        profiles = list
        if activeID == id { activeID = list.first?.id }
        NotificationCenter.default.post(name: Self.removed, object: gone)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
        ]
    }

    private func load() throws -> [ServerProfile] {
        var read = query
        read[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = out as? Data else {
            throw AppError.message(L("keychain.read") + " (\(status))")
        }
        return try JSONDecoder().decode([ServerProfile].self, from: data)
    }

    private func save(_ list: [ServerProfile]) throws {
        let data = try JSONEncoder().encode(list)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw AppError.message(L("keychain.write") + " (\(status))") }
    }
}
