import Foundation
import NIOCore
import NIOPosix

/// What went wrong while installing or managing the person's server, in their words:
/// what happened, the likely reason and what to do next. Every SSH failure and every
/// coded failure of Server/install.sh («@@error <code> <detail>») maps to one of these.
struct InstallProblem: LocalizedError {
    let code: String
    let detail: String
    let host: String
    /// For «host_key»: the key the server presented (OpenSSH text). Trusting it pins exactly this key for the retry.
    var presentedHostKey: String? = nil

    var errorDescription: String? {
        let title = L("problem.\(code).title")
        let advice = L("problem.\(code).advice")
        var text = (title == "problem.\(code).title" ? L("problem.other.title") : title).replacingOccurrences(
            of: "%HOST%", with: host)
        if advice != "problem.\(code).advice" { text += "\n\n" + advice.replacingOccurrences(of: "%HOST%", with: host) }
        if !detail.isEmpty { text += "\n\n" + L("problem.detail") + " " + detail }
        return text
    }

    /// An SSH-level failure before the installer could run; what the server already said
    /// (key exchange, offered login methods) decides between «your network» and «the server».
    static func ssh(_ error: Error, session: SSHExec) -> InstallProblem {
        // The server showed another key than the one expected: that is the problem, whichever error the channel
        // reported first (the refused key closes the connection, and that may surface before our own error).
        if let pinned = session.pinnedHostKey, let seen = session.seenHostKey, pinned != seen {
            return .init(
                code: "host_key", detail: SSHExec.fingerprint(seen), host: session.host, presentedHostKey: seen)
        }
        let host = session.host
        let port = session.port
        switch session.stage {
        case .passwordNotAllowed: return .init(code: "password_off", detail: "", host: host)
        case .credentialsRejected: return .init(code: "auth", detail: "", host: host)
        case .keyExchanged:
            if case SSHExec.Failure.exit = error {
            } else if !(error is SSHExec.Failure) {
                return .init(code: "server_closed", detail: "\(host):\(port)", host: host)
            }
        case .tcp: break
        }
        return ssh(error, host: host, port: port)
    }

    static func ssh(_ error: Error, host: String, port: Int) -> InstallProblem {
        let where_ = "\(host):\(port)"
        if let f = error as? SSHExec.Failure {
            switch f {
            case .authFailed: return .init(code: "auth", detail: "", host: host)
            case .hostKeyChanged(let seen):
                return .init(code: "host_key", detail: SSHExec.fingerprint(seen), host: host, presentedHostKey: seen)
            case .timeout: return .init(code: "install_timeout", detail: "", host: host)
            case .handshakeTimeout: return .init(code: "timeout", detail: "\(where_) (SSH)", host: host)
            case .exit(let code, let tail): return .init(code: "script_exit", detail: "\(code) \(tail)", host: host)
            }
        }
        if let c = error as? NIOConnectionError {
            if c.connectionErrors.isEmpty, c.dnsAError != nil || c.dnsAAAAError != nil {
                return .init(code: "dns", detail: host, host: host)
            }
            let errnos = c.connectionErrors.compactMap { ($0.error as? IOError)?.errnoCode }
            if errnos.contains(ECONNREFUSED) { return .init(code: "refused", detail: where_, host: host) }
            if errnos.contains(where: { [EHOSTUNREACH, ENETUNREACH].contains($0) }) {
                return .init(code: "unreachable", detail: where_, host: host)
            }
            if c.connectionErrors.contains(where: {
                if case ChannelError.connectTimeout = $0.error { return true }
                return false
            }) {
                return .init(code: "timeout", detail: where_, host: host)
            }
            return .init(
                code: "unreachable",
                detail: "\(where_) \(c.connectionErrors.map { "\($0.error)" }.joined(separator: "; "))", host: host)
        }
        if case ChannelError.connectTimeout = error { return .init(code: "timeout", detail: where_, host: host) }
        if let io = error as? IOError {
            switch io.errnoCode {
            case ECONNREFUSED: return .init(code: "refused", detail: where_, host: host)
            case ECONNRESET, EPIPE: return .init(code: "reset", detail: where_, host: host)
            case EHOSTUNREACH, ENETUNREACH: return .init(code: "unreachable", detail: where_, host: host)
            case ETIMEDOUT: return .init(code: "timeout", detail: where_, host: host)
            default: break
            }
        }
        let text = String(describing: error)
        if text.contains("authFailed") || text.lowercased().contains("auth") {
            return .init(code: "auth", detail: "", host: host)
        }
        if error is ChannelError || text.contains("eof") || text.contains("closed") {
            return .init(code: "reset", detail: where_, host: host)
        }
        return .init(code: "other", detail: text, host: host)
    }
}
