import Crypto
import Foundation
import UIKit

/// «Свой сервер в несколько нажатий» (the AmneziaVPN way): the person gives the address
/// and root password of a fresh VPS; the app connects over SSH, runs its bundled
/// installer (Server/install.sh) and receives this device's keys. The app adds its own
/// ed25519 key for later management (more devices, revoking one), so the password is
/// used once and never stored.
enum ServerInstaller {
    struct Progress {
        let step: Int
        let total: Int
        let text: String
    }

    static var script: Data {
        guard let url = Bundle.main.url(forResource: "install", withExtension: "sh"),
            let data = try? Data(contentsOf: url)
        else { return Data() }
        return data
    }

    static func deviceName() -> String {
        let base = UIDevice.current.model.lowercased().replacingOccurrences(of: " ", with: "-")
        return base + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Servers installed before 21.11.2026 have no management command: the script itself runs
    /// from stdin as root (directly or through sudo -n).
    private static func legacyCommand(user: String, args: [String]) -> String {
        let quoted = args.map(quote).joined(separator: " ")
        return user == "root" ? "bash -s -- \(quoted)" : "sudo -n bash -s -- \(quoted)"
    }

    /// The SSH host key this phone already trusts for that server (a profile installed there),
    /// checked BEFORE the password is sent.
    static func knownHostKey(host: String, port: Int) -> String? {
        ProfileStore.shared.profiles.compactMap(\.management).first {
            $0.host == host && $0.port == port && !$0.hostKey.isEmpty
        }?.hostKey
    }

    /// Install (or reinstall) on the person's server. `pinnedHostKey`: the key this phone knows
    /// for that address (nil on first contact, or when the person confirmed a reinstalled server).
    static func install(
        host: String, port: Int, user: String, password: String, name: String, pinnedHostKey: String? = nil,
        progress: @escaping (Progress) -> Void
    ) async throws -> ServerProfile {
        let key = Curve25519.Signing.PrivateKey()
        let device = deviceName()
        DispatchQueue.main.async {
            progress(Progress(step: 0, total: 9, text: String(format: L("install.connecting"), host)))
        }
        let ssh = try await connectWithRetry(
            host: host, port: port, user: user, auth: .password(password), pinned: pinnedHostKey, progress: progress)
        defer { ssh.close() }
        var result: [String: Any]?
        var problem: InstallProblem?
        // A non-root user: ask sudo first whether it wants a password at all. If it does not,
        // the password must never reach bash's stdin (it would run as a command line as root).
        var sudoNeedsPassword = false
        if user != "root" {
            do { try await ssh.run("sudo -n true", timeout: 30) } catch { sudoNeedsPassword = true }
        }
        // The script goes to a private file of the login user first, then runs as root from that
        // file: the server keeps a root-owned copy behind its management command, and a sudo
        // password (if sudo wants one) goes to sudo alone.
        var file: String?
        do {
            try await ssh.run(
                "umask 077; f=$(mktemp /tmp/ip-browser-install.XXXXXX) && cat > \"$f\" && echo \"@@file $f\"",
                stdin: script, timeout: 120
            ) { line in
                if line.hasPrefix("@@file /tmp/ip-browser-install.") { file = String(line.dropFirst(7)) }
            }
        } catch { throw InstallProblem.ssh(error, session: ssh) }
        guard let file else { throw InstallProblem(code: "no_result", detail: "upload", host: host) }
        var words = ["install", "--device", device, "--pubkey", SSHExec.publicKeyLine(key), "--endpoint", host]
        // A reinstall from this phone replaces its own earlier device on that server (its management key goes
        // with it), instead of leaving a second, forgotten access there.
        for old in ProfileStore.shared.profiles.compactMap(\.management) where old.host == host {
            words += ["--retire-device", old.device]
        }
        let args = words.map(quote).joined(separator: " ")
        let elevate = user == "root" ? "" : (sudoNeedsPassword ? "sudo -S -p '' " : "sudo -n ")
        let run = "\(elevate)bash \(quote(file)) \(args); rc=$?; rm -f \(quote(file)); exit $rc"
        let stdin = sudoNeedsPassword ? Data((password + "\n").utf8) : Data()
        var lastLines: [String] = []
        do {
            try await ssh.run(run, stdin: stdin) { line in
                lastLines.append(line)
                if lastLines.count > 8 { lastLines.removeFirst() }
                parse(line, host: host, progress: progress, problem: { problem = $0 }) { result = $0 }
            }
        } catch {
            if let problem { throw problem }
            let tail = lastLines.joined(separator: "\n")
            if tail.contains("incorrect password") || tail.contains("Sorry, try again") {
                throw InstallProblem(code: "sudo", detail: "", host: host)
            }
            if tail.contains("a password is required") || tail.contains("not in the sudoers") {
                throw InstallProblem(code: "sudo_none", detail: "", host: host)
            }
            throw InstallProblem.ssh(error, session: ssh)
        }
        guard let result, let links = result["links"] as? [String], !links.isEmpty, let ip = result["ip"] as? String
        else {
            throw problem
                ?? InstallProblem(code: "no_result", detail: lastLines.suffix(3).joined(separator: " "), host: host)
        }
        try XrayEngine.validate(links: links)
        return ServerProfile(
            name: name, links: links, exitIPv4: ip, origin: .installed,
            management: .init(
                host: host, port: port, user: user, hostKey: ssh.seenHostKey ?? "",
                privateKeyPEM: key.rawRepresentation.base64EncodedString(), device: device))
    }

    /// A fresh VPS is brute-forced by bots from its first minute; OpenSSH then drops new
    /// connections at random (MaxStartups 10:30:100). Seen on a real VPS 20.11.2026. Retry a
    /// dropped or silent connection twice before telling the person about a network problem;
    /// never retry a refused password (that only feeds the server's brute-force protection).
    private static func connectWithRetry(
        host: String, port: Int, user: String, auth: SSHExec.Auth, pinned: String?,
        progress: @escaping (Progress) -> Void
    ) async throws -> SSHExec {
        var last: InstallProblem?
        for attempt in 1...3 {
            let ssh = SSHExec(host: host, port: port, user: user, auth: auth, pinnedHostKey: pinned)
            do {
                try await ssh.connect()
                try await ssh.run("true", timeout: 40)  // completes key exchange and login
                return ssh
            } catch {
                ssh.close()
                let problem = InstallProblem.ssh(error, session: ssh)
                last = problem
                guard ["reset", "server_closed", "timeout"].contains(problem.code), attempt < 3 else { throw problem }
                DispatchQueue.main.async {
                    progress(Progress(step: -1, total: 9, text: String(format: L("install.retry"), attempt + 1)))
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 4_000_000_000)
            }
        }
        throw last ?? InstallProblem(code: "other", detail: "", host: host)
    }

    /// Ask the server for keys for another device (QR to scan on that device).
    static func addDevice(_ profile: ServerProfile, name: String) async throws -> [String] {
        let result = try await manage(profile, ["add-device", "--device", name])
        guard let links = result["links"] as? [String], !links.isEmpty else {
            throw AppError.message(L("install.noResult"))
        }
        return links
    }

    static func devices(_ profile: ServerProfile) async throws -> [String] {
        (try await manage(profile, ["list-devices"])["devices"] as? [String]) ?? []
    }

    static func revoke(_ profile: ServerProfile, device: String) async throws {
        _ = try await manage(profile, ["revoke-device", "--device", device])
    }

    /// One management command on the person's server with the app's own key. Servers installed
    /// since 21.11.2026 run only /usr/local/sbin/ip-browser-manage for that key (any sudo
    /// policy works: it has its own sudoers rule); older servers get the script on stdin.
    private static func manage(_ profile: ServerProfile, _ args: [String]) async throws -> [String: Any] {
        guard let m = profile.management, let raw = Data(base64Encoded: m.privateKeyPEM),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else { throw AppError.message(L("install.notManaged")) }
        let ssh: SSHExec
        do {
            ssh = try await connectWithRetry(
                host: m.host, port: m.port, user: m.user, auth: .key(key),
                pinned: m.hostKey.isEmpty ? nil : m.hostKey, progress: { _ in })
        } catch let problem as InstallProblem where problem.code == "auth" {
            // The server no longer knows this phone's key (reinstalled or cleaned up).
            throw InstallProblem(code: "manage_key", detail: "", host: m.host)
        }
        defer { ssh.close() }
        var result: [String: Any] = [:]
        var problem: InstallProblem?
        let collect: (String) -> Void = { line in
            parse(line, host: m.host, progress: { _ in }, problem: { problem = $0 }) { result = $0 }
        }
        do {
            // Plain words (verbs and device names are [a-z0-9-]): the server's forced command splits
            // the requested line itself and accepts nothing else.
            guard
                args.allSatisfy({
                    $0.range(of: "^[a-z0-9][a-z0-9-]{0,31}$|^--device$", options: .regularExpression) != nil
                })
            else {
                throw InstallProblem(code: "device", detail: args.joined(separator: " "), host: m.host)
            }
            try await ssh.run(
                (["/usr/local/sbin/ip-browser-manage"] + args).joined(separator: " "), timeout: 180, line: collect)
        } catch SSHExec.Failure.exit(127, _) {
            problem = nil
            do {
                try await ssh.run(legacyCommand(user: m.user, args: args), stdin: script, timeout: 180, line: collect)
            } catch { throw problem ?? InstallProblem.ssh(error, session: ssh) }
        } catch { throw problem ?? InstallProblem.ssh(error, session: ssh) }
        return result
    }

    private static func parse(
        _ line: String, host: String, progress: @escaping (Progress) -> Void,
        problem: (InstallProblem) -> Void, result: ([String: Any]) -> Void
    ) {
        if line.hasPrefix("@@error ") {
            let parts = line.dropFirst(8).split(separator: " ", maxSplits: 1).map(String.init)
            problem(InstallProblem(code: parts.first ?? "other", detail: parts.count > 1 ? parts[1] : "", host: host))
        } else if line.hasPrefix("@@warn ") {
            let parts = line.dropFirst(7).split(separator: " ", maxSplits: 1).map(String.init)
            let text = "⚠︎ " + L("warn.\(parts.first ?? "")")
            DispatchQueue.main.async { progress(Progress(step: -1, total: 9, text: text)) }
        } else if line.hasPrefix("@@step ") {
            let parts = line.dropFirst(7).split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count == 3, let s = Int(parts[0]), let t = Int(parts[1]) {
                let p = Progress(step: s, total: t, text: parts[2])
                DispatchQueue.main.async { progress(p) }
            }
        } else if line.hasPrefix("@@result "), let data = line.dropFirst(9).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            result(object)
        }
    }
}
