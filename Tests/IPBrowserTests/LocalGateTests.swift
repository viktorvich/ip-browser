import Network
import XCTest

@testable import IPBrowser

/// A stand-in for one door of the core. Like Xray's HTTP inbound it answers «200» to any CONNECT at
/// once, before it reached anything, and then behaves as told: stays silent (UDP lost on the way to
/// the server), closes, or answers as a site would.
private final class FakeDoor {
    enum Behaviour { case silent, closes, answers, closesFirstThenAnswers }

    private let behaviour: Behaviour
    private let queue = DispatchQueue(label: "test.door")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var bytes = Data()
    private var served = 0

    init(_ behaviour: Behaviour) throws {
        self.behaviour = behaviour
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }
    /// What reached the «site» through this door.
    var received: Data { queue.sync { bytes } }

    func start() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                if case .ready = state, !resumed {
                    resumed = true
                    done.resume()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        readHead(connection, Data())
    }

    private func readHead(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                connection.send(
                    content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .idempotent)
                let rest = Data(buffer[range.upperBound...])
                if !rest.isEmpty { self.handle(connection, rest) }
                self.readBody(connection)
            } else if !done {
                self.readHead(connection, buffer)
            }
        }
    }

    private func readBody(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, _ in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(connection, data) }
            if !done { self.readBody(connection) }
        }
    }

    private func handle(_ connection: NWConnection, _ data: Data) {
        bytes.append(data)
        switch behaviour {
        case .silent: break
        case .closes: connection.cancel()
        case .answers: connection.send(content: Data("ANSWER:".utf8) + data, completion: .idempotent)
        case .closesFirstThenAnswers:
            served += 1
            if served == 1 {
                connection.cancel()
            } else {
                connection.send(content: Data("ANSWER:".utf8) + data, completion: .idempotent)
            }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }
}

/// A browser-side connection to the gate: everything it receives collects in a buffer.
private final class Client {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.client")
    private var buffer = Data()

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if !done, error == nil { self.read() }
        }
    }

    func send(_ data: Data) { connection.send(content: data, completion: .idempotent) }

    /// What arrived since the last call, or nil if nothing came within the time.
    func receive(within seconds: TimeInterval) async -> Data? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let taken: Data = queue.sync {
                defer { buffer.removeAll() }
                return buffer
            }
            if !taken.isEmpty {
                // the rest of a burst
                try? await Task.sleep(nanoseconds: 50_000_000)
                return taken
                    + queue.sync {
                        defer { buffer.removeAll() }
                        return buffer
                    }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    func close() { connection.cancel() }
}

final class LocalGateTests: XCTestCase {
    private var gate: LocalGate!
    private var doors: [FakeDoor] = []
    private let profile = UUID()
    private var authorization = ""
    private var failures: [Int?] = []

    override func setUp() async throws {
        gate = LocalGate()
        let started = expectation(description: "gate")
        gate.start { result in
            if case .success = result { started.fulfill() }
        }
        await fulfillment(of: [started], timeout: 5)
        _ = await MainActor.run { gate.browserProxy(for: profile) }
        let space = URLProtectionSpace(
            proxyHost: "127.0.0.1", port: Int(gate.port!.rawValue),
            type: NSURLProtectionSpaceHTTPSProxy, realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credential = try XCTUnwrap(gate.credential(for: space, profile: profile))
        authorization = "Basic " + Data("\(credential.user!):\(credential.password!)".utf8).base64EncodedString()
        gate.upstreamFailure = { [weak self] port in self?.failures.append(port) }
    }

    override func tearDown() {
        gate.closeAll()
        doors.forEach { $0.stop() }
    }

    /// Doors in the order given, each verified with the witness time given.
    private func core(_ list: [(FakeDoor.Behaviour, TimeInterval)]) async throws -> [FakeDoor] {
        var made: [FakeDoor] = []
        for (behaviour, _) in list {
            let door = try FakeDoor(behaviour)
            await door.start()
            made.append(door)
        }
        doors += made
        let running = XrayEngine.Running(
            doors: made.enumerated().map { XrayEngine.Door(kind: "kind\($0.offset)", port: $0.element.port) },
            user: "u", password: "p")
        gate.setUpstream(running)
        gate.setProfile(profile, open: true)
        gate.setVerified(zip(made, list).map { (port: $0.0.port, seconds: $0.1.1) })
        return made
    }

    private func connect(_ target: String = "example.com:443", authorization: String? = nil) async -> (Client, String) {
        let client = Client(port: gate.port!.rawValue)
        client.send(
            Data(
                "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\nProxy-Authorization: \(authorization ?? self.authorization)\r\n\r\n"
                    .utf8))
        let head = await client.receive(within: 3).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (client, head)
    }

    /// The review's case (21.11): UDP lost on the way, so the first door says «200» and then nothing.
    /// The TLS ClientHello is handed to the next verified door within the first door's patience, the
    /// page gets the site's answer, and the silent door is reported.
    func testSilentDoorHandsTlsToTheNextDoor() async throws {
        let (silent, good) = try await core([(.silent, 0.5), (.answers, 1.0)]).pair
        let (client, head) = await connect()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        let hello = Data([0x16, 0x03, 0x01, 0x00, 0x04, 1, 2, 3, 4])
        let sent = Date()
        client.send(hello)
        let answer = await client.receive(within: 6)
        let elapsed = Date().timeIntervalSince(sent)
        XCTAssertEqual(answer, Data("ANSWER:".utf8) + hello)
        XCTAssertGreaterThan(elapsed, 1.3, "the first door had its patience (1.5 s)")
        XCTAssertLessThan(elapsed, 4)
        XCTAssertEqual(silent.received, hello, "the silent door got the ClientHello first")
        XCTAssertEqual(good.received, hello)
        try await Task.sleep(nanoseconds: 200_000_000)
        let reported = await MainActor.run { failures }
        XCTAssertTrue(reported.contains(silent.port), "the silent door is reported for a re-check")
        client.close()
    }

    /// A door that closes before the site answered: the same bytes go through the next door at once.
    func testClosingDoorHandsTheRequestOver() async throws {
        let (_, good) = try await core([(.closes, 0.5), (.answers, 1.0)]).pair
        let (client, head) = await connect("example.com:80")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        let request = Data("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
        let sent = Date()
        client.send(request)
        let answer = await client.receive(within: 4)
        XCTAssertEqual(answer, Data("ANSWER:".utf8) + request)
        XCTAssertLessThan(Date().timeIntervalSince(sent), 1.2)
        XCTAssertEqual(good.received, request, "the request reached the site once")
        client.close()
    }

    /// Not TLS: a silent door is never doubled by another one (the request could reach the site twice).
    func testPlainRequestIsNeverSentTwice() async throws {
        let (_, good) = try await core([(.silent, 0.5), (.answers, 1.0)]).pair
        let (client, _) = await connect("example.com:80")
        client.send(Data("POST /order HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n".utf8))
        let answer = await client.receive(within: 3)
        XCTAssertNil(answer)
        XCTAssertTrue(good.received.isEmpty)
        client.close()
    }

    /// A door that took a plain POST and closed before any answer: the POST may have reached the site, so it
    /// is never sent through another door (review of build 21, 21.11.2026).
    func testClosingDoorNeverResendsAPost() async throws {
        let (closing, good) = try await core([(.closes, 0.5), (.answers, 1.0)]).pair
        let (client, head) = await connect("example.com:80")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        let post = Data("POST /order HTTP/1.1\r\nHost: example.com\r\nContent-Length: 2\r\n\r\nok".utf8)
        client.send(post)
        let answer = await client.receive(within: 3)
        XCTAssertNil(answer)
        XCTAssertEqual(closing.received, post)
        XCTAssertTrue(good.received.isEmpty, "the POST reached a site once at most")
        client.close()
    }

    /// The only door loses a stream before the site answered: a TLS handshake goes through it once more by itself.
    func testOnlyDoorGetsOneMoreTryForAHandshake() async throws {
        let flaky = try FakeDoor(.closesFirstThenAnswers)
        await flaky.start()
        doors.append(flaky)
        gate.setUpstream(
            XrayEngine.Running(doors: [XrayEngine.Door(kind: "k", port: flaky.port)], user: "u", password: "p"))
        gate.setProfile(profile, open: true)
        gate.setVerified([(port: flaky.port, seconds: 1)])
        let (client, head) = await connect()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        let hello = Data([0x16, 0x03, 0x01, 0x00, 0x02, 7, 7])
        client.send(hello)
        let answer = await client.receive(within: 3)
        XCTAssertEqual(answer, Data("ANSWER:".utf8) + hello)
        client.close()
    }

    func testReplayRule() {
        let hello = Data([0x16, 0x03, 0x01, 0x00, 0x04, 1, 2, 3, 4])
        XCTAssertTrue(LocalGate.isHandshakeOnly(hello))
        XCTAssertTrue(LocalGate.isHandshakeOnly(hello + Data([0x16, 0x03, 0x03, 0x01])), "a record still coming")
        XCTAssertFalse(LocalGate.isHandshakeOnly(hello + Data([0x17, 0x03, 0x03, 0x00, 0x01, 9])), "early data")
        XCTAssertTrue(LocalGate.isReplaySafe(Data("GET / HTTP/1.1\r\nHost: a\r\n\r\n".utf8)))
        XCTAssertTrue(LocalGate.isReplaySafe(Data("HEAD / HTTP/1.1\r\n".utf8)))
        XCTAssertFalse(LocalGate.isReplaySafe(Data("POST / HTTP/1.1\r\nHost: a\r\n\r\n".utf8)))
        XCTAssertFalse(
            LocalGate.isReplaySafe(Data("GET / HTTP/1.1\r\n\r\nPOST / HTTP/1.1\r\n\r\n".utf8)),
            "a pipelined POST after a GET")
        XCTAssertFalse(LocalGate.isReplaySafe(Data()))
    }

    func testWrongCredentialAndOtherProfileAreRefused() async throws {
        _ = try await core([(.answers, 1.0)])
        let (stranger, head407) = await connect(authorization: "Basic " + Data("x:y".utf8).base64EncodedString())
        XCTAssertTrue(head407.hasPrefix("HTTP/1.1 407"), head407)
        stranger.close()
        let other = UUID()
        _ = await MainActor.run { gate.browserProxy(for: other) }
        let space = URLProtectionSpace(
            proxyHost: "127.0.0.1", port: Int(gate.port!.rawValue),
            type: NSURLProtectionSpaceHTTPSProxy, realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credential = try XCTUnwrap(gate.credential(for: space, profile: other))
        let (foreign, head503) = await connect(
            authorization: "Basic "
                + Data("\(credential.user!):\(credential.password!)".utf8).base64EncodedString())
        XCTAssertTrue(head503.hasPrefix("HTTP/1.1 503"), "another profile never rides this server: \(head503)")
        foreign.close()
    }

    /// While the profile's exit is being verified a page waits, and goes on once a door is verified.
    func testPageWaitsForVerification() async throws {
        let door = try FakeDoor(.answers)
        await door.start()
        doors.append(door)
        gate.setUpstream(
            XrayEngine.Running(doors: [XrayEngine.Door(kind: "k", port: door.port)], user: "u", password: "p"))
        gate.setProfile(profile, open: false)
        let client = Client(port: gate.port!.rawValue)
        client.send(Data("CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: \(authorization)\r\n\r\n".utf8))
        let early = await client.receive(within: 1)
        XCTAssertNil(early, "held, not refused")
        gate.setProfile(profile, open: true)
        gate.setVerified([(port: door.port, seconds: 1)])
        let head = await client.receive(within: 3).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        client.close()
    }

    func testAdmissionRule() {
        let a = UUID()
        let b = UUID()
        func admit(
            witness: Bool = false, _ profile: UUID?, open: Bool = true, verified: [Int] = [2], wait: Bool = true
        ) -> LocalGate.Admission {
            LocalGate.admission(
                witness: witness, profile: profile, mayWait: wait, activeProfile: a, open: open,
                doors: [1, 2], verified: verified, latency: [2: 0.5], authorization: "x")
        }
        XCTAssertEqual(admit(a), .through([LocalGate.Upstream(port: 2, authorization: "x", patience: 1.5)]))
        XCTAssertEqual(admit(b), .refuse)
        XCTAssertEqual(admit(a, open: false), .wait)
        XCTAssertEqual(admit(a, open: false, wait: false), .refuse)
        XCTAssertEqual(admit(witness: true, nil).ports, [2, 1], "the witness may use every door, verified first")
        XCTAssertEqual(LocalGate.patience(after: nil), 3)
        XCTAssertEqual(LocalGate.patience(after: 10), 6)
    }
}

private extension Array where Element == FakeDoor {
    var pair: (FakeDoor, FakeDoor) { (self[0], self[1]) }
}

private extension LocalGate.Admission {
    var ports: [Int] {
        if case .through(let list) = self { return list.map(\.port) }
        return []
    }
}
