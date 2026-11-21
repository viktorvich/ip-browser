import Foundation
import SwiftUI

/// Favourites, history and open tabs of ONE profile, kept only on this device
/// (Application Support/Library/<profile>), never synced. Profiles never share them.
final class BrowserLibrary: ObservableObject {
    /// The library of the active profile (the browser sets it when it switches).
    private static let none = BrowserLibrary(folder: base.appendingPathComponent("none", isDirectory: true))
    private(set) static var shared = none
    private static var opened: [UUID: BrowserLibrary] = [:]

    struct Favorite: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var url: URL
    }
    struct Visit: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var url: URL
        var date: Date
    }
    /// The tabs a profile had open when the person switched away (or the app went to the background).
    struct Tabs: Codable {
        var urls: [URL?]
        var selected: Int
    }

    @Published private(set) var favorites: [Favorite] = []
    @Published private(set) var history: [Visit] = []

    private static let base: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private let folder: URL
    private var favoritesFile: URL { folder.appendingPathComponent("favorites.json") }
    private var historyFile: URL { folder.appendingPathComponent("history.json") }
    private var tabsFile: URL { folder.appendingPathComponent("tabs.json") }

    /// The library of a profile (one instance per profile per app run).
    static func of(_ profile: UUID) -> BrowserLibrary {
        if let l = opened[profile] { return l }
        let l = BrowserLibrary(folder: base.appendingPathComponent(profile.uuidString, isDirectory: true))
        opened[profile] = l
        return l
    }
    static func activate(_ profile: UUID) { shared = of(profile) }
    /// No server yet: the start page's own favourites.
    static func deactivate() { shared = none }

    /// A removed profile: its favourites, history and tabs are deleted.
    static func forget(_ profile: UUID) {
        opened[profile] = nil
        try? FileManager.default.removeItem(at: base.appendingPathComponent(profile.uuidString, isDirectory: true))
    }

    /// Build ≤ 16 kept one library for all servers: it becomes the library of the profile in use.
    static func adoptLegacy(into profile: UUID) {
        let fm = FileManager.default
        let dest = base.appendingPathComponent(profile.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in ["favorites.json", "history.json"] {
            let from = base.appendingPathComponent(name)
            let to = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
        }
    }

    private init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: favoritesFile),
            let list = try? JSONDecoder().decode([Favorite].self, from: data)
        {
            favorites = list
        } else {
            favorites = Self.defaults
            save()
        }
        if let data = try? Data(contentsOf: historyFile), let list = try? JSONDecoder().decode([Visit].self, from: data)
        {
            history = list
        }
    }

    var savedTabs: Tabs? {
        (try? Data(contentsOf: tabsFile)).flatMap { try? JSONDecoder().decode(Tabs.self, from: $0) }
    }
    func saveTabs(_ tabs: Tabs) {
        if let d = try? JSONEncoder().encode(tabs) { try? d.write(to: tabsFile, options: .completeFileProtection) }
    }

    private static var defaults: [Favorite] {
        let ru = Locale.current.language.languageCode?.identifier == "ru"
        let list: [(String, String)] = [
            ("Google", "https://www.google.com"), ("YouTube", "https://m.youtube.com"),
            (ru ? "Википедия" : "Wikipedia", ru ? "https://ru.m.wikipedia.org" : "https://en.m.wikipedia.org"),
            ("Gmail", "https://mail.google.com"), ("ChatGPT", "https://chatgpt.com"), ("Claude", "https://claude.ai"),
            ("GitHub", "https://github.com"), ("DuckDuckGo", "https://duckduckgo.com"),
        ]
        return list.compactMap { t, u in URL(string: u).map { Favorite(title: t, url: $0) } }
    }

    func isFavorite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return favorites.contains { Self.same($0.url, url) }
    }

    func toggleFavorite(title: String, url: URL) {
        if let i = favorites.firstIndex(where: { Self.same($0.url, url) }) {
            favorites.remove(at: i)
        } else {
            favorites.append(Favorite(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url))
        }
        save()
    }
    func removeFavorites(_ ids: Set<UUID>) {
        favorites.removeAll { ids.contains($0.id) }
        save()
    }
    func moveFavorites(from: IndexSet, to: Int) {
        favorites.move(fromOffsets: from, toOffset: to)
        save()
    }
    func rename(_ id: UUID, to title: String) {
        guard let i = favorites.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        favorites[i].title = title
        save()
    }

    func recordVisit(title: String, url: URL) {
        guard ["http", "https"].contains(url.scheme ?? ""), url.host != "selftest.ipbrowser.invalid" else { return }
        if let first = history.first, Self.same(first.url, url) {
            history[0].title = title.isEmpty ? first.title : title
            history[0].date = Date()
        } else {
            history.insert(
                Visit(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url, date: Date()), at: 0)
            if history.count > 3000 { history.removeLast(history.count - 3000) }
        }
        saveHistory()
    }
    func removeVisits(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        saveHistory()
    }
    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    /// The few sites the person opened lately (one per host), for the start page.
    var recent: [Visit] {
        var seen = Set<String>()
        var out: [Visit] = []
        for v in history where !seen.contains(v.url.host ?? "") && !isFavorite(v.url) {
            seen.insert(v.url.host ?? "")
            out.append(v)
            if out.count == 6 { break }
        }
        return out
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String { (u.host ?? "") + (u.path.isEmpty ? "/" : u.path) + "?" + (u.query ?? "") }
        return key(a) == key(b)
    }
    private func save() {
        if let d = try? JSONEncoder().encode(favorites) {
            try? d.write(to: favoritesFile, options: .completeFileProtection)
        }
    }
    private func saveHistory() {
        if let d = try? JSONEncoder().encode(history) {
            try? d.write(to: historyFile, options: .completeFileProtection)
        }
    }
}

/// A site's tile: its first letter on a colour derived from the host. No icon is
/// fetched — that would be a request outside the person's browsing.
struct SiteTile: View {
    let title: String
    let url: URL
    var size: CGFloat = 60

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.47, blue: 0.95), Color(red: 0.93, green: 0.30, blue: 0.27),
        Color(red: 0.16, green: 0.66, blue: 0.47),
        Color(red: 0.98, green: 0.60, blue: 0.13), Color(red: 0.55, green: 0.36, blue: 0.95),
        Color(red: 0.10, green: 0.62, blue: 0.75),
        Color(red: 0.85, green: 0.29, blue: 0.60), Color(red: 0.40, green: 0.45, blue: 0.52),
    ]
    var body: some View {
        let host =
            url.host?.replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "m.", with: "") ?? title
        let letter = String((title.first ?? host.first ?? "•")).uppercased()
        let color = Self.palette[abs(host.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.palette.count]
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(letter).font(.system(size: size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(
                    .white))
    }
}
