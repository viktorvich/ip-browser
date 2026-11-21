import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A minimal SSH client on Apple's swift-nio-ssh: password or ed25519 key, host key
/// pinned on first contact, one exec channel with stdin and streamed output.
/// Used only to install and manage the person's OWN server; never for browsing.
final class SSHExec {
    enum Auth {
        case password(String)
        case key(Curve25519.Signing.PrivateKey)
    }
    enum Failure: LocalizedError {
        case hostKeyChanged(String)
        case authFailed, timeout, handshakeTimeout
        case exit(Int, String)
        var errorDescription: String? {
            switch self {
            case .hostKeyChanged: return L("ssh.hostKeyChanged")
            case .authFailed: return L("ssh.authFailed")
            case .timeout, .handshakeTimeout: return L("ssh.timeout")
            case .exit(let code, let tail):
                return String(format: L("ssh.exit"), code) + (tail.isEmpty ? "" : "\n" + tail)
            }
        }
    }

    /// How far the conversation with the server got: tells a network cut (nothing from the
    /// server) from a server that refuses password logins or rejects the password.
    enum Stage { case tcp, keyExchanged, passwordNotAllowed, credentialsRejected }
    fileprivate(set) var stage = Stage.tcp

    let host: String, port: Int, user: String, auth: Auth
    /// OpenSSH form of the server key to require; nil = trust on first use.
    let pinnedHostKey: String?
    private(set) var seenHostKey: String?
    /// NIO's process-wide group: never shut down under a pending connect (a per-session
    /// group torn down in deinit leaked the connect promise when DNS or TCP failed).
    private let group = MultiThreadedEventLoopGroup.singleton
    private var channel: Channel?

    init(host: String, port: Int, user: String, auth: Auth, pinnedHostKey: String?) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.pinnedHostKey = pinnedHostKey
    }

    /// «SHA256:…» as `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it on the server:
    /// what a person compares in the hoster's console.
    static func fingerprint(_ openSSH: String) -> String {
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return openSSH }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func publicKeyLine(_ key: Curve25519.Signing.PrivateKey) -> String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + " ip-browser"
    }

    func connect() async throws {
        let userAuth = UserAuth(user: user, auth: auth) { [weak self] stage in self?.stage = stage }
        let serverAuth = HostKeyCheck(pinned: pinnedHostKey) { [weak self] seen in
            self?.seenHostKey = seen
            if self?.stage == .tcp { self?.stage = .keyExchanged }
        }
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(
                            role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                            allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        CloseOnError(),
                    ])
                }
            }
        // An IPv4 address on an IPv6-only network is dialed through its synthesized IPv6 (NAT64); the
        // pinned host key and every message keep the address the person typed.
        channel = try await bootstrap.connect(host: NAT64.address(for: host) ?? host, port: port).get()
        if let pinned = pinnedHostKey, let seen = seenHostKey, pinned != seen { throw Failure.hostKeyChanged(seen) }
    }

    /// Run `command`, feed `stdin`, call `line` for every output line, return the exit code.
    @discardableResult
    func run(
        _ command: String, stdin: Data? = nil, timeout: TimeInterval = 900, line: @escaping (String) -> Void = { _ in }
    ) async throws -> Int {
        guard let channel else { throw Failure.authFailed }
        let done = channel.eventLoop.makePromise(of: Int.self)
        let handler = ExecHandler(command: command, stdin: stdin, line: line, done: done)
        let child: Channel
        do {
            child = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                // A network filter can accept the TCP connection and then never answer the
                // SSH handshake: give up after 20 s instead of waiting for the run timeout.
                let guardTask = channel.eventLoop.scheduleTask(in: .seconds(20)) {
                    promise.fail(Failure.handshakeTimeout)
                    channel.close(promise: nil)
                }
                promise.futureResult.whenComplete { _ in guardTask.cancel() }
                ssh.createChannel(promise) { child, type in
                    guard type == .session else { return child.eventLoop.makeFailedFuture(Failure.authFailed) }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandlers([handler, CloseOnError()])
                    }
                }
                return promise.futureResult
            }.get()
        } catch {
            // The session never opened (auth refused, connection cut during the SSH
            // handshake by a network filter): settle our promise and report.
            done.fail(error)
            throw error
        }
        let deadline = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeout))) {
            done.fail(Failure.timeout)
            child.close(promise: nil)
        }
        defer { deadline.cancel() }
        let code = try await done.futureResult.get()
        try? await child.closeFuture.get()
        return code
    }

    func close() { channel?.close(promise: nil) }
}

private final class UserAuth: NIOSSHClientUserAuthenticationDelegate {
    let user: String, auth: SSHExec.Auth
    let report: (SSHExec.Stage) -> Void
    private var offered = false
    init(user: String, auth: SSHExec.Auth, report: @escaping (SSHExec.Stage) -> Void) {
        self.user = user
        self.auth = auth
        self.report = report
    }
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered else {
            // Asked again = the first offer failed. If the server no longer lists passwords,
            // it never accepted them (keys only); otherwise the password itself was wrong.
            if case .password = auth, !availableMethods.contains(.password) {
                report(.passwordNotAllowed)
            } else {
                report(.credentialsRejected)
            }
            nextChallengePromise.fail(SSHExec.Failure.authFailed)
            return
        }
        offered = true
        switch auth {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                report(.passwordNotAllowed)
                nextChallengePromise.fail(SSHExec.Failure.authFailed)
                return
            }
            nextChallengePromise.succeed(
                .init(username: user, serviceName: "", offer: .password(.init(password: password))))
        case .key(let key):
            guard availableMethods.contains(.publicKey) else {
                report(.credentialsRejected)
                nextChallengePromise.fail(SSHExec.Failure.authFailed)
                return
            }
            nextChallengePromise.succeed(
                .init(
                    username: user, serviceName: "",
                    offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))))
        }
    }
}

private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate {
    let pinned: String?
    let seen: (String) -> Void
    init(pinned: String?, seen: @escaping (String) -> Void) {
        self.pinned = pinned
        self.seen = seen
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let text = String(openSSHPublicKey: hostKey)
        seen(text)
        if let pinned, pinned != text {
            validationCompletePromise.fail(SSHExec.Failure.hostKeyChanged(text))
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

private final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    let command: String, stdin: Data?, line: (String) -> Void, done: EventLoopPromise<Int>
    private var pending = Data(), tail: [String] = [], exitCode: Int?
    init(command: String, stdin: Data?, line: @escaping (String) -> Void, done: EventLoopPromise<Int>) {
        self.command = command
        self.stdin = stdin
        self.line = line
        self.done = done
    }
    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }
    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
            .whenComplete { [self] result in
                guard case .success = result else {
                    done.fail(SSHExec.Failure.exit(-1, "exec refused"))
                    context.close(promise: nil)
                    return
                }
                if let stdin {
                    var buffer = context.channel.allocator.buffer(capacity: stdin.count)
                    buffer.writeBytes(stdin)
                    context.writeAndFlush(
                        wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
                }
                context.close(mode: .output, promise: nil)
            }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = message.data, let chunk = bytes.readBytes(length: bytes.readableBytes)
        else { return }
        pending.append(contentsOf: chunk)
        while let i = pending.firstIndex(of: 0x0A) {
            let text = String(decoding: pending[..<i], as: UTF8.self)
            pending.removeSubrange(...i)
            tail.append(text)
            if tail.count > 6 { tail.removeFirst() }
            line(text)
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitCode = status.exitStatus
        } else if event is ChannelEvent { /* half-closure */
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !pending.isEmpty {
            line(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        let code = exitCode ?? -1
        if code == 0 { done.succeed(0) } else { done.fail(SSHExec.Failure.exit(code, tail.joined(separator: "\n"))) }
    }
}

private final class CloseOnError: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
