import UIKit
import WebKit

/// One profile's browser: its own website store (cookies, storage, caches, service workers),
/// its configuration (the shield carrying the profile exit's clock), its tabs and library.
/// Only the active profile has a session; another profile's pages do not exist meanwhile.
final class ProfileSession {
    let profile: UUID
    var configuration: WKWebViewConfiguration
    let library: BrowserLibrary
    var tabs: [WKWebView] = []
    var appliedZone: String?
    init(profile: UUID, configuration: WKWebViewConfiguration, library: BrowserLibrary) {
        self.profile = profile
        self.configuration = configuration
        self.library = library
    }
}

/// Profiles: each server is a separate browser with its own website store, tabs and library.
extension BrowserController {
    /// Switch the whole browser to a profile: the old profile's pages close (their tabs are
    /// kept for later), the gate closes, the new profile's own website store, tabs, library
    /// and clock come up, and its server's tunnel starts. Nothing of one profile is ever
    /// visible to, or carried by, another.
    func switchProfile(to id: UUID?, force: Bool = false) {
        let target =
            id.flatMap { id in ProfileStore.shared.profiles.first { $0.id == id } } ?? ProfileStore.shared.active
        if !force, let s = session, s.profile == target?.id { return }
        dismissMenus()
        // An address typed before there was any server opens in the first one added (review 21.11);
        // one typed in another profile never follows into this one.
        let carried = session == nil ? pendingTarget : nil
        closeSession()
        pendingTarget = nil
        ProfileStore.shared.activeID = target?.id
        // The tunnel switches first: the old profile's route is closed and the new one is not
        // open until its own exit is verified, so the restored tab waits for it instead of
        // loading through the old route (an empty page on returning, review 21.11).
        TunnelController.shared.activate(target)
        if let target {
            openSession(target)
            if let carried { pendingTarget = carried }
        } else {
            BrowserLibrary.deactivate()
            startHost.rootView = StartPageView(model: startModel, library: BrowserLibrary.shared)
            showStart()
        }
        render(TunnelController.shared.state)
    }

    func dismissMenus() { view.endEditing(true) }

    /// The website store of a profile; nil if the gate cannot give it a proxy (then the
    /// profile gets no pages at all: a store without the proxy would go straight out).
    func store(for p: ServerProfile) -> WKWebsiteDataStore? {
        if let s = Self.stores[p.dataStoreID] { return s }
        guard let proxy = TunnelController.shared.gate.browserProxy(for: p.id) else { return nil }
        let s = WKWebsiteDataStore(forIdentifier: p.dataStoreID)
        s.proxyConfigurations = [proxy]
        Self.stores[p.dataStoreID] = s
        return s
    }

    func openSession(_ p: ServerProfile) {
        guard let rules, let store = store(for: p) else {
            Self.log.error("IPB no proxy for the profile store")
            return
        }
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        Shield.harden(c, strict: strict)
        let s = ProfileSession(profile: p.id, configuration: c, library: BrowserLibrary.of(p.id))
        BrowserLibrary.activate(p.id)
        session = s
        s.appliedZone = Region.shared.zone(for: p.exitIPv4)
        if shieldOn { Shield.install(into: c.userContentController, zone: s.appliedZone) }
        c.userContentController.add(rules)
        startHost.rootView = StartPageView(model: startModel, library: s.library)
        // The tabs this profile had: each loads its address when it is shown.
        let saved = s.library.savedTabs
        let urls: [URL?] = (saved?.urls.isEmpty == false ? saved!.urls : [nil])
        s.tabs = urls.map { _ in makeWebView(c) }
        for (w, u) in zip(s.tabs, urls) { if let u { restoring[ObjectIdentifier(w)] = u } }
        switchTo(s.tabs[min(max(saved?.selected ?? 0, 0), s.tabs.count - 1)])
    }

    /// The tabs of the active profile, kept in its library (switching away, the background).
    func saveTabs() {
        guard let s = session else { return }
        let urls: [URL?] = s.tabs.map { w in
            let u = restoring[ObjectIdentifier(w)] ?? w.url
            return u.flatMap {
                ["http", "https"].contains($0.scheme ?? "") && $0.host != "selftest.ipbrowser.invalid" ? $0 : nil
            }
        }
        let selected = webView.flatMap { s.tabs.firstIndex(of: $0) } ?? 0
        s.library.saveTabs(.init(urls: urls, selected: selected))
    }

    func closeSession() {
        guard let s = session else { return }
        saveTabs()
        if presentedViewController != nil { dismiss(animated: false) }
        for w in s.tabs {
            w.stopLoading()
            w.removeFromSuperview()
            w.navigationDelegate = nil
            w.uiDelegate = nil
        }
        s.tabs = []
        restoring.removeAll()
        observation = nil
        webView = nil
        session = nil
    }

    /// A removed profile: its pages, website data, tabs, favourites and history go.
    func forget(_ gone: ServerProfile) {
        let wasCurrent = session?.profile == gone.id
        if wasCurrent { closeSession() }
        BrowserLibrary.forget(gone.id)
        let store =
            Self.stores.removeValue(forKey: gone.dataStoreID) ?? WKWebsiteDataStore(forIdentifier: gone.dataStoreID)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                WKWebsiteDataStore.remove(forIdentifier: gone.dataStoreID) { error in
                    if let error {
                        Self.log.notice("IPB store remove: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        if wasCurrent || session == nil {
            switchProfile(to: ProfileStore.shared.active?.id, force: true)
        } else {
            refreshBar()
        }
    }

    /// The active profile's website data only; other profiles keep theirs.
    func clearData() {
        configuration?.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        ) { [weak self] in
            guard let self, let c = self.configuration else { return }
            for w in self.tabs {
                w.stopLoading()
                w.removeFromSuperview()
            }
            self.tabs = []
            self.restoring.removeAll()
            let w = self.makeWebView(c)
            self.tabs = [w]
            self.switchTo(w)
            self.saveTabs()
        }
    }

    /// Lockdown can be switched on per navigation but never off again inside one
    /// configuration, so a change rebuilds the configuration and reopens the tabs
    /// (same store: cookies and logins stay).
    func rebuildForStrictMode() {
        guard let old = configuration else { return }
        let c = WKWebViewConfiguration()
        c.websiteDataStore = old.websiteDataStore
        c.userContentController = old.userContentController
        Shield.harden(c, strict: strict)
        session?.configuration = c
        let urls = tabs.map { restoring[ObjectIdentifier($0)] ?? $0.url }
        restoring.removeAll()
        let selected = webView.flatMap { tabs.firstIndex(of: $0) } ?? 0
        for w in tabs {
            w.stopLoading()
            w.removeFromSuperview()
        }
        tabs = urls.map { _ in makeWebView(c) }
        for (w, u) in zip(tabs, urls) {
            if let u, ["http", "https"].contains(u.scheme ?? "") { w.load(URLRequest(url: u)) }
        }
        switchTo(tabs[min(selected, tabs.count - 1)])
    }
}
