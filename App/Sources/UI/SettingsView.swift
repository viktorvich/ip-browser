import SwiftUI

/// Everything that is not browsing lives here, grouped the way iOS Settings groups things.
struct SettingsView: View {
    let onDone: () -> Void
    let onLeakTest: () -> Void
    let onClearData: () -> Void
    let onStrictChanged: () -> Void
    /// Opens an address in a new tab of the active profile (through its own server, not Safari).
    let onOpen: (URL) -> Void
    @AppStorage("strictMode") private var strict = false
    @AppStorage("zoneFromServer") private var zoneFromServer = true
    @AppStorage("searchEngine") private var search = "duckduckgo"
    @ObservedObject private var library = BrowserLibrary.shared
    @State private var confirm: Confirm?
    @State private var tick = 0  // refreshes the server row after changes in Servers

    enum Confirm: Identifiable {
        case history, data
        var id: Int { self == .history ? 0 : 1 }
    }

    /// What clock websites see now, in words.
    private var zoneFooter: String {
        guard zoneFromServer else { return String(format: L("settings.zone.off"), TimeZone.current.identifier) }
        var ip = ProfileStore.shared.active?.exitIPv4
        if case .verified(let seen) = TunnelController.shared.state { ip = seen }
        guard let zone = Region.shared.knownZone(for: ip) else { return L("settings.zone.unknown") }
        return String(format: L("settings.zone.on"), Region.describe(zone))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ServersView().onDisappear { tick += 1 }
                    } label: {
                        serverRow
                    }
                } header: {
                    Text(L("settings.server"))
                }

                Section {
                    Button(action: onLeakTest) {
                        SettingsRow(icon: "checkmark.shield.fill", color: .green, title: L("selftest"))
                    }
                    NavigationLink {
                        ConnectionLogView()
                    } label: {
                        SettingsRow(icon: "list.bullet.rectangle.fill", color: .teal, title: L("log.title"))
                    }
                    Toggle(isOn: Shield.webTransportLeaks ? .constant(true) : $strict) {
                        SettingsRow(icon: "lock.shield.fill", color: .orange, title: L("settings.strict"))
                    }
                    .disabled(Shield.webTransportLeaks)
                    .onChange(of: strict) { onStrictChanged() }
                } header: {
                    Text(L("settings.protection"))
                } footer: {
                    Text(
                        L("settings.strict.footer")
                            + (Shield.webTransportLeaks
                                ? "\n\n" + String(format: L("settings.strict.forced"), Shield.iosVersion) : ""))
                }

                Section {
                    Toggle(isOn: $zoneFromServer) {
                        SettingsRow(icon: "clock.fill", color: .purple, title: L("settings.zone"))
                    }
                    .onChange(of: zoneFromServer) {
                        Region.shared.followsServer = zoneFromServer
                        if zoneFromServer { TunnelController.shared.learnZone() }
                    }
                } footer: {
                    Text(zoneFooter)
                }

                Section {
                    NavigationLink {
                        List {
                            Picker(L("settings.search"), selection: $search) {
                                ForEach(Settings.engines, id: \.id) { Text($0.name).tag($0.id) }
                            }.pickerStyle(.inline).labelsHidden()
                        }.navigationTitle(L("settings.search"))
                    } label: {
                        SettingsRow(
                            icon: "magnifyingglass", color: .blue, title: L("settings.search"),
                            value: Settings.engines.first { $0.id == search }?.name)
                    }
                    Button {
                        confirm = .history
                    } label: {
                        SettingsRow(icon: "clock.arrow.circlepath", color: .gray, title: L("library.clear"))
                    }
                    .disabled(library.history.isEmpty)
                    Button {
                        confirm = .data
                    } label: {
                        SettingsRow(icon: "trash.fill", color: .red, title: L("settings.clear"))
                    }
                } header: {
                    Text(L("settings.browser"))
                } footer: {
                    if let p = ProfileStore.shared.active {
                        Text(String(format: L("settings.browser.footer"), p.title))
                    }
                }

                Section {
                    NavigationLink {
                        textPage(Settings.privacyText, title: L("settings.privacy"))
                    } label: {
                        SettingsRow(icon: "hand.raised.fill", color: .indigo, title: L("settings.privacy"))
                    }
                    NavigationLink {
                        textPage(Settings.text("licenses"), title: L("settings.licenses"))
                    } label: {
                        SettingsRow(icon: "doc.text.fill", color: .gray, title: L("settings.licenses"))
                    }
                    Button {
                        onOpen(URL(string: Settings.repository)!)
                    } label: {
                        SettingsRow(
                            icon: "chevron.left.forwardslash.chevron.right", color: .black, title: L("settings.source"))
                    }
                    .foregroundStyle(Color.primary)
                    SettingsRow(
                        icon: "info.circle.fill", color: .blue, title: L("settings.version"),
                        value: Settings.versionLine)
                } header: {
                    Text(L("settings.about"))
                } footer: {
                    Text(L("settings.promise"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("done"), action: onDone) } }
            .confirmationDialog(
                confirm == .history ? L("library.clear") : L("settings.clear"),
                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                titleVisibility: .visible
            ) {
                Button(confirm == .history ? L("library.clear") : L("settings.clear"), role: .destructive) {
                    if confirm == .history { library.clearHistory() } else { onClearData() }
                    confirm = nil
                }
            }
        }
    }

    private var serverRow: some View {
        let _ = tick
        let p = ProfileStore.shared.active
        let state = TunnelController.shared.state
        let detail: String
        let color: Color
        switch state {
        case .verified(let ip):
            detail = String(format: L("settings.server.verified"), ip)
            color = .green
        case .noProfile:
            detail = L("settings.server.none")
            color = .gray
        case .mismatch:
            detail = L("chip.mismatch")
            color = .red
        case .failed:
            detail = L("chip.failed")
            color = .red
        default:
            detail = L("chip.reconnecting")
            color = .orange
        }
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.blue.gradient).frame(
                    width: 30, height: 30)
                Image(systemName: "server.rack").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.map { ($0.flag.map { $0 + " " } ?? "") + $0.title } ?? L("settings.server.add")).foregroundStyle(
                    Color.primary)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// Long texts (the licenses of every bundled component run to hundreds of kilobytes) are
    /// laid out paragraph by paragraph, only as they scroll into view.
    private func textPage(_ text: String, title: String) -> some View {
        let parts = text.components(separatedBy: "\n\n")
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(parts.indices, id: \.self) { i in Text(parts[i]).font(.footnote).textSelection(.enabled) }
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
    }
}

/// An iOS Settings-style row: a white symbol on a coloured rounded square.
struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    var value: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient).frame(width: 29, height: 29)
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// The tunnel's own journal: when the network changed, when the core restarted, what the
/// exit check saw. No website addresses. Shareable, so a person can send it when asking for help.
struct ConnectionLogView: View {
    @ObservedObject private var log = ConnectionLog.shared
    @State private var confirm = false
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        return f
    }()

    var body: some View {
        List {
            if log.entries.isEmpty { Text(L("log.empty")).foregroundStyle(.secondary) }
            ForEach(log.entries.reversed()) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.time.string(from: e.date)).font(.caption2.monospacedDigit()).foregroundStyle(
                        Color.secondary)
                    Text(e.text).font(.footnote).foregroundStyle(Color.primary).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(L("log.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: log.shareableText) { Image(systemName: "square.and.arrow.up") }.disabled(
                    log.entries.isEmpty)
                Button(role: .destructive) {
                    confirm = true
                } label: {
                    Image(systemName: "trash")
                }.disabled(log.entries.isEmpty)
            }
        }
        .confirmationDialog(L("log.clear"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L("log.clear"), role: .destructive) { log.clear() }
        }
    }
}
