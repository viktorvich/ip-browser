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
    private let service = "app.ipbrowser.profiles"
    private let account = "v1"
    private let activeKey = "activeProfile"

    private(set) var profiles: [ServerProfile] = []
    var activeID: UUID? {
        get { UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: activeKey) }
    }
    var active: ServerProfile? { profiles.first { $0.id == activeID } ?? profiles.first }

    init() {
        // iOS keeps Keychain items after an app is deleted; UserDefaults go with it.
        // A reinstalled app starts clean, as a person expects after «Delete App».
        if !UserDefaults.standard.bool(forKey: "installMarker") {
            SecItemDelete(query as CFDictionary)
            UserDefaults.standard.set(true, forKey: "installMarker")
        }
        // One entry per key: older builds could store the same key twice.
        var seen = Set<Set<String>>()
        profiles = ((try? load()) ?? []).filter { seen.insert(Set($0.links)).inserted }
        // Build 17: every profile became a separate browser. The profile in use until now
        // keeps the old shared website data, favourites and history; the others start clean.
        if !UserDefaults.standard.bool(forKey: "profilesSeparate") {
            if var a = active, !profiles.contains(where: { $0.storeID == Self.legacyStoreID }) {
                a.storeID = Self.legacyStoreID
                if (try? upsert(a)) != nil { BrowserLibrary.adoptLegacy(into: a.id) }
            }
            UserDefaults.standard.set(true, forKey: "profilesSeparate")
        }
    }

    /// Ask the browser to switch to a profile (pages, data and tunnel together).
    static func requestSwitch(to id: UUID) { NotificationCenter.default.post(name: switchRequest, object: id) }

    /// The profile a new key or installation belongs to: the same links, or the same exit
    /// address (one exit = one profile: a new key for it — new passwords, another kind —
    /// updates that profile, whose sign-ins and website data stay).
    func existing(for profile: ServerProfile) -> ServerProfile? {
        profiles.first { $0.id == profile.id }
            ?? profiles.first { Set($0.links) == Set(profile.links) }
            ?? profile.exitIPv4.flatMap { exit in profiles.first { $0.exitIPv4 == exit } }
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
