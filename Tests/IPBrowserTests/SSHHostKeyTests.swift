import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import XCTest

@testable import IPBrowser

/// Records every password a client offers; accepts none.
private final class PasswordRecorder: NIOSSHServerUserAuthenticationDelegate {
    private let lock = NSLock()
    private var count = 0
    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(
        request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        lock.lock()
        count += 1
        lock.unlock()
        responsePromise.succeed(.failure)
    }
}

/// The password goes only to a server that shows the expected key: the one this phone knows, or the new one the
/// person confirmed by its fingerprint (review of the GitHub candidate, 21.11.2026).
final class SSHHostKeyTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var server: Channel!
    private let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
    private let recorder = PasswordRecorder()

    override func setUp() async throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let key = hostKey
        let recorder = recorder
        server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .server(.init(hostKeys: [key], userAuthDelegate: recorder)),
                            allocator: channel.allocator, inboundChildChannelInitializer: nil))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    override func tearDown() async throws {
        try await server.close()
        try await group.shutdownGracefully()
    }

    private var presented: String { String(openSSHPublicKey: hostKey.publicKey) }

    private func attempt(pinned: String?) async -> InstallProblem? {
        let ssh = SSHExec(
            host: "127.0.0.1", port: server.localAddress!.port!, user: "root", auth: .password("secret"),
            pinnedHostKey: pinned)
        defer { ssh.close() }
        do {
            try await ssh.connect()
            try await ssh.run("true", timeout: 10)
            return nil
        } catch {
            return InstallProblem.ssh(error, session: ssh)
        }
    }

    func testAnotherKeyStopsBeforeThePasswordAndNamesTheKeyItSaw() async {
        let other = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey)
        let problem = await attempt(pinned: other)
        XCTAssertEqual(problem?.code, "host_key")
        XCTAssertEqual(problem?.presentedHostKey, presented, "the key to confirm is exactly the one shown")
        XCTAssertEqual(problem?.detail, SSHExec.fingerprint(presented))
        XCTAssertEqual(recorder.attempts, 0, "no password reached a server with another key")
    }

    func testTheConfirmedKeyLetsThePasswordGoToThatServer() async {
        let problem = await attempt(pinned: presented)
        XCTAssertNotEqual(problem?.code, "host_key")
        XCTAssertGreaterThan(recorder.attempts, 0)
    }
}
