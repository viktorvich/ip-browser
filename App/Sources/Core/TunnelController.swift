import Foundation
import Network
import UIKit

/// What the witness saw through one kind's own door of the core.
struct KindWitness: Equatable {
    let kind: String
    let port: Int
    let ip: String?
    let seconds: TimeInterval
}

/// The decision over one round of witnesses (unit-tested): websites open only when every kind
/// that answered left from one address and it is the profile's.
enum ExitVerdict: Equatable {
    /// No kind answered (no route from this network now).
    case silent
    /// The kinds of one key leave from different addresses: a wrong key or a wrongly configured
    /// server, nothing the person could accept.
    case kindsDiffer(String)
    /// A kind leaves from another address than the profile's.
    case mismatch(kind: String, expected: String, seen: String)
    /// The exit, and the doors that showed it, fastest first.
    case open(exit: String, doors: [KindWitness])

    static func decide(_ results: [KindWitness], expected: String?) -> ExitVerdict {
        let answered = results.filter { $0.ip != nil }
        guard let first = answered.first?.ip else { return .silent }
        if Set(answered.compactMap(\.ip)).count > 1 {
            return .kindsDiffer(answered.map { "\($0.kind) → \($0.ip ?? "?")" }.joined(separator: ", "))
        }
        let exit = expected ?? first
        if let wrong = answered.first(where: { $0.ip != exit }) {
            return .mismatch(kind: wrong.kind, expected: exit, seen: wrong.ip ?? "?")
        }
        return .open(exit: exit, doors: answered.sorted { $0.seconds < $1.seconds })
    }
}

/// The whole route of this browser: WebKit -> LocalGate (loopback) -> in-app core -> the
/// profile's server -> the internet from ONE address.
///
/// Websites open only after the exit witness, sent through each masked kind's own door of the
/// core, saw the profile's exit address; a page then passes only through a kind whose exit was
/// seen (LocalGate). Every new core (a switch, a network change) starts closed. A transient
/// outage (a carrier's reconnect, a train tunnel, an app switch) only pauses: nothing can leave
/// another way, because the core has no direct outbound and WebKit's proxy has no failover. A
/// different exit address closes the gate hard until the person decides.
final class TunnelController {
    enum State: Equatable {
        case noProfile
        case starting
        case verified(ip: String)
        case reconnecting(ip: String?)
        case mismatch(expected: String, seen: String)
        case failed(String)
    }

    static let shared = TunnelController()
    let gate = LocalGate()
    private(set) var state: State = .starting { didSet { if state != oldValue { notify() } } }
    /// Websites may use the tunnel (set only after a verified exit; kept through a reconnect).
    private(set) var isOpen = false
    /// The profile the tunnel runs for now: only its pages may pass the gate.
    private(set) var profileID: UUID?
    private var witnessSession: URLSession?
    private var generation = 0
    private var checking = false
    private var verifyAgain = false
    private var pathChange = 0
    private var retryDelay: TimeInterval = 1
    private var backgroundedAt: Date?
    /// Wi-Fi ↔ mobile, a VPN app switched on or off: the route to the server changed, so the
    /// exit is verified again at once instead of showing an old «verified».
    private let pathMonitor = NWPathMonitor()
    private var lastPath: String?
    var onChange: [(State) -> Void] = []
    /// Plain words about what does not get through from this network (set by describe()).
    private(set) var diagnosis: String? { didSet { notify() } }
    /// The phone itself has no network (airplane mode, no signal): said as it is.
    private(set) var offline = false { didSet { if offline != oldValue { notify() } } }
    private var activatedAt = Date()
    private var failingSince = Date()
    private var lastDiagnosis = Date.distantPast
    /// The generation whose background re-check of the kinds is scheduled.
    private var recheckFor = -1
    private var recheckSummary = ""
    private var lastTroubleCheck = Date.distantPast
    /// How long the witness took through each door at the last verification.
    private var doorSeconds: [Int: TimeInterval] = [:]

    /// The profile as stored now (its pinned exit can change while the tunnel runs).
    private var profile: ServerProfile? {
        profileID.flatMap { id in ProfileStore.shared.profiles.first { $0.id == id } }
    }

    private func setOpen(_ open: Bool) {
        isOpen = open
        gate.setProfile(profileID, open: open)
    }

    private func notify() { for f in onChange { f(state) } }
    private func log(_ text: String) { ConnectionLog.shared.add(text) }

    /// Start the gate. `ready(true)`: profiles' proxies can be made; the browser then activates
    /// the active profile (pages, data and tunnel together).
    func boot(_ ready: @escaping (Bool) -> Void) {
        gate.upstreamFailure = { [weak self] port in self?.doorTrouble(port) }
        gate.doorStalled = { [weak self] port in self?.probeDoor(port) }
        gate.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let witness):
                let c = URLSessionConfiguration.ephemeral
                c.proxyConfigurations = [witness]
                c.timeoutIntervalForRequest = 12
                c.timeoutIntervalForResource = 15
                c.urlCache = nil
                c.requestCachePolicy = .reloadIgnoringLocalCacheData
                self.witnessSession = URLSession(configuration: c)
                Self.importProvisionedKey()
                ready(true)
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
                ready(false)
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature =
                path.availableInterfaces.map { "\($0.type)\($0.index)" }.joined(separator: ",")
                + "|\(path.status)"
            DispatchQueue.main.async { self?.pathChanged(path, signature: signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.ipbrowser.path"))
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
            [weak self] _ in self?.backgroundedAt = Date()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            // After a long suspension the core's sessions are gone (iOS took its sockets): like a network change, a
            // fresh core that starts closed - pages wait until its kinds are verified again, instead of meeting a dead
            // route (a leak test right after a 20-minute pause said «the server does not answer», 21.11.2026).
            if let since = self.backgroundedAt, Date().timeIntervalSince(since) > 25, ProfileStore.shared.active != nil {
                self.log("back after \(Int(Date().timeIntervalSince(since))) s: fresh core")
                self.restartCore(keepingPages: true)
            }
            self.backgroundedAt = nil
        }
    }

    private func pathChanged(_ path: NWPath, signature: String) {
        // Offline = no physical network: a VPN tunnel or a cable link to a computer alone is
        // not the internet.
        offline =
            path.status != .satisfied
            || !path.availableInterfaces.contains { [.wifi, .cellular, .wiredEthernet].contains($0.type) }
        defer { lastPath = signature }
        guard lastPath != signature else { return }
        log("network: " + ConnectionLog.describe(path))
        guard lastPath != nil else { return }
        // Wi-Fi ↔ mobile or the network came back: the core's UDP session belongs to the old
        // path, so start a fresh core (same server, same exit) instead of waiting for its idle
        // timeout. Pages and forms stay; nothing can leak meanwhile. One restart per change,
        // after the path has been stable for 1.5 s (switching Wi-Fi off reports two or three
        // paths within a second).
        pathChange += 1
        let change = pathChange
        if case .verified(let ip) = state { state = .reconnecting(ip: ip) }
        diagnosis = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, change == self.pathChange else { return }
            if self.pathMonitor.currentPath.status == .satisfied, ProfileStore.shared.active != nil {
                self.log("network settled: fresh core")
                self.restartCore(keepingPages: true)
            } else {
                self.check(reason: "path")
            }
        }
    }

    /// Start (or switch to) a profile. Existing website connections are closed: a connection
    /// must never continue on another server's exit.
    func activate(_ profile: ServerProfile?) {
        generation += 1
        let gen = generation
        profileID = profile?.id
        setOpen(false)
        gate.setUpstream(nil)
        guard let profile else {
            XrayEngine.stop()
            state = .noProfile
            log("no server")
            return
        }
        log("server «\(profile.title)»: start (\(profile.kinds))")
        activatedAt = Date()
        diagnosis = nil
        lastDiagnosis = .distantPast
        state = .starting
        XrayEngine.start(links: profile.links) { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let running):
                self.gate.setUpstream(running)
                self.verify(gen: gen)
            case .failure(let error):
                self.log("core did not start: \(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Verify the exit again, showing «reconnecting» meanwhile (a resume, a manual retry).
    func check(reason: String) {
        guard ProfileStore.shared.active != nil, XrayEngine.current != nil else { return }
        switch state {
        case .verified(let ip): state = .reconnecting(ip: ip)
        case .mismatch, .noProfile: return
        default: break
        }
        verify(gen: generation)
    }

    /// A page failed: look at the kinds again without alarming anyone (at most every 15 s).
    func recheckSoon() { doorTrouble(nil) }

    /// A door lost a connection (or none could carry one): the witness re-checks every kind
    /// silently; a kind that does not answer stops carrying pages until it answers again.
    private func doorTrouble(_ port: Int?) {
        guard isOpen, !checking, Date().timeIntervalSince(lastTroubleCheck) > 15 else { return }
        lastTroubleCheck = Date()
        let gen = generation
        log("a kind lost a connection: re-check the kinds")
        recheck(gen: gen)
    }

    /// A request through this door heard nothing for too long: one quick question through it alone
    /// tells a dead path (UDP stopped on the way) from a slow site.
    private func probeDoor(_ port: Int) {
        guard let running = XrayEngine.current, let door = running.doors.first(where: { $0.port == port }),
            let exit = profile?.exitIPv4
        else {
            gate.doorProbed(port, alive: true)
            return
        }
        let limit = max(2.5, 2.5 * (doorSeconds[port] ?? 1))
        let gen = generation
        ask(through: door, of: running, urls: Self.witnessURLs.prefix(1), timeout: limit) { [weak self] ip, _ in
            guard let self, gen == self.generation else { return }
            let alive = ip == exit
            self.gate.doorProbed(port, alive: alive)
            if !alive {
                self.log("\(door.kind) stopped answering: pages go through the other kind")
                self.doorTrouble(port)
            }
        }
    }

    func restartCore() { activate(ProfileStore.shared.active) }

    /// A fresh core for the same server after a network change. Pages and forms stay as they
    /// are; new requests wait (LocalGate holds them) until the new core's kinds are verified
    /// again. If the new core does not start within 10 s the person sees it.
    func restartCore(keepingPages: Bool) {
        guard let profile = ProfileStore.shared.active else { return }
        generation += 1
        let gen = generation
        setOpen(false)
        if case .verified(let ip) = state { state = .reconnecting(ip: ip) }
        failingSince = Date()
        lastDiagnosis = .distantPast
        diagnosis = nil
        retryDelay = 1
        gate.setUpstream(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, gen == self.generation, XrayEngine.current == nil else { return }
            self.log("core did not restart within 10 s")
            self.state = .failed(L("core.stuck"))
        }
        XrayEngine.start(links: profile.links) { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let running):
                self.gate.setUpstream(running)
                self.verify(gen: gen)
            case .failure(let error):
                self.log("core did not restart: \(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func verify(gen: Int) {
        // One witness at a time; a check asked for meanwhile runs right after it, for the
        // generation current THEN (a dropped check left the browser stuck after a switch).
        guard !checking else {
            verifyAgain = true
            return
        }
        checking = true
        let started = Date()
        witnessKinds { [weak self] results in
            guard let self else { return }
            self.checking = false
            if self.verifyAgain {
                self.verifyAgain = false
                if gen != self.generation, XrayEngine.current != nil {
                    self.verify(gen: self.generation)
                    return
                }
            }
            guard gen == self.generation, let profile = self.profile else { return }
            guard let seen = self.admit(results, profile: profile) else {
                if ExitVerdict.decide(results, expected: profile.exitIPv4) == .silent {
                    self.noAnswer(results, profile: profile, gen: gen, since: started)
                }
                return
            }
            if case .verified = self.state {
            } else {
                self.log("exit check: \(seen) — " + Self.summary(results) + (self.isOpen ? "" : " — websites open"))
            }
            self.retryDelay = 1
            self.diagnosis = nil
            if profile.exitIPv4 == nil {
                // A raw key names no exit: the first one seen is the profile's from now on, for
                // every later check too (they read the stored profile).
                var pinned = profile
                pinned.exitIPv4 = seen
                try? ProfileStore.shared.upsert(pinned)
            }
            self.scheduleRecheck(gen: gen, missing: results.contains { $0.ip == nil })
            // The first time an exit address is seen, learn its time zone before the first page,
            // so no page ever sees the phone's clock next to the server's address (Region).
            let open = { [weak self] in
                guard let self, gen == self.generation else { return }
                self.setOpen(true)
                self.state = .verified(ip: seen)
            }
            if !Region.shared.isKnown(seen), let session = self.witnessSession {
                Region.shared.lookup(seen, through: session) { [weak self] zone in
                    self?.log("time zone of the exit: " + (zone ?? "not known yet, pages see the phone's clock"))
                    open()
                }
            } else {
                open()
            }
        }
    }

    /// No kind answers. Nothing can leak (no direct path), so keep the core and the pages as
    /// they are and keep asking; the core redials by itself. (Restarting the core here hung on a
    /// dead path: Streisand, 20.11.)
    private func noAnswer(_ results: [KindWitness], profile: ServerProfile, gen: Int, since started: Date) {
        log("exit check: no answer through the server (\(Int(Date().timeIntervalSince(started))) s)")
        if case .verified(let ip) = state {
            state = .reconnecting(ip: ip)
            failingSince = Date()
        } else if case .starting = state {
            state = .reconnecting(ip: profile.exitIPv4)
            failingSince = activatedAt
        }
        // After 20 s of silence, and again every 2 minutes, say which kind does not get through
        // from this network.
        if Date().timeIntervalSince(failingSince) > 20, Date().timeIntervalSince(lastDiagnosis) > 120 {
            describe(results, profile: profile)
        }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.verify(gen: gen)
        }
    }

    /// Apply a round of witnesses: the kinds that showed the profile's exit become the gate's
    /// doors (fastest first). Another exit closes the gate hard until the person decides.
    /// Returns the exit, or nil when the gate is not (or no longer) open for pages.
    private func admit(_ results: [KindWitness], profile: ServerProfile) -> String? {
        switch ExitVerdict.decide(results, expected: profile.exitIPv4) {
        case .silent:
            return nil
        case .kindsDiffer(let list):
            setOpen(false)
            gate.setVerified([])
            log("exit check: the kinds leave from different addresses (\(list)) — websites closed")
            state = .failed(String(format: L("exit.kindsDiffer"), list))
            return nil
        case .mismatch(let kind, let expected, let seen):
            setOpen(false)
            gate.setVerified([])
            log("exit check: \(kind) leaves from \(seen), the profile's address is \(expected) — websites closed")
            state = .mismatch(expected: expected, seen: seen)
            return nil
        case .open(let exit, var doors):
            #if DEBUG
            // lab: `-preferkind TCP` (or UDP) puts that kind first, to measure pages through it
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-preferkind"), i + 1 < args.count {
                doors = doors.filter { $0.kind.contains(args[i + 1]) } + doors.filter { !$0.kind.contains(args[i + 1]) }
            }
            #endif
            gate.setVerified(doors.map { (port: $0.port, seconds: $0.seconds) })
            for door in doors { doorSeconds[door.port] = door.seconds }
            return exit
        }
    }

    /// While the profile is open: a kind that did not answer is asked again (30 s, doubling to
    /// 5 min) and joins once its own exit is seen; every kind is re-verified every 10 min.
    /// Silent: the person sees nothing unless an exit changes (then the gate closes hard).
    private func scheduleRecheck(gen: Int, missing: Bool, delay: TimeInterval = 30) {
        guard recheckFor != gen || missing else { return }
        recheckFor = gen
        let wait = missing ? delay : 600
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, gen == self.generation, self.isOpen, !self.checking else { return }
            self.recheckFor = -1
            self.recheck(gen: gen, delay: delay)
        }
    }

    /// One silent round of witnesses for the running core.
    private func recheck(gen: Int, delay: TimeInterval = 30) {
        checking = true
        witnessKinds { [weak self] results in
            guard let self else { return }
            self.checking = false
            // A visible check asked for meanwhile (a switch, a resume) takes over.
            if self.verifyAgain {
                self.verifyAgain = false
                self.verify(gen: self.generation)
                return
            }
            guard gen == self.generation, self.isOpen, let profile = self.profile else { return }
            if ExitVerdict.decide(results, expected: profile.exitIPv4) == .silent {
                // Nothing answers any more: that is a reconnect the person should see.
                self.check(reason: "silent")
                return
            }
            guard self.admit(results, profile: profile) != nil else { return }
            let before = self.recheckSummary
            self.recheckSummary = Self.summary(results)
            if before != self.recheckSummary { self.log("kinds re-checked: " + self.recheckSummary) }
            let stillMissing = results.contains { $0.ip == nil }
            self.scheduleRecheck(gen: gen, missing: stillMissing, delay: stillMissing ? min(delay * 2, 300) : 30)
        }
    }

    private static func summary(_ results: [KindWitness]) -> String {
        results.map { "\($0.kind) " + ($0.ip != nil ? String(format: "%.1f s", $0.seconds) : "no answer") }
            .joined(separator: ", ")
    }

    /// Ask the exit's time zone again (Settings turned «server's clock» on for an exit not asked yet).
    func learnZone() {
        guard case .verified(let ip) = state, !Region.shared.isKnown(ip), let session = witnessSession else { return }
        Region.shared.lookup(ip, through: session) { [weak self] zone in
            self?.log("time zone of the exit: " + (zone ?? "not known yet, pages see the phone's clock"))
        }
    }

    /// A key placed into Documents/import-key.txt (first install by cable, lab runs) becomes a
    /// profile and the file is deleted at once.
    private static func importProvisionedKey() {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("import-key.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        do {
            let profile = try ProfileStore.shared.upsert(try AccessKey.decode(text))
            ProfileStore.shared.activeID = profile.id
            print("IPB_IMPORT ok kinds=\(profile.kinds)")
        } catch {
            print("IPB_IMPORT failed \(error.localizedDescription)")
        }
    }

    /// Plain words about which kind does not get through from this network (no extra probe: the
    /// witness just asked every kind).
    private func describe(_ results: [KindWitness], profile: ServerProfile) {
        lastDiagnosis = Date()
        let line = results.map { "\($0.kind): " + ($0.ip != nil ? L("diag.ok") : L("diag.fail")) }
            .joined(separator: " · ")
        let host = profile.management?.host ?? profile.exitIPv4 ?? ""
        let udpOnly = results.count == 1 && results[0].kind.contains("UDP")
        diagnosis = line + "\n" + String(format: L(udpOnly ? "diag.udpOnly" : "diag.none"), host)
        log("diagnosis: " + line)
    }

    /// One witness request through each kind's own door of the running core: which kinds get
    /// through from this network, from which address each leaves, and how fast.
    private static let witnessURLs = ["https://checkip.amazonaws.com/", "https://api.ipify.org/"].compactMap(
        URL.init(string:))

    func witnessKinds(_ done: @escaping ([KindWitness]) -> Void) {
        guard let running = XrayEngine.current, !running.doors.isEmpty else {
            done([])
            return
        }
        let group = DispatchGroup()
        var results = running.doors.map { KindWitness(kind: $0.kind, port: $0.port, ip: nil, seconds: 0) }
        for (i, door) in running.doors.enumerated() {
            group.enter()
            ask(through: door, of: running, urls: Self.witnessURLs[...], timeout: 10) { ip, seconds in
                if let ip { results[i] = KindWitness(kind: door.kind, port: door.port, ip: ip, seconds: seconds) }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(results) }
    }

    /// The exit address seen through one door of the core (the IP-echo services in turn), on main.
    private func ask(
        through door: XrayEngine.Door, of running: XrayEngine.Running, urls: ArraySlice<URL>,
        timeout: TimeInterval, done: @escaping (String?, TimeInterval) -> Void
    ) {
        var proxy = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(door.port))!))
        proxy.allowFailover = false
        proxy.applyCredential(username: running.user, password: running.password)
        let c = URLSessionConfiguration.ephemeral
        c.proxyConfigurations = [proxy]
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 2
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: c)
        let started = Date()
        func attempt(_ rest: ArraySlice<URL>) {
            guard let url = rest.first else {
                session.finishTasksAndInvalidate()
                DispatchQueue.main.async { done(nil, 0) }
                return
            }
            session.dataTask(with: url) { data, response, error in
                let text = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let text, IPv4Address(text) != nil {
                    let seconds = Date().timeIntervalSince(started)
                    session.finishTasksAndInvalidate()
                    DispatchQueue.main.async { done(text, seconds) }
                } else {
                    attempt(rest.dropFirst())
                }
            }.resume()
        }
        attempt(urls)
    }

    /// Accept a new exit address the person confirmed (e.g. the server moved).
    func acceptExit(_ ip: String) {
        guard var profile = ProfileStore.shared.active else { return }
        profile.exitIPv4 = ip
        try? ProfileStore.shared.upsert(profile)
        activate(profile)
    }
}
