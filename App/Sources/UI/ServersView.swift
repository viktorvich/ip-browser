import CoreImage.CIFilterBuiltins
import Crypto
import SwiftUI
import VisionKit

/// Servers = profiles: add one in a few taps (install on my VPS / paste or scan a key), pick
/// the active one, rename, share access with another device, remove (with all its data).
struct ServersView: View {
    var onDone: (() -> Void)? = nil
    @State private var profiles = ProfileStore.shared.profiles
    @State private var activeID = ProfileStore.shared.active?.id
    @State private var sheet: Sheet?
    @State private var error: String?
    @State private var renaming: ServerProfile?
    @State private var newName = ""
    @State private var removing: ServerProfile?

    enum Sheet: Identifiable {
        case install, importKey
        case share(ServerProfile)
        var id: String {
            switch self {
            case .install: "i"
            case .importKey: "k"
            case .share(let p): p.id.uuidString
            }
        }
    }

    var body: some View {
        List {
            if profiles.isEmpty {
                Section { Text(L("servers.empty")).foregroundStyle(.secondary) }
            }
            if !profiles.isEmpty {
                Section(L("servers")) {
                    ForEach(profiles) { p in
                        Button {
                            activate(p)
                        } label: {
                            HStack {
                                Image(systemName: p.id == activeID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((p.flag.map { $0 + " " } ?? "") + p.title).font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(
                                        [p.exitIPv4 ?? L("server.exitUnknown"), p.kinds.joined(separator: " + ")]
                                            .joined(separator: " · ")
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    sheet = .share(p)
                                } label: {
                                    Image(systemName: "qrcode")
                                }.buttonStyle(.borderless)
                            }
                        }
                        .swipeActions {
                            Button(L("delete"), role: .destructive) { removing = p }
                            Button(L("profiles.rename")) {
                                newName = p.title
                                renaming = p
                            }.tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                newName = p.title
                                renaming = p
                            } label: {
                                Label(L("profiles.rename"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                removing = p
                            } label: {
                                Label(L("delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    sheet = .install
                } label: {
                    Label(L("servers.install"), systemImage: "server.rack")
                }
                Button {
                    sheet = .importKey
                } label: {
                    Label(L("servers.import"), systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text(L("servers.footer") + "\n\n" + L("profiles.footer"))
            }
        }
        .navigationTitle(L("servers"))
        .toolbar { if let onDone { ToolbarItem(placement: .confirmationAction) { Button(L("done"), action: onDone) } } }
        .sheet(item: $sheet) { s in
            switch s {
            case .install: InstallView { p in added(p) }
            case .importKey: ImportView { p in added(p) }
            case .share(let p): ShareView(profile: p)
            }
        }
        .alert(
            L("error.title"), isPresented: .constant(error != nil), actions: { Button("OK") { error = nil } },
            message: { Text(error ?? "") }
        )
        .alert(L("profiles.rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }))
        {
            TextField(L("profiles.rename"), text: $newName)
            Button(L("cancel"), role: .cancel) { renaming = nil }
            Button(L("done")) { rename() }
        }
        .confirmationDialog(
            removing.map { String(format: L("profiles.remove.title"), $0.title) } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("delete"), role: .destructive) {
                if let p = removing { remove(p) }
                removing = nil
            }
        } message: {
            Text(L("profiles.remove.detail"))
        }
    }

    private func added(_ p: ServerProfile) {
        sheet = nil
        do { activate(try ProfileStore.shared.upsert(p)) } catch { self.error = error.localizedDescription }
    }
    /// The browser switches pages, website data and tunnel together.
    private func activate(_ p: ServerProfile) {
        activeID = p.id
        ProfileStore.requestSwitch(to: p.id)
        profiles = ProfileStore.shared.profiles
    }
    private func remove(_ p: ServerProfile) {
        try? ProfileStore.shared.remove(p.id)  // the browser deletes its pages and data
        profiles = ProfileStore.shared.profiles
        activeID = ProfileStore.shared.active?.id
    }
    private func rename() {
        guard var p = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty else { return }
        p.name = name
        do {
            try ProfileStore.shared.upsert(p)
            profiles = ProfileStore.shared.profiles
        } catch { self.error = error.localizedDescription }
        NotificationCenter.default.post(name: Region.changed, object: nil)  // the bar shows the new name
    }
}

struct InstallView: View {
    let onInstalled: (ServerProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var name = ""
    @State private var running = false
    @State private var steps: [String] = []
    @State private var fraction = 0.0
    @State private var error: String?
    @State private var networkBlocked = false
    /// The server showed another SSH key than the one this phone knows for it: that key, for this address and port.
    @State private var presentedKey: (host: String, port: Int, key: String)?

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                Form {
                    Section {
                        LabeledContent(L("install.host.label")) {
                            TextField("203.0.113.10", text: $host).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().keyboardType(.URL).multilineTextAlignment(.trailing)
                        }
                        LabeledContent(L("install.user")) {
                            // Empty means root: a prefilled «root» made people type «rootroot».
                            TextField("root", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent(L("install.password")) {
                            SecureField(L("install.password.hint"), text: $password).multilineTextAlignment(.trailing)
                        }
                        LabeledContent(L("install.port")) {
                            TextField("22", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                        LabeledContent(L("install.name.label")) {
                            TextField(L("install.name.hint"), text: $name).multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text(L("install.header"))
                    } footer: {
                        Text(L("install.footer"))
                    }
                    if !running && steps.isEmpty && error == nil {
                        Section {
                            DisclosureGroup(L("install.where")) {
                                Text(L("install.where.text")).font(.footnote).foregroundStyle(.secondary)
                            }
                            DisclosureGroup(L("install.what")) {
                                Text(L("install.what.text")).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if running || !steps.isEmpty {
                        Section(L("install.progress")) {
                            ProgressView(value: fraction)
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in Text(s).font(.footnote) }
                            if running {
                                HStack {
                                    ProgressView()
                                    Text(L("install.wait")).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(.red).font(.footnote).textSelection(.enabled) }.id(
                            "result")
                    }
                    if let presentedKey {
                        Section {
                            Button(role: .destructive) {
                                start(trusting: presentedKey)
                            } label: {
                                Label(L("install.trustNewKey"), systemImage: "key.horizontal")
                            }
                        } footer: {
                            Text(L("install.trustNewKey.footer"))
                        }
                    }
                    if networkBlocked {
                        Section {
                            Text(Settings.consoleCommand).font(.footnote.monospaced()).textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = Settings.consoleCommand
                            } label: {
                                Label(L("install.console.copy"), systemImage: "doc.on.doc")
                            }
                        } header: {
                            Text(L("install.console"))
                        } footer: {
                            Text(L("install.console.footer"))
                        }
                    }
                    Color.clear.frame(height: 1).listRowBackground(Color.clear).listRowInsets(EdgeInsets()).id("bottom")
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: steps.count) { withAnimation { scroller.scrollTo("bottom") } }
                .onChange(of: error) { withAnimation { scroller.scrollTo("result", anchor: .top) } }
            }
            .navigationTitle(L("install.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() }.disabled(running) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("install.go")) { start() }.disabled(
                        running || host.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(running)
    }

    /// `trusting`: the key the person confirmed by its fingerprint. The retry accepts only that key - another one stops
    /// it before the password is sent - and only for the address and port it was shown for.
    private func start(trusting confirmed: (host: String, port: Int, key: String)? = nil) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        running = true
        error = nil
        steps = []
        fraction = 0
        networkBlocked = false
        presentedKey = nil
        let host = self.host.trimmingCharacters(in: .whitespaces)
        let typed = self.user.trimmingCharacters(in: .whitespaces)
        let user = typed.isEmpty ? "root" : typed
        let name = self.name.isEmpty ? host : self.name
        Task {
            do {
                let port = Int(self.port) ?? 22
                // The SSH key is checked before the password goes out: the one this phone knows for the server, or the
                // new one the person confirmed for exactly this address. A first contact remembers the key it meets.
                let pinned =
                    confirmed.flatMap { $0.host == host && $0.port == port ? $0.key : nil }
                    ?? ServerInstaller.knownHostKey(host: host, port: port)
                let p = try await ServerInstaller.install(
                    host: host, port: port, user: user, password: password, name: name, pinnedHostKey: pinned
                ) { pr in
                    steps.append(pr.text)
                    if pr.step >= 0 { fraction = Double(pr.step) / Double(max(pr.total, 1)) }
                }
                await MainActor.run {
                    running = false
                    password = ""
                    onInstalled(p)
                }
            } catch {
                await MainActor.run {
                    running = false
                    self.error = error.localizedDescription
                    networkBlocked = ["timeout", "unreachable", "reset"].contains(
                        (error as? InstallProblem)?.code ?? "")
                    if let problem = error as? InstallProblem, problem.code == "host_key",
                        let key = problem.presentedHostKey
                    {
                        presentedKey = (host, Int(self.port) ?? 22, key)
                    }
                }
            }
        }
    }
}

struct ImportView: View {
    let onImported: (ServerProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scanning = false
    @State private var editing = false
    @State private var error: String?

    /// The key as a person understands it: which server, which address websites will see.
    private var decoded: Result<ServerProfile, Error>? { text.isEmpty ? nil : Result { try AccessKey.decode(text) } }
    private var parsed: ServerProfile? { try? decoded?.get() }

    var body: some View {
        NavigationStack {
            Form {
                if let p = parsed, !editing {
                    Section(L("import.found")) {
                        LabeledContent(L("import.server"), value: p.name)
                        LabeledContent(L("import.exit"), value: p.exitIPv4 ?? L("server.exitUnknown"))
                        LabeledContent(
                            L("import.ways"), value: p.links.map { XrayEngine.kind(of: $0) }.joined(separator: ", "))
                        Button(L("import.other")) {
                            text = ""
                            error = nil
                        }
                    }
                } else {
                    Section {
                        PasteButton(payloadType: String.self) { values in
                            Task { @MainActor in
                                text = values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                editing = false
                                check()
                            }
                        }
                        if DataScannerViewController.isSupported {
                            Button {
                                scanning = true
                            } label: {
                                Label(L("import.scan"), systemImage: "qrcode.viewfinder")
                            }
                        }
                        DisclosureGroup(L("import.manual"), isExpanded: $editing) {
                            TextEditor(text: $text).frame(minHeight: 100).font(.footnote.monospaced())
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    } header: {
                        Text(L("import.header"))
                    } footer: {
                        Text(L("import.footer"))
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle(L("servers.import"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("import.add")) { add() }.disabled(parsed == nil)
                }
            }
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    text = code
                    editing = false
                    check()
                }.ignoresSafeArea()
            }
        }
    }
    /// Why a key is refused, in its own words (not a key at all, or a key without masking).
    private func check() {
        if case .failure(let problem) = decoded { error = problem.localizedDescription } else { error = nil }
    }
    private func add() {
        do { onImported(try AccessKey.decode(text)) } catch { self.error = error.localizedDescription }
    }
}

struct ShareView: View {
    let profile: ServerProfile
    @Environment(\.dismiss) private var dismiss
    @State private var key: String?
    @State private var working = false
    @State private var error: String?
    @State private var devices: [String] = []
    @State private var confirmRevokeSelf = false
    /// This phone's own name on the server.
    private var ownDevice: String? { profile.management?.device }

    var body: some View {
        NavigationStack {
            List {
                if let key {
                    Section {
                        if let image = QR.image(key) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260)
                                .frame(maxWidth: .infinity)
                        }
                        ShareLink(item: key) { Label(L("share.send"), systemImage: "square.and.arrow.up") }
                        Button {
                            UIPasteboard.general.string = key
                        } label: {
                            Label(L("share.copy"), systemImage: "doc.on.doc")
                        }
                    } footer: {
                        Text(L("share.footer"))
                    }
                }
                if profile.management != nil {
                    Section {
                        Button {
                            newDevice()
                        } label: {
                            Label(L("share.newDevice"), systemImage: "plus.circle")
                        }.disabled(working)
                        ForEach(devices, id: \.self) { d in
                            HStack {
                                Text(d)
                                if d == ownDevice {
                                    Spacer()
                                    Text(L("share.thisPhone")).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                // The only device cannot go: without it the tunnel has no user (uninstall instead).
                                if devices.count > 1 {
                                    Button(L("share.revoke"), role: .destructive) {
                                        if d == ownDevice { confirmRevokeSelf = true } else { revoke(d) }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(L("share.devices"))
                    } footer: {
                        if devices.count == 1 { Text(L("share.lastDevice")) }
                    }
                } else if key == nil {
                    Section {
                        Button(L("share.thisKey")) {
                            key = AccessKey.encode(name: profile.name, exit: profile.exitIPv4, links: profile.links)
                        }
                    }
                }
                if working { ProgressView() }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle(profile.title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("done")) { dismiss() } } }
            .task { if profile.management != nil { await loadDevices() } }
            .confirmationDialog(L("share.revokeSelf.title"), isPresented: $confirmRevokeSelf, titleVisibility: .visible)
            {
                Button(L("share.revokeSelf.confirm"), role: .destructive) { if let ownDevice { revoke(ownDevice) } }
            } message: {
                Text(L("share.revokeSelf.message"))
            }
        }
    }
    private func loadDevices() async {
        do { devices = try await ServerInstaller.devices(profile) } catch { self.error = error.localizedDescription }
    }
    private func newDevice() {
        working = true
        error = nil
        Task {
            do {
                let links = try await ServerInstaller.addDevice(
                    profile, name: "device-" + String(UUID().uuidString.prefix(4)).lowercased())
                key = AccessKey.encode(name: profile.name, exit: profile.exitIPv4, links: links)
                await loadDevices()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
    /// Revoking a device removes its tunnel access and, on the server, its management key. This
    /// phone revoking itself has nothing left on that server: its profile goes from this phone too.
    private func revoke(_ d: String) {
        working = true
        error = nil
        Task {
            do {
                try await ServerInstaller.revoke(profile, device: d)
                if d == ownDevice {
                    try? ProfileStore.shared.remove(profile.id)
                    dismiss()
                } else {
                    await loadDevices()
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

enum QR {
    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let cg = CIContext().createCGImage(out, from: out.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let c = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            isHighlightingEnabled: true)
        c.delegate = context.coordinator
        try? c.startScanning()
        return c
    }
    func updateUIViewController(_ c: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                if let v = b.payloadStringValue, !done {
                    done = true
                    s.stopScanning()
                    found(v)
                }
            }
        }
    }
}

enum Settings {
    struct Engine {
        let id: String
        let name: String
        let url: String
    }
    static let engines = [
        Engine(id: "duckduckgo", name: "DuckDuckGo", url: "https://duckduckgo.com/"),
        Engine(id: "google", name: "Google", url: "https://www.google.com/search"),
        Engine(id: "bing", name: "Bing", url: "https://www.bing.com/search"),
        Engine(id: "yandex", name: "Яндекс", url: "https://yandex.ru/search/"),
    ]
    static func search(_ query: String) -> URL? {
        let id = UserDefaults.standard.string(forKey: "searchEngine") ?? "duckduckgo"
        let e = engines.first { $0.id == id } ?? engines[0]
        var c = URLComponents(string: e.url)
        c?.queryItems = [URLQueryItem(name: e.id == "yandex" ? "text" : "q", value: query)]
        return c?.url
    }
    static var privacyText: String { text(L("privacy.file")) }
    /// The public home of the project; the console command installs from it, never from us.
    static let repository = "https://github.com/viktorvich/ip-browser"
    /// The installer this app carries, fetched from the repository by its own checksum (a tag named after it): the
    /// console runs exactly the script the app would have run over SSH, or nothing.
    static var consoleCommand: String { consoleCommand(for: ServerInstaller.script) }
    static func consoleCommand(for script: Data) -> String {
        let sum = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        let url =
            "https://raw.githubusercontent.com/viktorvich/ip-browser/installer-\(sum.prefix(12))/Server/install.sh"
        return
            "curl -fsSLo ipb.sh \(url) && echo \"\(sum)  ipb.sh\" | sha256sum -c - && $(command -v sudo) bash ipb.sh install"
    }
    static func text(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        } ?? ""
    }
    static var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b)) · Xray \(XrayEngine.version)"
    }
}
