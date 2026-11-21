import Foundation
import Network

/// What happened to the tunnel, in time order: networks, core starts, exit checks and
/// diagnoses. It holds no website address and no key, and it stays on this phone (the
/// person can share it). It exists so that «it keeps reconnecting» can be answered with facts.
final class ConnectionLog: ObservableObject {
    static let shared = ConnectionLog()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    private let limit = 400
    private let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("connection-log.json")
    }()
    private var saveScheduled = false

    init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    /// Main thread only (TunnelController lives there).
    func add(_ text: String) {
        #if DEBUG
        print("IPB_LOG " + text)
        #endif
        entries.append(Entry(date: Date(), text: text))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let d = try? JSONEncoder().encode(self.entries) {
                try? d.write(to: self.file, options: .completeFileProtection)
            }
        }
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: file)
    }

    /// The copy a person shares (often in a public bug report): every IPv4 address hidden.
    var shareableText: String { Self.hidingAddresses(text) }

    static func hidingAddresses(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "•.•.•.•", options: .regularExpression)
    }

    var text: String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        return ([Settings.versionLine] + entries.map { f.string(from: $0.date) + "  " + $0.text }).joined(
            separator: "\n")
    }

    /// «Wi-Fi», «mobile», «other + mobile», «no network» — the route the core's UDP takes now.
    static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "no network (\(path.status))" }
        func name(_ t: NWInterface.InterfaceType) -> String {
            switch t {
            case .wifi: return "Wi-Fi"
            case .cellular: return "mobile"
            case .wiredEthernet: return "wired"
            case .loopback: return "loopback"
            default: return "other"
            }
        }
        var seen: [String] = []
        for i in path.availableInterfaces {
            let n = name(i.type)
            if !seen.contains(n) { seen.append(n) }
        }
        return seen.joined(separator: " + ") + (path.isExpensive ? " · expensive" : "")
            + (path.isConstrained ? " · low data" : "")
    }
}
