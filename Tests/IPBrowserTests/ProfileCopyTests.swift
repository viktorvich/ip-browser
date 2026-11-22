import WebKit
import XCTest

@testable import IPBrowser

@MainActor
final class ProfileCopyTests: XCTestCase {
    private func cookies(_ store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    func testCopiesSurviveReloadAndUpdatingOrDeletingOneKeepsTheOther() throws {
        let service = "app.ipbrowser.copy-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: service)!
        defer { defaults.removePersistentDomain(forName: service) }
        let store = ProfileStore(service: service, defaults: defaults)
        let original = try store.upsert(ServerProfile(name: "KZ", links: ["hy2://test.invalid"], exitIPv4: "203.0.113.1", origin: .imported))
        let copy = try store.duplicate(original.id)
        let third = try store.duplicate(original.id)
        XCTAssertNotEqual(copy.name, third.name)
        let reloaded = ProfileStore(service: service, defaults: defaults)
        XCTAssertEqual(Set(reloaded.profiles.map(\.id)), [original.id, copy.id, third.id])
        reloaded.activeID = copy.id
        let updated = try reloaded.upsert(ServerProfile(name: "import", links: ["hy2://updated.invalid"], exitIPv4: original.exitIPv4, origin: .imported))
        XCTAssertEqual(updated.id, copy.id, "an imported replacement updates the active copy only")
        XCTAssertEqual(reloaded.profiles.first { $0.id == original.id }?.links, original.links)
        try reloaded.remove(copy.id)
        let afterRemoval = ProfileStore(service: service, defaults: defaults)
        XCTAssertEqual(Set(afterRemoval.profiles.map(\.id)), [original.id, third.id])
        for p in afterRemoval.profiles { try afterRemoval.remove(p.id) }
    }

    func testCopyHasFreshPersistentWebKitAndBrowserStorage() async throws {
        var original = ServerProfile(name: "KZ", links: [], exitIPv4: "203.0.113.1", origin: .installed)
        original.storeID = UUID() // covers migrated profiles whose store is not their profile UUID
        let copy = original.isolatedCopy(named: "KZ copy")
        XCTAssertNotEqual(original.id, copy.id)
        XCTAssertNotEqual(original.dataStoreID, copy.dataStoreID)
        XCTAssertNil(copy.management)
        let first = WKWebsiteDataStore(forIdentifier: original.dataStoreID)
        let second = WKWebsiteDataStore(forIdentifier: copy.dataStoreID)
        let cookie = HTTPCookie(properties: [.domain: "isolation.example", .path: "/", .name: "login", .value: "original-session"])!
        await first.httpCookieStore.setCookie(cookie)
        let originalCookies = await cookies(first.httpCookieStore)
        let copyCookies = await cookies(second.httpCookieStore)
        XCTAssertEqual(originalCookies.first { $0.name == "login" }?.value, "original-session")
        XCTAssertFalse(copyCookies.contains { $0.name == "login" })
        let library = BrowserLibrary.of(original.id)
        let url = URL(string: "https://isolation.example/original")!
        library.recordVisit(title: "original", url: url)
        library.saveTabs(.init(urls: [url], selected: 0))
        XCTAssertTrue(BrowserLibrary.of(copy.id).history.isEmpty)
        XCTAssertNil(BrowserLibrary.of(copy.id).savedTabs)
        await second.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let stillPresent = await cookies(first.httpCookieStore)
        XCTAssertTrue(stillPresent.contains { $0.name == "login" }, "clearing a copy must not sign the original out")
        await first.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        BrowserLibrary.forget(original.id)
        BrowserLibrary.forget(copy.id)
    }
}
