#if DEBUG
import UIKit
import WebKit
import SwiftUI

/// Measurement hooks of Debug builds only (never compiled into a release). Each one runs when the app is
/// launched with its argument, e.g. `xcrun simctl launch --console <device> app.ipbrowser -labreturn`,
/// and prints IPB_* lines; docs/TESTING.md lists them and what each one proves.
extension BrowserController {
    /// `-strict`: strict mode on; `-phoneclock`: pages keep the phone's clock (the unprotected baseline).
    func applyLabSwitches() {
        let args = ProcessInfo.processInfo.arguments
        UserDefaults.standard.set(args.contains("-strict"), forKey: "strictMode")
        Region.shared.followsServer = !args.contains("-phoneclock")
    }

    func runLabHooks() {
        self.labInstall()
        self.labWebTransport()
        self.labProbeKinds()
        self.labManage()
        self.labReturn()
        self.labNetChange()
        self.labClock()
        self.labProfiles()
        self.labFailover()
        self.labPending()
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-ui"),
            i + 1 < ProcessInfo.processInfo.arguments.count
        {
            let screen = ProcessInfo.processInfo.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                switch screen {
                case "servers": self.showServers()
                case "install": self.present(UIHostingController(rootView: InstallView { _ in }), animated: false)
                case "import": self.present(UIHostingController(rootView: ImportView { _ in }), animated: false)
                case "settings": self.showSettings()
                case "tabs": self.showTabs()
                case "library": self.showLibrary()
                case "home": break
                default: break
                }
            }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-open"),
            i + 1 < ProcessInfo.processInfo.arguments.count,
            let u = URL(string: ProcessInfo.processInfo.arguments[i + 1])
        {
            self.labOpen(u)
        }
    }

    /// Lab: the exact install path of the «Install on my server» screen, without typing.
    func labInstall() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-labinstall"), i + 3 < args.count else { return }
        let target = args[i + 1].split(separator: ":")
        let user = args[i + 2]
        // "@/path" = read the password from a file (never on a command line)
        let password =
            args[i + 3].hasPrefix("@")
            ? ((try? String(contentsOfFile: String(args[i + 3].dropFirst()), encoding: .utf8))?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? "") : args[i + 3]
        let host = String(target[0])
        let port = target.count > 1 ? Int(target[1]) ?? 22 : 22
        Task {
            do {
                let started = Date()
                let p = try await ServerInstaller.install(
                    host: host, port: port, user: user, password: password, name: "Lab VM"
                ) { pr in
                    print("IPB_INSTALL step \(pr.step)/\(pr.total) \(pr.text)")
                }
                print(
                    "IPB_INSTALL ok seconds=\(Int(Date().timeIntervalSince(started))) kinds=\(p.kinds) managed=\(p.management != nil)"
                )
                let stored = try ProfileStore.shared.upsert(p)
                self.switchProfile(to: stored.id)
                self.pendingSelfTest = true
            } catch {
                print(
                    "IPB_INSTALL failed \((error as? InstallProblem)?.code ?? "-") \(error.localizedDescription.replacingOccurrences(of: "\n", with: " ⏎ "))"
                )
            }
        }
    }

    /// Lab: try WebTransport from the window and from a dedicated worker to a target;
    /// the target host observes whether any UDP from this device arrives directly.
    func labWebTransport() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wtprobe"), i + 1 < args.count else { return }
        let target = args[i + 1]
        guard ready, let w = webView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.labWebTransport() }
            return
        }
        let js =
            "const T=" + "\"" + target + "\"" + ";window.__wt={};"
            + "try{if(typeof WebTransport==='function'){const t=new WebTransport(T);t.ready.then(()=>__wt.window='ready').catch(e=>__wt.window='rejected:'+e)}else __wt.window='absent'}catch(e){__wt.window='threw:'+e}"
            + "try{const src=\"let r;try{if(typeof WebTransport==='function'){const t=new WebTransport('\"+T+\"');t.ready.then(()=>postMessage('ready')).catch(e=>postMessage('rejected:'+e))}else postMessage('absent')}catch(e){postMessage('threw:'+e)}\";"
            + "const wk=new Worker(URL.createObjectURL(new Blob([src],{type:'text/javascript'})));wk.onmessage=e=>__wt.worker=e.data}catch(e){__wt.worker='threw:'+e}"
        let html = "<!doctype html><body>wt probe<script>" + js + "</script></body>"
        showWeb()
        w.loadHTMLString(html, baseURL: URL(string: "https://selftest.ipbrowser.invalid/")!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            w.evaluateJavaScript("JSON.stringify(window.__wt)") { v, _ in
                print("IPB_WTPROBE target=\(target) \(v ?? "?")")
            }
        }
    }

    /// Lab: the page clock, seen through every Date/Intl entry a site uses, printed for comparison
    /// (unpatched vs. patched to the simulator's own zone must print the same text).
    func labClock() {
        guard ProcessInfo.processInfo.arguments.contains("-clock") else { return }
        guard ready, let w = webView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.labClock() }
            return
        }
        let js = #"""
            const out = [];
            const instants = [Date.UTC(2026,10,20,22,15,30,123), Date.UTC(2026,2,29,0,30), Date.UTC(2026,9,25,0,30), Date.UTC(1999,11,31,23,59,59), Date.UTC(1970,0,1), -1e12, Date.UTC(2026,6,1,12)];
            for (const t of instants) { const d = new Date(t);
              out.push([t, d.getFullYear(), d.getMonth(), d.getDate(), d.getDay(), d.getHours(), d.getMinutes(), d.getSeconds(), d.getTimezoneOffset(), d.toString(), d.toDateString(), d.toTimeString(), d.toLocaleString(), d.toLocaleDateString('en-US', {weekday: 'long'}), d.toLocaleTimeString(), `${d}`].join(' | ')); }
            out.push('resolved ' + Intl.DateTimeFormat().resolvedOptions().timeZone + ' ' + new Intl.DateTimeFormat('en-US', {timeZone: 'UTC'}).resolvedOptions().timeZone);
            for (const a of [[2026,10,20,10,0], [2026,2,29,2,30], [2026,9,25,2,30], [99,0,1], [2026,0]]) out.push('ctor ' + a + ' ' + new Date(...a).getTime());
            for (const s of ['2026-11-20T10:00', '2026-11-20T10:00:00Z', '2026-11-20', 'Nov 20 2026 10:00', '2026/11/20 10:00:00', 'Fri, 20 Nov 2026 10:00:00 GMT', '2026-11-20T10:00:00+05:00', 'garbage'])
              out.push('parse ' + s + ' ' + Date.parse(s) + ' ' + new Date(s).getTime());
            const d = new Date(Date.UTC(2026,10,20,22,15)); d.setHours(3); out.push('setHours ' + d.getTime()); d.setDate(31); out.push('setDate ' + d.getTime());
            d.setFullYear(2027, 2, 14); out.push('setFullYear ' + d.getTime()); d.setMinutes(90); out.push('setMinutes ' + d.getTime());
            out.push('natives ' + [Date, Date.prototype.getHours, Date.prototype.toString, Intl.DateTimeFormat, Function.prototype.toString, Blob, Node.prototype.appendChild,
              Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow').get, window.open].map(f => Function.prototype.toString.call(f).replace(/\s+/g, ' ')).join(' ; '));
            out.push('names ' + [Date.name, Date.length, Date.prototype.getHours.name, Date.prototype.setHours.length, Intl.DateTimeFormat.length, typeof Date(), new Date() instanceof Date, Object.keys(window).length].join(','));
            out.push('lastModified-ok ' + /^\d\d\/\d\d\/\d{4} \d\d:\d\d:\d\d$/.test(document.lastModified));
            out.push('ua ' + navigator.userAgent);
            const wk = new Worker(URL.createObjectURL(new Blob(['postMessage([new Intl.DateTimeFormat().resolvedOptions().timeZone, new Date(1795212930123).toString(), Function.prototype.toString.call(Date)].join(" | "))'], {type: 'text/javascript'})));
            return await new Promise(r => { wk.onmessage = e => { out.push('worker ' + e.data); r(out.join('\n')); }; setTimeout(() => r(out.join('\n') + '\nworker timeout'), 4000); });
            """#
        showWeb()
        w.loadHTMLString(
            "<!doctype html><title>clock</title><body>clock</body>",
            baseURL: URL(string: "https://selftest.ipbrowser.invalid/")!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            w.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                let text = (try? result.get()) as? String ?? "error \(result)"
                for line in text.split(separator: "\n") { print("IPB_CLOCK \(line)") }
                print("IPB_CLOCK done")
            }
        }
    }

    /// Lab: profiles are separate browsers. In the first profile a site sets a cookie and a
    /// storage value; every other profile must see neither (and its own exit and clock); back in
    /// the first profile both are still there. Printed as IPB_PROFILES lines.
    func labProfiles() {
        guard ProcessInfo.processInfo.arguments.contains("-labprofiles") else { return }
        let all = ProfileStore.shared.profiles
        guard all.count >= 2, let first = ProfileStore.shared.active else {
            print("IPB_PROFILES need two profiles")
            return
        }
        let order = [first] + all.filter { $0.id != first.id } + [first]
        let site = URL(string: "https://httpbin.org/cookies")!
        func whenReady(_ then: @escaping () -> Void) {
            if ready, webView != nil {
                then()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { whenReady(then) }
            }
        }
        func step(_ i: Int) {
            guard i < order.count else {
                print("IPB_PROFILES done")
                return
            }
            let p = order[i]
            if session?.profile != p.id { switchProfile(to: p.id) }
            whenReady { [weak self] in
                guard let self, let w = self.webView else { return }
                let mark = "p" + p.id.uuidString.prefix(6)
                let url = i == 0 ? URL(string: "https://httpbin.org/cookies/set?ipb=" + mark)! : site
                w.load(URLRequest(url: url))
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    let js =
                        (i == 0 ? "localStorage.setItem('ipb', '\(mark)');" : "")
                        + "JSON.stringify({body: document.body ? document.body.innerText.replace(/\\s+/g, ' ') : '', storage: localStorage.getItem('ipb'), tz: Intl.DateTimeFormat().resolvedOptions().timeZone})"
                    w.evaluateJavaScript(js) { v, e in
                        var exit = "?"
                        if case .verified(let ip) = TunnelController.shared.state { exit = ip }
                        print(
                            "IPB_PROFILES step=\(i) profile=\(p.title) mark=\(mark) exit=\(exit) page=\((v as? String) ?? "error \(String(describing: e))")"
                        )
                        step(i + 1)
                    }
                }
            }
        }
        step(0)
    }

    /// Lab (review 21.11): A → B → A. A page opened in profile A, another page in profile B; back
    /// in A, A's selected tab must show its page again by itself. Printed as IPB_RETURN lines.
    func labReturn() {
        guard ProcessInfo.processInfo.arguments.contains("-labreturn") else { return }
        let all = ProfileStore.shared.profiles
        guard all.count >= 2, let a = ProfileStore.shared.active, let b = all.first(where: { $0.id != a.id }) else {
            print("IPB_RETURN need two profiles")
            return
        }
        func when(_ ok: @escaping () -> Bool, _ seconds: Int, _ then: @escaping (Bool) -> Void) {
            if ok() {
                then(true)
            } else if seconds <= 0 {
                then(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { when(ok, seconds - 1, then) }
            }
        }
        let loaded = { (host: String) -> Bool in
            self.ready && self.webView?.isLoading == false && self.webView?.url?.host == host
                && self.webView?.title?.isEmpty == false
        }
        when({ self.ready && self.webView != nil }, 60) { _ in
            self.navigate(URL(string: "https://example.com/")!)
            when({ loaded("example.com") }, 60) { ok in
                print("IPB_RETURN A=\(a.title) example.com loaded=\(ok)")
                self.switchProfile(to: b.id)
                when({ self.ready && self.webView != nil }, 60) { _ in
                    self.navigate(URL(string: "https://www.iana.org/help/example-domains")!)
                    when({ loaded("www.iana.org") }, 60) { ok in
                        print("IPB_RETURN B=\(b.title) iana loaded=\(ok)")
                        let back = Date()
                        self.switchProfile(to: a.id)
                        when({ loaded("example.com") }, 60) { ok in
                            print(
                                "IPB_RETURN back in A: restored=\(ok) title=\(self.webView?.title ?? "") after=\(String(format: "%.1f", Date().timeIntervalSince(back))) s"
                            )
                        }
                    }
                }
            }
        }
    }

    /// Lab (review 21.11): a network change. A fresh core starts closed; a page that asks during
    /// the reconnect waits in LocalGate and goes out only after every answering kind's exit was
    /// verified. Printed as IPB_NETCHANGE lines.
    func labNetChange() {
        guard ProcessInfo.processInfo.arguments.contains("-labnetchange") else { return }
        guard ready, let w = webView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.labNetChange() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let t0 = Date()
            TunnelController.shared.restartCore(keepingPages: true)
            print("IPB_NETCHANGE restarted; websites open right after = \(TunnelController.shared.isOpen)")
            var openedAt: TimeInterval?
            self.showWeb()
            w.load(URLRequest(url: URL(string: "https://api.ipify.org/")!))  // a page asking DURING the reconnect (text/plain)
            func poll(_ n: Int) {
                if openedAt == nil, TunnelController.shared.isOpen { openedAt = Date().timeIntervalSince(t0) }
                if n % 100 == 0 {
                    print(
                        "IPB_NETCHANGE poll url=\(w.url?.absoluteString ?? "nil") loading=\(w.isLoading) progress=\(w.estimatedProgress) shown=\(w === self.webView) superview=\(w.superview != nil)"
                    )
                }
                if (w.url?.host == "api.ipify.org" && !w.isLoading) || n == 0 {
                    w.evaluateJavaScript("document.body ? document.body.innerText : ''") { v, _ in
                        print(
                            "IPB_NETCHANGE websites open after \(openedAt.map { String(format: "%.2f s", $0) } ?? "never"); page finished after \(String(format: "%.2f", Date().timeIntervalSince(t0))) s: \((v as? String) ?? "?")"
                        )
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(n - 1) }
            }
            poll(600)
        }
    }

    /// Lab (review of build 20, 21.11): a kind is lost while browsing. A first page opens; then the
    /// lab stops that kind's packets (a relay on the Mac, see docs/TESTING.md) and a NEW page must open
    /// by itself through the other kind, without a retry or a restart. Printed as IPB_FAILOVER lines.
    func labFailover() {
        guard ProcessInfo.processInfo.arguments.contains("-labfailover") else { return }
        func when(_ ok: @escaping () -> Bool, _ seconds: Double, _ then: @escaping (Bool) -> Void) {
            if ok() {
                then(true)
            } else if seconds <= 0 {
                then(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { when(ok, seconds - 0.25, then) }
            }
        }
        // Every page has its own address (never from WebKit's cache). The second is on the host of the
        // first, so WebKit sends it into the connection it already has (HTTP/2); the third is a new host.
        let token = String(UUID().uuidString.prefix(8))
        let loaded = { (url: URL) -> Bool in
            self.webView?.isLoading == false && self.webView?.url == url && self.webView?.title?.isEmpty == false
        }
        func open(_ address: String, _ label: String, then: @escaping () -> Void) {
            let url = URL(string: address + "?ipb=" + token)!
            let started = Date()
            navigate(url)
            when({ loaded(url) }, 60) { ok in
                print(
                    "IPB_FAILOVER \(label): loaded=\(ok) after=\(String(format: "%.1f", Date().timeIntervalSince(started))) s"
                )
                then()
            }
        }
        when({ self.ready && self.webView != nil }, 90) { _ in
            open("https://www.iana.org/help/example-domains", "baseline page") {
                print("IPB_FAILOVER baseline loaded: stop the first kind now")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    open("https://www.iana.org/domains/reserved", "after the loss, same host (open connection)") {
                        open("https://example.com/", "after the loss, new host") {
                            print("IPB_FAILOVER done state=\(TunnelController.shared.state)")
                        }
                    }
                }
            }
        }
    }

    /// Lab (review of build 20): on a phone with no server yet, an address typed first opens by itself
    /// in the first server added. The key comes from Documents/lab-pending-key.txt through the same
    /// path as «Add» on the import screen. Printed as IPB_PENDING lines.
    func labPending() {
        guard ProcessInfo.processInfo.arguments.contains("-labpending") else { return }
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lab-pending-key.txt")
        guard ProfileStore.shared.profiles.isEmpty, let text = try? String(contentsOf: file, encoding: .utf8) else {
            print("IPB_PENDING needs a phone without servers and Documents/lab-pending-key.txt")
            return
        }
        try? FileManager.default.removeItem(at: file)
        let url = URL(string: "https://example.com/?ipb=" + UUID().uuidString.prefix(8))!
        navigate(url)
        print("IPB_PENDING typed before any server: \(url.host ?? ""), pending=\(pendingTarget != nil)")
        do {
            let profile = try AccessKey.decode(text)
            let started = Date()
            added(profile)
            func check(_ left: Int) {
                if webView?.url == url, webView?.isLoading == false {
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                    print(
                        "IPB_PENDING opened in the first server by itself after \(seconds) s: \(webView?.title ?? "")")
                } else if left == 0 {
                    print("IPB_PENDING not opened (url=\(webView?.url?.host ?? "nil"))")
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check(left - 1) }
                }
            }
            check(120)
        } catch {
            print("IPB_PENDING key refused: \(error.localizedDescription)")
        }
    }

    /// Lab: once verified, try every masked kind on its own and print where each exits.
    func labProbeKinds() {
        guard ProcessInfo.processInfo.arguments.contains("-probekinds") else { return }
        guard ready else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.labProbeKinds() }
            return
        }
        TunnelController.shared.witnessKinds { results in
            print("IPB_KINDS " + results.map { "\($0.kind)=\($0.ip ?? "no-answer")" }.joined(separator: " "))
        }
    }

    /// Lab: the «key for a new device» / «revoke» buttons' code against the active server.
    func labManage() {
        guard ProcessInfo.processInfo.arguments.contains("-labmanage"), let p = ProfileStore.shared.active else {
            return
        }
        Task {
            do {
                let before = try await ServerInstaller.devices(p)
                let links = try await ServerInstaller.addDevice(p, name: "lab-extra")
                let added = try await ServerInstaller.devices(p)
                let key = AccessKey.encode(name: p.name, exit: p.exitIPv4, links: links)
                let decoded = try AccessKey.decode(key)
                try await ServerInstaller.revoke(p, device: "lab-extra")
                let after = try await ServerInstaller.devices(p)
                print(
                    "IPB_MANAGE before=\(before.count) added=\(added.contains("lab-extra")) newKeyKinds=\(decoded.kinds) revoked=\(!after.contains("lab-extra")) after=\(after.count)"
                )
            } catch {
                print("IPB_MANAGE failed \(error.localizedDescription.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
    }

    /// Lab: open a page once the exit is verified and print its visible text after 25 s.
    func labOpen(_ url: URL) {
        guard ready else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.labOpen(url) }
            return
        }
        navigate(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.webView?.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                let probe = "({sw: 'serviceWorker' in navigator, shared: typeof SharedWorker, idb: typeof indexedDB})"
                self?.webView?.evaluateJavaScript("JSON.stringify(\(probe))") { p, _ in
                    print(
                        "IPB_LABPAGE \(url.absoluteString) features=\(p ?? "?") text=\(((value as? String) ?? "").replacingOccurrences(of: "\n", with: " | "))"
                    )
                }
            }
        }
    }
}
#endif
