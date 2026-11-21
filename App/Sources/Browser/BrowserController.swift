import SwiftUI
import UIKit
import WebKit
import os

/// The browser: profiles on top (one per server, each a separate browser), tabs of WebKit
/// pages, a start page with favourites, an address bar with the tunnel's state as its
/// shield, and a toolbar. Servers, protection and the rest live in Settings.
final class BrowserController: UIViewController, UITextFieldDelegate {
    static let log = Logger(subsystem: "app.ipbrowser", category: "browser")
    /// One persistent website store per profile, made once per app run with that profile's
    /// own gate credential as its proxy (WebKit ignores a proxy added to a store already in use).
    static var stores: [UUID: WKWebsiteDataStore] = [:]

    let accent = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.62, blue: 1, alpha: 1) : UIColor(red: 0.05, green: 0.36, blue: 0.86, alpha: 1)
    }
    let content = UIView()
    let address = UITextField()
    let statusButton = UIButton(type: .system)
    let banner = UIButton(type: .system)
    let progress = UIProgressView(progressViewStyle: .bar)
    let toolbar = UIStackView()
    let menuButton = UIButton(type: .system)
    let startModel = StartPageModel()
    lazy var startHost = UIHostingController(rootView: StartPageView(model: startModel, library: BrowserLibrary.shared))
    let barModel = ProfileBarModel()
    lazy var barHost = UIHostingController(rootView: ProfileBar(model: barModel))
    var barShown: NSLayoutConstraint?
    var barHidden: NSLayoutConstraint?
    var session: ProfileSession?
    var rules: WKContentRuleList?
    /// Tabs brought back from a profile's saved state: their address loads when the tab is shown.
    var restoring: [ObjectIdentifier: URL] = [:]
    var configuration: WKWebViewConfiguration? { session?.configuration }
    var webView: WKWebView?
    var tabs: [WKWebView] {
        get { session?.tabs ?? [] }
        set { session?.tabs = newValue }
    }
    var observation: NSKeyValueObservation?
    var pendingTarget: URL?
    /// The route was open at the last render (to notice the moment it opens).
    var wasReady = false
    let uploads = UploadPicker()
    var downloads: [WKDownload: URL] = [:]
    var strict: Bool { UserDefaults.standard.bool(forKey: "strictMode") || Shield.webTransportLeaks }
    var ready: Bool { TunnelController.shared.isOpen }
    #if DEBUG
    var shieldOn: Bool { !ProcessInfo.processInfo.arguments.contains("-shieldoff") }
    #else
    let shieldOn = true
    #endif
    /// The time zone the page scripts carry now (nil = the phone's clock).
    var appliedZone: String? {
        get { session?.appliedZone }
        set { session?.appliedZone = newValue }
    }

    /// Pages see the verified exit's time zone (or the phone's, if the person chose so).
    /// The scripts apply to every document loaded from now on; the open page is reloaded
    /// when its clock changes, so a page never mixes two zones.
    func applyRegion() {
        guard let c = configuration, shieldOn else { return }
        var ip: String?
        if case .verified(let seen) = TunnelController.shared.state {
            ip = seen
        } else {
            ip = ProfileStore.shared.active?.exitIPv4
        }
        let zone = Region.shared.zone(for: ip)
        guard zone != appliedZone else { return }
        appliedZone = zone
        Shield.install(into: c.userContentController, zone: zone)
        if ready { for w in tabs where w.url != nil && w.url?.host != "selftest.ipbrowser.invalid" { w.reload() } }
        refreshBar()
    }
    var startVisible: Bool { !startHost.view.isHidden }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        wireStartPage()
        TunnelController.shared.onChange.append { [weak self] state in self?.render(state) }
        let center = NotificationCenter.default
        center.addObserver(forName: Region.changed, object: nil, queue: .main) { [weak self] _ in self?.applyRegion() }
        center.addObserver(forName: ProfileStore.switchRequest, object: nil, queue: .main) { [weak self] n in
            if let id = n.object as? UUID { self?.use(id) }
        }
        center.addObserver(forName: ProfileStore.removed, object: nil, queue: .main) { [weak self] n in
            if let gone = n.object as? ServerProfile { self?.forget(gone) }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
            [weak self] _ in self?.saveTabs()
        }
        TunnelController.shared.boot { [weak self] ok in self?.makeEngine(ok) }
        render(TunnelController.shared.state)
    }

    // MARK: interface

    func buildInterface() {
        view.backgroundColor = .systemBackground
        address.borderStyle = .none
        address.font = .systemFont(ofSize: 16)
        address.placeholder = L("address.placeholder")
        address.keyboardType = .webSearch
        address.returnKeyType = .go
        address.autocapitalizationType = .none
        address.autocorrectionType = .no
        address.clearButtonMode = .whileEditing
        address.delegate = self
        address.backgroundColor = .secondarySystemBackground
        address.layer.cornerRadius = 14
        address.accessibilityIdentifier = "addressField"
        statusButton.addTarget(self, action: #selector(showConnection), for: .touchUpInside)
        statusButton.accessibilityIdentifier = "exitChip"
        statusButton.accessibilityLabel = L("connection.title")
        address.leftView = padded(statusButton, width: 44)
        address.leftViewMode = .always
        address.rightView = padded(icon("arrow.clockwise", L("reload"), #selector(reloadPage)), width: 44)
        address.rightViewMode = .unlessEditing

        menuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        menuButton.tintColor = accent
        menuButton.accessibilityLabel = L("menu")
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.menuItems() ?? []) }
        ])
        menuButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        toolbar.axis = .horizontal
        toolbar.distribution = .equalSpacing
        for b in [
            icon("chevron.backward", L("back"), #selector(back)),
            icon("chevron.forward", L("forward"), #selector(forward)),
            icon("book", L("library.title"), #selector(showLibrary)),
            icon("square.on.square", L("tabs"), #selector(showTabs)),
            menuButton,
        ] { toolbar.addArrangedSubview(b) }

        var bc = UIButton.Configuration.plain()
        bc.contentInsets = .init(top: 4, leading: 12, bottom: 4, trailing: 12)
        banner.configuration = bc
        banner.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        banner.backgroundColor = .secondarySystemBackground
        banner.layer.cornerRadius = 13
        banner.addTarget(self, action: #selector(showConnection), for: .touchUpInside)
        banner.isHidden = true
        banner.accessibilityIdentifier = "tunnelBanner"

        addChild(barHost)
        barHost.view.backgroundColor = .systemBackground
        for v in [content, progress, address, toolbar, banner, barHost.view!] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        barHost.didMove(toParent: self)
        barShown = content.topAnchor.constraint(equalTo: barHost.view.bottomAnchor)
        barHidden = content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            barHost.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            barHost.view.heightAnchor.constraint(equalToConstant: 44),
            barHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: address.topAnchor, constant: -8),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progress.topAnchor.constraint(equalTo: content.topAnchor),
            banner.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.heightAnchor.constraint(equalToConstant: 26),
            address.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            address.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            address.heightAnchor.constraint(equalToConstant: 46),
            address.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -4),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            toolbar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
        ])
        addChild(startHost)
        startHost.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(startHost.view)
        NSLayoutConstraint.activate([
            startHost.view.topAnchor.constraint(equalTo: content.topAnchor),
            startHost.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            startHost.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            startHost.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        startHost.didMove(toParent: self)
        barHidden?.isActive = true
        barHost.view.isHidden = true
        progress.isHidden = true
    }

    /// A side view of the address field: the button centred in a fixed box (UITextField
    /// otherwise sizes it to the bare symbol and the text touches it).
    func padded(_ button: UIButton, width: CGFloat) -> UIView {
        let box = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 44))
        button.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: width), box.heightAnchor.constraint(equalToConstant: 44),
        ])
        return box
    }

    func icon(_ symbol: String, _ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = accent
        b.accessibilityLabel = title
        b.addTarget(self, action: action, for: .touchUpInside)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return b
    }

    func wireStartPage() {
        startModel.open = { [weak self] url in self?.navigate(url) }
        startModel.install = { [weak self] in self?.presentInstall() }
        startModel.haveKey = { [weak self] in self?.presentImport() }
        startModel.servers = { [weak self] in self?.showServers() }
        barModel.select = { [weak self] id in
            if id == self?.session?.profile { self?.showConnection() } else { self?.switchProfile(to: id) }
        }
        barModel.install = { [weak self] in self?.presentInstall() }
        barModel.haveKey = { [weak self] in self?.presentImport() }
        barModel.manage = { [weak self] in self?.showServers() }
        startModel.acceptExit = { ip in TunnelController.shared.acceptExit(ip) }
        startModel.retry = { TunnelController.shared.restartCore() }
    }

    func render(_ state: TunnelController.State) {
        let name = ProfileStore.shared.active?.title ?? ""
        var symbol = "shield.lefthalf.filled"
        var color = UIColor.systemOrange
        var bannerText: String? = L("chip.reconnecting")
        switch state {
        case .noProfile:
            startModel.status = .noServer
            symbol = "shield.slash"
            color = .secondaryLabel
            bannerText = L("chip.noServer")
        case .starting, .reconnecting:
            if TunnelController.shared.offline {
                startModel.status = .offline(server: name)
                bannerText = L("chip.offline")
            } else {
                let diagnosis = TunnelController.shared.diagnosis
                startModel.status = .connecting(server: name, diagnosis: diagnosis)
                // After 20 s without the server, a page says so and why (one tap shows the details).
                if diagnosis != nil { bannerText = L("chip.noRoute") }
            }
        case .verified(let ip):
            applyRegion()
            startModel.status = .verified(server: name, ip: ip)
            symbol = "checkmark.shield.fill"
            color = .systemGreen
            bannerText = nil
        case .mismatch(let expected, let seen):
            startModel.status = .mismatch(expected: expected, seen: seen)
            symbol = "xmark.shield.fill"
            color = .systemRed
            bannerText = L("chip.mismatch")
        case .failed(let message):
            startModel.status = .failed(message)
            symbol = "xmark.shield.fill"
            color = .systemRed
            bannerText = L("chip.failed")
        }
        startModel.pending = pendingTarget
        statusButton.setImage(UIImage(systemName: symbol), for: .normal)
        statusButton.tintColor = color
        banner.setTitle(bannerText, for: .normal)
        banner.setTitleColor(color, for: .normal)
        banner.isHidden = bannerText == nil || startVisible
        // (navigate → showWeb → render: wasReady is updated first, so this runs once per opening)
        let opened = ready && !wasReady
        wasReady = ready
        if ready, let target = pendingTarget {
            pendingTarget = nil
            navigate(target)
        }
        // The shown tab still waits to be restored (its first attempt failed): when the route
        // opens again, try it again.
        else if opened, let w = webView, !w.isLoading, let u = restoring[ObjectIdentifier(w)] {
            navigate(u)
        }
        refreshBar()
    }

    /// The profile bar: every server as a profile, the active one with the tunnel's state.
    func refreshBar() {
        let profiles = ProfileStore.shared.profiles
        let items = profiles.map { ProfileBarModel.Item(id: $0.id, title: $0.title, flag: $0.flag) }
        if barModel.items != items { barModel.items = items }
        if barModel.active != session?.profile { barModel.active = session?.profile }
        let dot: ProfileBarModel.Dot
        switch TunnelController.shared.state {
        case .verified: dot = .ok
        case .mismatch, .failed: dot = .bad
        default: dot = .wait
        }
        if barModel.dot != dot { barModel.dot = dot }
        let show = !profiles.isEmpty
        if barShown?.isActive != show || barHidden?.isActive == show {
            barShown?.isActive = false
            barHidden?.isActive = false
            (show ? barShown : barHidden)?.isActive = true
            barHost.view.isHidden = !show
        }
    }

    /// A server added from the start page or the profile bar: store it and switch to it.
    func added(_ profile: ServerProfile) {
        dismiss(animated: true)
        guard let stored = try? ProfileStore.shared.upsert(profile) else { return }
        use(stored.id)
    }

    /// Make a profile the active one. The active profile updated with a new key (same exit,
    /// new links) keeps its pages and data; only its tunnel restarts with the new key.
    func use(_ id: UUID) {
        if session?.profile == id, let p = ProfileStore.shared.profiles.first(where: { $0.id == id }) {
            TunnelController.shared.activate(p)
            render(TunnelController.shared.state)
        } else {
            switchProfile(to: id)
        }
    }
    func presentInstall() {
        present(UIHostingController(rootView: InstallView { [weak self] p in self?.added(p) }), animated: true)
    }
    func presentImport() {
        present(UIHostingController(rootView: ImportView { [weak self] p in self?.added(p) }), animated: true)
    }

    // MARK: engine

    func makeEngine(_ ok: Bool) {
        guard ok else { return }
        #if DEBUG
        applyLabSwitches()
        #endif
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ipbrowser-local-v1", encodedContentRuleList: Shield.contentRules
        ) { [weak self] list, _ in
            guard let self else { return }
            self.rules = list
            self.switchProfile(to: ProfileStore.shared.active?.id, force: true)
            if ProcessInfo.processInfo.arguments.contains("-selftest") { self.pendingSelfTest = true }
            #if DEBUG
            self.runLabHooks()
            #endif
            self.render(TunnelController.shared.state)
        }
    }

    var pendingSelfTest = false { didSet { if pendingSelfTest { runSelfTestWhenReady() } } }
    func runSelfTestWhenReady() {
        guard pendingSelfTest else { return }
        if ready {
            pendingSelfTest = false
            openSelfTest(report: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runSelfTestWhenReady() }
        }
    }

    func makeWebView(_ c: WKWebViewConfiguration) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: c)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.allowsLinkPreview = false
        w.isFindInteractionEnabled = true
        w.isInspectable = false
        w.accessibilityIdentifier = "browserContent"
        return w
    }

    func switchTo(_ w: WKWebView) {
        webView?.removeFromSuperview()
        observation = nil
        webView = w
        w.translatesAutoresizingMaskIntoConstraints = false
        content.insertSubview(w, at: 0)
        NSLayoutConstraint.activate([
            w.topAnchor.constraint(equalTo: content.topAnchor),
            w.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            w.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            w.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        observation = w.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
            guard let self else { return }
            self.progress.progress = Float(w.estimatedProgress)
            self.progress.isHidden = !w.isLoading || self.startVisible
        }
        pendingTarget = nil
        if let u = restoring[ObjectIdentifier(w)] {  // now, or once the tunnel is open
            if w.isLoading {
                showWeb()
                address.text = shownAddress(u)
            } else {
                navigate(u)
            }
        } else if w.url == nil {
            showStart()
        } else {
            showWeb()
            address.text = shownAddress(w.url)
        }
    }

    func showStart() {
        startHost.view.isHidden = false
        webView?.isHidden = true
        progress.isHidden = true
        if !address.isFirstResponder { address.text = "" }
        render(TunnelController.shared.state)
    }
    func showWeb() {
        startHost.view.isHidden = true
        webView?.isHidden = false
        render(TunnelController.shared.state)
    }

    // MARK: navigation

    func navigate(_ url: URL) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        view.endEditing(true)
        address.text = shownAddress(url)
        guard ready, let w = webView else {
            pendingTarget = url
            showStart()
            return
        }
        showWeb()
        // A tab being restored keeps its address until the page has really arrived
        // (didCommit): a failed attempt is tried again, never lost.
        if restoring[ObjectIdentifier(w)] != url { restoring[ObjectIdentifier(w)] = nil }
        w.load(URLRequest(url: url))
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let raw = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return true }
        if raw.contains("://"), let u = URL(string: raw), u.host != nil {
            navigate(u)
        } else if !raw.contains(" "), raw.contains("."), let u = URL(string: "https://" + raw), u.host != nil {
            navigate(u)
        } else if let u = Settings.search(raw) {
            navigate(u)
        }
        return true
    }
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.text =
            startVisible
            ? "" : webView?.url.flatMap { shownAddress($0) == L("selftest") ? nil : editableAddress($0) } ?? ""
        DispatchQueue.main.async { textField.selectAll(nil) }
    }
    func textFieldDidEndEditing(_ textField: UITextField) {
        if startVisible { textField.text = "" } else { textField.text = shownAddress(webView?.url) }
    }

    @objc func showHome() {
        pendingTarget = nil
        webView?.stopLoading()
        view.endEditing(true)
        showStart()
    }
    @objc func back() { if startVisible, webView?.url != nil { showWeb() } else { webView?.goBack() } }
    @objc func forward() { webView?.goForward() }
    @objc func reloadPage() {
        if startVisible {
            TunnelController.shared.check(reason: "manual")
            return
        }
        if let w = webView, let failed = restoring[ObjectIdentifier(w)] { navigate(failed) } else { webView?.reload() }
    }

    func newTab() {
        guard let c = configuration, tabs.count < 30 else { return }
        let w = makeWebView(c)
        tabs.append(w)
        switchTo(w)
    }

    func openSelfTest(report: Bool = false) {
        TunnelController.shared.check(reason: "selftest")
        guard ready, let w = webView, let file = Bundle.main.url(forResource: "selftest", withExtension: "html"),
            let html = try? String(contentsOf: file, encoding: .utf8)
        else { return }
        showWeb()
        // A local document with an https origin: the probes run without any site.
        // The page cannot see the iOS version (WebKit freezes it in the user agent).
        let facts =
            "#ios=\(Shield.iosVersion)&strict=\(strict ? 1 : 0)&wtProxySafe=\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? 1 : 0)"
            + "&zone=\(appliedZone ?? "")&phone=\(TimeZone.current.identifier)"
            + "&profile=\(session.map { String($0.profile.uuidString.prefix(8)) } ?? "")"
            + "&pname=\((ProfileStore.shared.active?.title ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            + "&exit=\(ProfileStore.shared.active?.exitIPv4 ?? "")"
            + "&lang=\(Bundle.main.preferredLocalizations.first?.hasPrefix("ru") == true ? "ru" : "en")"
        w.loadHTMLString(html, baseURL: URL(string: "https://selftest.ipbrowser.invalid/" + facts)!)
        address.text = L("selftest")
        guard report else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            w.callAsyncJavaScript("return JSON.stringify(window.__selftest)", arguments: [:], in: nil, in: .page) {
                result in
                let text = (try? result.get()) as? String ?? "error \(result)"
                Self.log.notice(
                    "IPB_SELFTEST mode=\(self.strict ? "strict" : "shield", privacy: .public) \(text, privacy: .public)"
                )
                print("IPB_SELFTEST mode=\(self.strict ? "strict" : "shield") \(text)")
            }
        }
    }

    // MARK: tabs, library, menu

    @objc func showTabs() {
        let group = DispatchGroup()
        var images: [ObjectIdentifier: UIImage] = [:]
        for w in tabs where w.url != nil && !(w === webView && startVisible) {
            group.enter()
            let c = WKSnapshotConfiguration()
            c.snapshotWidth = 320
            w.takeSnapshot(with: c) { image, _ in
                if let image { images[ObjectIdentifier(w)] = image }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in self?.presentTabs(images) }
    }

    func presentTabs(_ images: [ObjectIdentifier: UIImage]) {
        let items = tabs.map { w -> TabsView.Item in
            let waiting = restoring[ObjectIdentifier(w)]
            let start = waiting == nil && (w.url == nil || (w === webView && startVisible))
            let title =
                start
                ? L("tab.start")
                : waiting.map { $0.host ?? "" } ?? (w.title?.isEmpty == false ? w.title! : (w.url?.host ?? ""))
            return TabsView.Item(
                id: ObjectIdentifier(w), title: title, host: (waiting ?? w.url)?.host ?? "",
                image: start ? nil : images[ObjectIdentifier(w)], current: w === webView)
        }
        let profile = ProfileStore.shared.active.map { ($0.flag.map { $0 + " " } ?? "") + $0.title }
        let view = TabsView(
            items: items, profile: profile,
            onSelect: { [weak self] id in
                guard let self, let w = self.tabs.first(where: { ObjectIdentifier($0) == id }) else { return }
                self.dismiss(animated: true)
                self.switchTo(w)
            },
            onClose: { [weak self] id in self?.closeTab(id) },
            onNew: { [weak self] in
                self?.dismiss(animated: true)
                self?.newTab()
            },
            onDone: { [weak self] in self?.dismiss(animated: true) })
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    func closeTab(_ id: ObjectIdentifier) {
        guard let i = tabs.firstIndex(where: { ObjectIdentifier($0) == id }) else { return }
        let w = tabs.remove(at: i)
        restoring[ObjectIdentifier(w)] = nil
        w.stopLoading()
        w.removeFromSuperview()
        if tabs.isEmpty { newTab() } else if w === webView { switchTo(tabs[max(0, i - 1)]) }
    }

    @objc func showLibrary() {
        let host = UIHostingController(
            rootView: LibraryView(
                onOpen: { [weak self] url in
                    self?.dismiss(animated: true)
                    self?.navigate(url)
                }, onDone: { [weak self] in self?.dismiss(animated: true) }))
        present(host, animated: true)
    }

    func menuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if let w = webView, let url = w.url, !startVisible, url.host != "selftest.ipbrowser.invalid",
            ["http", "https"].contains(url.scheme ?? "")
        {
            let favorite = BrowserLibrary.shared.isFavorite(url)
            items.append(
                UIMenu(
                    options: .displayInline,
                    children: [
                        UIAction(
                            title: favorite ? L("menu.unfavorite") : L("menu.favorite"),
                            image: UIImage(systemName: favorite ? "star.slash" : "star")
                        ) { _ in
                            BrowserLibrary.shared.toggleFavorite(title: w.title ?? "", url: url)
                        },
                        UIAction(title: L("share"), image: UIImage(systemName: "square.and.arrow.up")) {
                            [weak self] _ in self?.share(url)
                        },
                        UIAction(title: L("find"), image: UIImage(systemName: "doc.text.magnifyingglass")) {
                            [weak self] _ in
                            self?.webView?.findInteraction?.presentFindNavigator(showingReplace: false)
                        },
                    ]))
        }
        items.append(
            UIMenu(
                options: .displayInline,
                children: [
                    UIAction(title: L("tab.new"), image: UIImage(systemName: "plus.square.on.square")) {
                        [weak self] _ in self?.newTab()
                    },
                    UIAction(title: L("home"), image: UIImage(systemName: "house")) { [weak self] _ in self?.showHome()
                    },
                ]))
        items.append(
            UIAction(title: L("settings"), image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.showSettings()
            })
        return items
    }

    func share(_ url: URL) {
        let a = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        a.popoverPresentationController?.sourceView = menuButton
        present(a, animated: true)
    }

    @objc func showConnection() {
        var message: String
        switch TunnelController.shared.state {
        case .verified(let ip):
            message = String(format: L("connection.exit"), ip) + "\n" + (ProfileStore.shared.active?.title ?? "")
            if let zone = Region.shared.zone(for: ip) { message += "\n" + Region.describe(zone) }
        case .noProfile: message = L("chip.noServer")
        case .failed(let text): message = text
        default:
            message = L("chip.reconnecting")
            if TunnelController.shared.offline {
                message = L("chip.offline")
            } else if let diagnosis = TunnelController.shared.diagnosis {
                message += "\n\n" + diagnosis
            }
        }
        if let w = webView, let url = w.url, !startVisible, ["http", "https"].contains(url.scheme ?? "") {
            let secure = url.scheme == "https" && w.hasOnlySecureContent && w.serverTrust != nil
            message += "\n\n" + (url.host ?? "—") + "\n" + (secure ? L("connection.secure") : L("connection.insecure"))
            if let trust = w.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                let leaf = chain.first
            {
                message += "\n" + ((SecCertificateCopySubjectSummary(leaf) as String?) ?? "—")
            }
        }
        let alert = UIAlertController(title: L("connection.title"), message: message, preferredStyle: .alert)
        switch TunnelController.shared.state {
        case .verified, .noProfile, .mismatch: break
        default:
            alert.addAction(
                UIAlertAction(title: L("retry"), style: .default) { _ in TunnelController.shared.restartCore() })
        }
        alert.addAction(UIAlertAction(title: L("servers"), style: .default) { [weak self] _ in self?.showServers() })
        alert.addAction(UIAlertAction(title: L("close"), style: .cancel))
        present(alert, animated: true)
    }

    func offerKey(_ text: String) {
        do {
            let profile = try AccessKey.decode(text)
            let old = ProfileStore.shared.existing(for: profile)
            let a = UIAlertController(
                title: old.map { String(format: L("key.update.title"), $0.title) } ?? L("key.offer.title"),
                message: old != nil
                    ? L("key.update.detail")
                    : String(format: L("key.offer.detail"), profile.name, profile.exitIPv4 ?? "—"),
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L("cancel"), style: .cancel))
            a.addAction(
                UIAlertAction(title: old != nil ? L("key.update") : L("import.add"), style: .default) { [weak self] _ in
                    guard let stored = try? ProfileStore.shared.upsert(profile) else { return }
                    self?.use(stored.id)
                })
            (presentedViewController ?? self).present(a, animated: true)
        } catch {
            let a = UIAlertController(
                title: L("error.title"), message: error.localizedDescription, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(a, animated: true)
        }
    }

    @objc func showServers() {
        let host = UIHostingController(
            rootView: NavigationStack { ServersView(onDone: { [weak self] in self?.dismiss(animated: true) }) })
        present(host, animated: true)
    }

    func showSettings() {
        let host = UIHostingController(
            rootView: SettingsView(
                onDone: { [weak self] in self?.dismiss(animated: true) },
                onLeakTest: { [weak self] in self?.dismiss(animated: true) { self?.openSelfTest() } },
                onClearData: { [weak self] in self?.clearData() },
                onStrictChanged: { [weak self] in self?.rebuildForStrictMode() },
                onOpen: { [weak self] url in
                    self?.dismiss(animated: true) {
                        self?.newTab()
                        self?.navigate(url)
                    }
                }))
        present(host, animated: true)
    }

    /// Like Safari: the site's name while browsing, the whole (readable) address while editing.
    func shownAddress(_ url: URL?) -> String? {
        guard let url else { return nil }
        if url.host == "selftest.ipbrowser.invalid" { return L("selftest") }
        guard let host = url.host, ["http", "https"].contains(url.scheme ?? "") else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    func editableAddress(_ url: URL) -> String { url.absoluteString.removingPercentEncoding ?? url.absoluteString }
}
