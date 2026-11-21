import Foundation
import Network

/// The loopback door WebKit is configured with (`WKWebsiteDataStore.proxyConfigurations`,
/// `allowFailover = false`). Its port and credentials stay the same for the whole app session
/// while the tunnel core behind it restarts or switches servers, because WebKit applies a
/// proxy only to a data store configured before its first load.
///
/// Two roles with separate credentials: the browser (website CONNECTs, allowed only while the
/// gate is open) and the exit witness (only the IP-echo hosts). Other apps on the phone can
/// reach 127.0.0.1 too; without the session credential they get 407.
///
/// Every profile's website store carries its own browser credential, and the gate is open for
/// one profile at a time: a page, a worker or a leftover connection of another profile can
/// never ride the active profile's server.
///
/// Behind the gate the core has one door per masked kind. A page passes only through a door
/// whose own exit was verified to be the profile's address since this core started (the
/// TunnelController's witness, per kind). The core answers a CONNECT before it has reached
/// anything, so a door is trusted with a connection only once the site's first bytes came
/// back through it ("commit"). Until then the gate keeps what the browser sent and gives it to
/// the next verified door if this one closes without an answer and what it got cannot have had an
/// effect at the site (`isReplaySafe`), or, for a TLS handshake, also runs the next door alongside a
/// door that stays silent for longer than it should. A door that lost a
/// connection is tried last and reported, and the witness re-checks it.
///
/// A connection the browser keeps open (HTTP/2) cannot be handed over: when a request through it
/// hears nothing for longer than its door's patience while nothing at all comes through that door,
/// the door is probed once (`doorStalled`); a door found dead stops carrying pages and its silent
/// connections are closed, so WebKit opens new ones through a door that answers.
final class LocalGate {
    struct Upstream: Equatable {
        let port: Int
        let authorization: String
        /// How long the site's first answer may take through this door before the next door
        /// is tried alongside it (TLS only).
        let patience: TimeInterval
    }

    enum Admission: Equatable {
        case through([Upstream])
        case wait, refuse
    }

    /// The IP-echo hosts, and the time-zone services asked once per exit address (Region).
    static let witnessHosts: Set<String> = [
        "checkip.amazonaws.com:443", "api.ipify.org:443", "ipapi.co:443", "ipwho.is:443", "api.ip.sb:443",
    ]

    /// How long a page's CONNECT waits for its profile's route to be verified.
    var holdLimit: TimeInterval = 12

    private let queue = DispatchQueue(label: "app.ipbrowser.gate", qos: .userInitiated)
    private var listener: NWListener?
    private var bridges: [UUID: Bridge] = [:]
    private let witnessPassword = UUID().uuidString + UUID().uuidString
    /// Browser credentials of this app run: Basic authorization -> profile.
    private var profileOf: [String: UUID] = [:]
    private var passwords: [UUID: String] = [:]
    /// The profile the tunnel runs for, and whether its pages may pass now.
    private var profile: UUID?
    private var open = false
    /// The core's doors (one per kind) and those verified, fastest first, with their latency.
    private var doors: [XrayEngine.Door] = []
    private var authorization = ""
    private var verified: [Int] = []
    private var latency: [Int: TimeInterval] = [:]
    private var held: [(bridge: Bridge, since: Date)] = []
    private(set) var port: NWEndpoint.Port?
    /// Called on main when a door lost a connection (its port), or when no door could carry
    /// one (nil).
    var upstreamFailure: ((Int?) -> Void)?
    /// Called on main when a request through a door heard nothing for too long: probe that door and
    /// answer with `doorProbed`.
    var doorStalled: ((Int) -> Void)?
    private var probing: Set<Int> = []
    /// A probe just proved the door alive (a slow site, not a dead path): no new probe until then.
    private var aliveUntil: [Int: Date] = [:]
    private var sweepScheduled = false

    func start(completion: @escaping (Result<ProxyConfiguration, Error>) -> Void) {
        queue.async { [self] in
            do {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                parameters.allowLocalEndpointReuse = false
                let listener = try NWListener(using: parameters)
                self.listener = listener
                var completed = false
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard !completed, let port = listener.port else { return }
                        completed = true
                        self.port = port
                        let witness = Self.proxy(port: port, user: "witness", password: self.witnessPassword)
                        DispatchQueue.main.async { completion(.success(witness)) }
                    case .failed(let error):
                        guard !completed else { return }
                        completed = true
                        DispatchQueue.main.async { completion(.failure(error)) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { client in
                    guard self.bridges.count < 160 else {
                        client.cancel()
                        return
                    }
                    let id = UUID()
                    let bridge = Bridge(client: client, queue: self.queue, gate: self) { [weak self] in
                        self?.bridges.removeValue(forKey: id)
                    }
                    self.bridges[id] = bridge
                    bridge.start()
                }
                listener.start(queue: self.queue)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func proxy(port: NWEndpoint.Port, user: String, password: String) -> ProxyConfiguration {
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
        proxy.allowFailover = false
        proxy.excludedDomains = []
        proxy.matchDomains = []
        proxy.applyCredential(username: user, password: password)
        return proxy
    }

    /// The proxy of one profile's website store (main thread; once per profile per app run:
    /// WebKit takes a store's proxy only before its first load).
    func browserProxy(for profile: UUID) -> ProxyConfiguration? {
        guard let port else { return nil }
        let password = queue.sync { () -> String in
            if let existing = passwords[profile] { return existing }
            let created = UUID().uuidString + UUID().uuidString
            passwords[profile] = created
            profileOf[Self.basic(Self.user(profile), created)] = profile
            return created
        }
        return Self.proxy(port: port, user: Self.user(profile), password: password)
    }

    private static func user(_ profile: UUID) -> String { "p-" + profile.uuidString.prefix(8).lowercased() }
    private static func basic(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    func credential(for space: URLProtectionSpace, profile: UUID) -> URLCredential? {
        guard space.isProxy(), space.host == "127.0.0.1", space.port == Int(port?.rawValue ?? 0),
            let password = queue.sync(execute: { passwords[profile] })
        else { return nil }
        return URLCredential(user: Self.user(profile), password: password, persistence: .forSession)
    }

    /// The core behind the gate. Nil = no tunnel: every CONNECT is refused locally. A new core
    /// starts with no verified door: pages wait for the witness.
    func setUpstream(_ running: XrayEngine.Running?) {
        queue.async {
            self.doors = running?.doors ?? []
            self.authorization = running?.authorization ?? ""
            self.verified = []
            self.latency = [:]
            self.probing = []
            self.aliveUntil = [:]
            if running == nil { self.closeAll(includingWitness: true) }
        }
    }

    /// The doors whose exit the witness saw as the profile's address, fastest first, with the
    /// time the witness took through each.
    func setVerified(_ list: [(port: Int, seconds: TimeInterval)]) {
        queue.async {
            let known = list.filter { item in self.doors.contains { $0.port == item.port } }
            self.verified = known.map(\.port)
            self.latency = Dictionary(known.map { ($0.port, $0.seconds) }, uniquingKeysWith: { first, _ in first })
            self.release()
            self.sweep()
        }
    }

    /// The verdict of the probe asked for by `doorStalled`.
    func doorProbed(_ port: Int, alive: Bool) {
        queue.async {
            self.probing.remove(port)
            if alive {
                self.aliveUntil[port] = Date().addingTimeInterval(60)
                return
            }
            if let i = self.verified.firstIndex(of: port), self.verified.count > 1 { self.verified.remove(at: i) }
            self.sweep()
        }
    }

    fileprivate func scheduleSweep() {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.sweepScheduled = false
            self?.sweep()
        }
    }

    /// The committed connections, door by door: a door the witness no longer trusts loses its silent
    /// connections (while another door is trusted); a trusted door through which a request heard
    /// nothing for longer than its patience, and nothing else came either, is probed.
    private func sweep() {
        let now = Date()
        var byPort: [Int: [Bridge]] = [:]
        for bridge in bridges.values { if let port = bridge.committedPort { byPort[port, default: []].append(bridge) } }
        guard !byPort.isEmpty else { return }
        for (port, list) in byPort {
            let patience = Self.patience(after: latency[port])
            if !verified.contains(port) {
                guard !verified.isEmpty else { continue }
                for bridge in list where now.timeIntervalSince(bridge.heardAt) > patience { bridge.stop() }
                continue
            }
            let heard = list.map(\.heardAt).max() ?? .distantPast
            guard verified.count > 1, !probing.contains(port), (aliveUntil[port] ?? .distantPast) < now,
                let asked = list.compactMap(\.askedAt).min(),
                now.timeIntervalSince(max(heard, asked)) > max(2, patience)
            else { continue }
            probing.insert(port)
            if let i = verified.firstIndex(of: port) { verified.append(verified.remove(at: i)) }
            DispatchQueue.main.async { self.doorStalled?(port) }
        }
        scheduleSweep()
    }

    /// The profile the tunnel runs for, open or still being verified (nil = none). Every
    /// website connection of any other profile is cut; while not open, its own pages wait.
    func setProfile(_ id: UUID?, open: Bool) {
        queue.async {
            self.profile = id
            self.open = open && id != nil
            for bridge in Array(self.bridges.values) where !bridge.isWitness {
                let foreign = id == nil || bridge.profile != id
                if foreign || (!self.open && bridge.admittedThrough) { bridge.stop() }
            }
            self.release()
        }
    }

    /// A door lost a connection before the site answered through it: try it last from now on
    /// and let the witness look at it.
    fileprivate func doorFailed(_ port: Int) {
        if let i = verified.firstIndex(of: port), verified.count > 1 { verified.append(verified.remove(at: i)) }
        DispatchQueue.main.async { self.upstreamFailure?(port) }
    }

    /// No verified door could carry a connection.
    fileprivate func routeFailed() { DispatchQueue.main.async { self.upstreamFailure?(nil) } }

    fileprivate func hold(_ bridge: Bridge) {
        held.append((bridge, Date()))
        queue.asyncAfter(deadline: .now() + holdLimit) { [weak self, weak bridge] in
            guard let self, let bridge, let i = self.held.firstIndex(where: { $0.bridge === bridge }) else { return }
            self.held.remove(at: i)
            bridge.admit()
        }
    }

    /// Held CONNECTs go on once their profile is open with a verified door (or are refused).
    private func release() {
        guard !held.isEmpty, open, !verified.isEmpty else { return }
        let waiting = held
        held.removeAll()
        for item in waiting { item.bridge.admit() }
    }

    func closeAll() { queue.async { self.closeAll(includingWitness: true) } }

    private func closeAll(includingWitness: Bool) {
        for bridge in Array(bridges.values) where includingWitness || !bridge.isWitness { bridge.stop() }
    }

    /// Which role an authorization is: the witness, a profile's browser, or nothing (407).
    fileprivate func role(of authorization: String) -> (witness: Bool, profile: UUID?)? {
        if authorization == Self.basic("witness", witnessPassword) { return (true, nil) }
        if let p = profileOf[authorization] { return (false, p) }
        return nil
    }

    /// Where a CONNECT may go: the witness through any door (verified first; it only reaches the
    /// IP-echo and time-zone services), a page only through verified doors of the open profile;
    /// the active profile's pages wait while its exit is being verified.
    fileprivate func admission(witness: Bool, profile: UUID?, mayWait: Bool) -> Admission {
        Self.admission(
            witness: witness, profile: profile, mayWait: mayWait, activeProfile: self.profile, open: open,
            doors: doors.map(\.port), verified: verified, latency: latency, authorization: authorization)
    }

    /// The admission rule itself, without state (unit-tested).
    static func admission(
        witness: Bool, profile: UUID?, mayWait: Bool, activeProfile: UUID?, open: Bool, doors: [Int],
        verified: [Int], latency: [Int: TimeInterval], authorization: String
    ) -> Admission {
        func upstream(_ port: Int) -> Upstream {
            Upstream(port: port, authorization: authorization, patience: patience(after: latency[port]))
        }
        if witness {
            let ordered = verified + doors.filter { !verified.contains($0) }
            return ordered.isEmpty ? .refuse : .through(ordered.map(upstream))
        }
        guard let profile, profile == activeProfile else { return .refuse }
        if open, !verified.isEmpty { return .through(verified.map(upstream)) }
        return mayWait ? .wait : .refuse
    }

    /// Bytes that may be sent to a site a second time: TLS handshake records only (a ClientHello: nothing
    /// has happened at the site before its answer; early application data is not), or one request of an
    /// idempotent HTTP method (RFC 9110 9.2.2). A plain POST and anything after it are never repeated.
    static func isReplaySafe(_ data: Data) -> Bool { isHandshakeOnly(data) || isIdempotentRequest(data) }

    static func isHandshakeOnly(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return false }
        var offset = 0
        while offset < bytes.count {
            guard bytes[offset] == 0x16 else { return false }
            guard offset + 5 <= bytes.count else { return true }  // the rest of this record is still coming
            offset += 5 + (Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4]))
        }
        return true
    }

    static func isIdempotentRequest(_ data: Data) -> Bool {
        guard let space = data.firstIndex(of: 0x20), space - data.startIndex <= 8,
            let method = String(data: data[data.startIndex..<space], encoding: .ascii),
            ["GET", "HEAD", "OPTIONS", "TRACE"].contains(method)
        else { return false }
        // exactly one request, nothing pipelined after it
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return true }
        return end.upperBound == data.endIndex
    }

    /// A TLS server answers a ClientHello within about the time the witness's whole request
    /// took through the same door; twice that, within 1.5-6 s, before the next door joins in.
    static func patience(after witnessSeconds: TimeInterval?) -> TimeInterval {
        guard let witnessSeconds else { return 3 }
        return min(max(witnessSeconds * 2, 1.5), 6)
    }
}

/// One browser connection: the CONNECT request, the admission, then the doors tried for it
/// until one carries the site's answer.
private final class Bridge {
    /// One try through one door of the core.
    private final class Attempt {
        let upstream: LocalGate.Upstream
        let connection: NWConnection
        /// The core accepted the CONNECT: what the browser sent goes to this door too.
        var accepted = false
        var sent = 0
        init(upstream: LocalGate.Upstream, connection: NWConnection) {
            self.upstream = upstream
            self.connection = connection
        }
    }

    private static let replayLimit = 256 * 1024

    private let client: NWConnection
    private let queue: DispatchQueue
    private weak var gate: LocalGate?
    private let finish: () -> Void
    private var header = Data()
    private var stopped = false
    private var waited = false
    private var target = ""
    /// What the browser sent before a door was committed (replayed through the next door).
    private var pending = Data()
    private var replayable = true
    /// A door that closed before answering was given one more try (when it was the only one left).
    private var retried = false
    private var candidates: [LocalGate.Upstream] = []
    private var attempts: [Attempt] = []
    private var committed: Attempt?
    private(set) var isWitness = false
    /// The door carrying this connection once committed, when it last sent anything, and since when
    /// the browser has been waiting for it (nil = not waiting).
    private(set) var committedPort: Int?
    private(set) var heardAt = Date()
    private(set) var askedAt: Date?
    /// The browser was told «connected» (a door was chosen for it).
    private(set) var admittedThrough = false
    /// The profile whose page opened this connection (nil for the witness).
    private(set) var profile: UUID?

    init(client: NWConnection, queue: DispatchQueue, gate: LocalGate, finish: @escaping () -> Void) {
        self.client = client
        self.queue = queue
        self.gate = gate
        self.finish = finish
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        client.start(queue: queue)
        // WebKit may open an idle local socket and never send CONNECT, and a connection whose
        // doors all stay silent must end too.
        queue.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self, self.committed == nil else { return }
            if self.admittedThrough { self.gate?.routeFailed() }
            self.stop()
        }
        readHeader()
    }

    private func readHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self, !self.stopped else { return }
            if let data { self.header.append(data) }
            guard self.header.count <= 32_768 else {
                self.reject(431)
                return
            }
            if let range = self.header.range(of: Data("\r\n\r\n".utf8)) {
                self.request(header: self.header[..<range.lowerBound], remainder: self.header[range.upperBound...])
            } else if done || error != nil {
                self.stop()
            } else {
                self.readHeader()
            }
        }
    }

    private func request(header: Data.SubSequence, remainder: Data.SubSequence) {
        guard let text = String(data: header, encoding: .utf8) else {
            reject(400)
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[0] == "CONNECT", first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else {
            reject(405)
            return
        }
        let auths = lines.dropFirst().filter { $0.lowercased().hasPrefix("proxy-authorization:") }
        guard auths.count == 1,
            let authorization = auths[0].split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces),
            let role = gate?.role(of: authorization)
        else {
            reject(407)
            return
        }
        let target = String(first[1])
        guard target.utf8.count < 300, !target.contains("@"), !target.contains("/"),
            let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]),
            (1...65535).contains(port)
        else {
            reject(400)
            return
        }
        isWitness = role.witness
        profile = role.profile
        if isWitness, !LocalGate.witnessHosts.contains(target.lowercased()) {
            reject(403)
            return
        }
        self.target = target
        pending = Data(remainder)
        self.header.removeAll()
        admit()
    }

    /// Ask the gate where this CONNECT may go (again after a wait).
    func admit() {
        guard !stopped, let gate else { return }
        let decision = gate.admission(witness: isWitness, profile: profile, mayWait: !waited)
        trace(decision)
        switch decision {
        case .refuse: reject(503)
        case .wait:
            waited = true
            gate.hold(self)
        case .through(let list):
            candidates = list
            // The browser sends its first bytes (a TLS ClientHello) only after «connected»; they
            // are kept until a door carries the answer.
            admittedThrough = true
            client.send(
                content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                completion: .contentProcessed { [weak self] error in
                    guard let self, !self.stopped else { return }
                    if error != nil {
                        self.stop()
                        return
                    }
                    self.readClient()
                    self.tryNextDoor()
                })
        }
    }

    // MARK: doors

    /// Dial the next candidate door; with nothing left and nothing running, the connection ends.
    private func tryNextDoor() {
        guard !stopped, committed == nil else { return }
        guard !candidates.isEmpty, replayable else {
            if attempts.isEmpty {
                gate?.routeFailed()
                stop()
            }
            return
        }
        let upstream = candidates.removeFirst()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .loopback
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(upstream.port))!,
            using: parameters)
        let attempt = Attempt(upstream: upstream, connection: connection)
        attempts.append(attempt)
        connection.stateUpdateHandler = { [weak self, weak attempt] state in
            guard let self, let attempt, !self.stopped else { return }
            switch state {
            case .ready:
                let request =
                    "CONNECT \(self.target) HTTP/1.1\r\nHost: \(self.target)\r\n"
                    + "Proxy-Authorization: \(upstream.authorization)\r\n\r\n"
                connection.send(
                    content: Data(request.utf8),
                    completion: .contentProcessed { [weak self] error in
                        guard let self, !self.stopped else { return }
                        if error != nil {
                            self.lost(attempt)
                            return
                        }
                        self.readCoreReply(attempt)
                    })
            case .failed: self.lost(attempt)
            default: break
            }
        }
        connection.start(queue: queue)
        armPatience(attempt)
    }

    /// A TLS site answers the ClientHello at once; a door silent for longer than its patience gets
    /// the next door alongside (never for other protocols: their request could reach the site twice).
    private func armPatience(_ attempt: Attempt) {
        queue.asyncAfter(deadline: .now() + attempt.upstream.patience) { [weak self, weak attempt] in
            guard let self, let attempt, !self.stopped, self.committed == nil, self.attempts.last === attempt else {
                return
            }
            if self.pending.isEmpty {
                self.armPatience(attempt)
                return
            }  // the browser has not asked yet
            if LocalGate.isHandshakeOnly(self.pending) { self.tryNextDoor() }
        }
    }

    /// The core's own reply to the CONNECT («200» comes before it reached anything).
    private func readCoreReply(_ attempt: Attempt, buffer: Data = Data()) {
        attempt.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self, weak attempt] data, _, done, error in
            guard let self, let attempt, !self.stopped, self.attempts.contains(where: { $0 === attempt }) else {
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
                guard head.split(separator: " ").dropFirst().first == "200" else {
                    self.lost(attempt)
                    return
                }
                attempt.accepted = true
                self.forward(to: attempt)
                let rest = Data(buffer[range.upperBound...])
                if !rest.isEmpty { self.commit(attempt, first: rest) } else { self.awaitAnswer(attempt) }
            } else if done || error != nil || buffer.count > 16_384 {
                self.lost(attempt)
            } else {
                self.readCoreReply(attempt, buffer: buffer)
            }
        }
    }

    /// The site's first bytes through this door decide it.
    private func awaitAnswer(_ attempt: Attempt) {
        attempt.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self, weak attempt] data, _, done, error in
            guard let self, let attempt, !self.stopped, self.attempts.contains(where: { $0 === attempt }) else {
                return
            }
            if let data, !data.isEmpty {
                self.commit(attempt, first: data)
            } else if done || error != nil {
                self.lost(attempt)
            } else {
                self.awaitAnswer(attempt)
            }
        }
    }

    /// A door closed or failed before the site answered through it.
    private func lost(_ attempt: Attempt) {
        guard let i = attempts.firstIndex(where: { $0 === attempt }) else { return }
        attempts.remove(at: i)
        attempt.connection.cancel()
        // What already went through this door may have reached the site: it is given to another door
        // only if that cannot have had an effect there.
        if attempt.sent > 0, !LocalGate.isReplaySafe(pending) { replayable = false }
        // The only door left closed before answering (a stream lost on the way, not a dead path - a dead path
        // is the stall probe's business): what may be repeated is tried through it once more, after a moment.
        if attempts.isEmpty, candidates.isEmpty, replayable, !retried {
            retried = true
            candidates = [attempt.upstream]
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.tryNextDoor() }
            return
        }
        gate?.doorFailed(attempt.upstream.port)
        #if DEBUG
        if !isWitness { print("IPB_GATE \(target) door \(attempt.upstream.port) lost before an answer") }
        #endif
        if attempts.isEmpty { tryNextDoor() }
    }

    private func commit(_ attempt: Attempt, first: Data) {
        guard committed == nil else { return }
        committed = attempt
        for other in attempts where other !== attempt {
            other.connection.cancel()
            // It was asked first and stayed silent while this one answered.
            gate?.doorFailed(other.upstream.port)
        }
        attempts = [attempt]
        pending = Data()
        committedPort = attempt.upstream.port
        heardAt = Date()
        askedAt = nil
        gate?.scheduleSweep()
        #if DEBUG
        if !isWitness { print("IPB_GATE \(target) committed to door \(attempt.upstream.port)") }
        #endif
        client.send(
            content: first,
            completion: .contentProcessed { [weak self] error in
                guard let self, !self.stopped else { return }
                if error != nil {
                    self.stop()
                    return
                }
                self.relayAnswers(from: attempt.connection)
            })
    }

    // MARK: bytes

    /// What the browser sends: kept for a replay until a door is committed, then relayed.
    private func readClient() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                if let committed = self.committed {
                    if self.askedAt == nil { self.askedAt = Date() }
                    committed.connection.send(
                        content: data,
                        completion: .contentProcessed { [weak self] error in
                            guard let self, !self.stopped else { return }
                            if error != nil { self.stop() } else { self.readClient() }
                        })
                    return
                }
                self.pending.append(data)
                if self.pending.count > Self.replayLimit { self.replayable = false }
                for attempt in self.attempts where attempt.accepted { self.forward(to: attempt) }
            }
            if done || error != nil { self.stop() } else { self.readClient() }
        }
    }

    /// Bring a door up to date with what the browser has sent so far.
    private func forward(to attempt: Attempt) {
        guard pending.count > attempt.sent else { return }
        let chunk = pending.subdata(in: attempt.sent..<pending.count)
        attempt.sent = pending.count
        attempt.connection.send(
            content: chunk,
            completion: .contentProcessed { [weak self, weak attempt] error in
                guard let self, let attempt, error != nil, self.committed !== attempt else { return }
                self.lost(attempt)
            })
    }

    /// The site's bytes to the browser, noting that the door is alive.
    private func relayAnswers(from upstream: NWConnection) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.heardAt = Date()
                self.askedAt = nil
                self.client.send(
                    content: data,
                    completion: .contentProcessed { [weak self] sendError in
                        guard let self, !self.stopped else { return }
                        if sendError != nil || error != nil || done {
                            self.stop()
                        } else {
                            self.relayAnswers(from: upstream)
                        }
                    })
            } else if done || error != nil {
                self.stop()
            } else {
                self.relayAnswers(from: upstream)
            }
        }
    }

    private func reject(_ status: Int) {
        let auth = status == 407 ? "Proxy-Authenticate: Basic realm=\"local\"\r\n" : ""
        let reply = "HTTP/1.1 \(status) Unavailable\r\n\(auth)Content-Length: 0\r\nConnection: close\r\n\r\n"
        client.send(content: Data(reply.utf8), completion: .contentProcessed { [weak self] _ in self?.stop() })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        #if DEBUG
        if !isWitness, !target.isEmpty { print("IPB_GATE \(target) closed committed=\(committed != nil)") }
        #endif
        client.cancel()
        for attempt in attempts { attempt.connection.cancel() }
        attempts.removeAll()
        finish()
    }

    private func trace(_ decision: LocalGate.Admission) {
        #if DEBUG
        guard !isWitness else { return }
        switch decision {
        case .through(let list): print("IPB_GATE \(target) through \(list.count) verified door(s)")
        case .wait: print("IPB_GATE \(target) wait")
        case .refuse: print("IPB_GATE \(target) refuse")
        }
        #endif
    }
}
