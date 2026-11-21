import SwiftUI

/// What the start page needs to know about the tunnel and what it can ask the browser to do.
final class StartPageModel: ObservableObject {
    enum Status: Equatable {
        case noServer
        case connecting(server: String, diagnosis: String?)
        case offline(server: String)
        case verified(server: String, ip: String)
        case mismatch(expected: String, seen: String)
        case failed(String)
    }
    @Published var status: Status = .noServer
    @Published var pending: URL?
    var open: (URL) -> Void = { _ in }
    var install: () -> Void = {}
    var haveKey: () -> Void = {}
    var servers: () -> Void = {}
    var acceptExit: (String) -> Void = { _ in }
    var retry: () -> Void = {}
}

/// The new-tab page: favourites first, like any browser; the server is one small line
/// at the top — until there is no server, then it is the one thing the page asks for.
struct StartPageView: View {
    @ObservedObject var model: StartPageModel
    /// The favourites and history of the active profile.
    @ObservedObject var library: BrowserLibrary
    @State private var renaming: BrowserLibrary.Favorite?
    @State private var newTitle = ""

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                statusView
                if !library.favorites.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L("start.favorites")).font(.title3.weight(.bold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(library.favorites) { f in
                                Button {
                                    model.open(f.url)
                                } label: {
                                    VStack(spacing: 7) {
                                        SiteTile(title: f.title, url: f.url)
                                        Text(f.title).font(.caption).foregroundStyle(.primary).lineLimit(1)
                                    }.frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        newTitle = f.title
                                        renaming = f
                                    } label: {
                                        Label(L("start.rename"), systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        library.toggleFavorite(title: f.title, url: f.url)
                                    } label: {
                                        Label(L("delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                if !library.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("start.recent")).font(.title3.weight(.bold))
                        VStack(spacing: 0) {
                            ForEach(library.recent) { v in
                                Button {
                                    model.open(v.url)
                                } label: {
                                    HStack(spacing: 12) {
                                        SiteTile(title: v.title, url: v.url, size: 34)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(v.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                            Text(v.url.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(
                                                1)
                                        }
                                        Spacer()
                                    }.padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if v.id != library.recent.last?.id { Divider().padding(.leading, 46) }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(
                                Color(.secondarySystemBackground)))
                    }
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemBackground))
        .alert(L("start.rename"), isPresented: .constant(renaming != nil)) {
            TextField(L("start.rename"), text: $newTitle)
            Button(L("cancel"), role: .cancel) { renaming = nil }
            Button(L("done")) {
                if let r = renaming { library.rename(r.id, to: newTitle) }
                renaming = nil
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .verified(let server, let ip):
            Button(action: model.servers) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    Text(String(format: L("start.verified"), ip, server)).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
            }.buttonStyle(.plain).accessibilityIdentifier("startStatus")
        case .noServer:
            card(icon: "server.rack", tint: .blue, title: L("start.noServer.title"), text: L("home.noServer")) {
                Button(action: model.install) { Text(L("servers.install")).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("homePrimary")
                Button(action: model.haveKey) { Text(L("home.haveKey")).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("homeSecondary")
            }
        case .connecting(let server, let diagnosis):
            card(
                icon: "arrow.triangle.2.circlepath", tint: .orange,
                title: String(format: L("start.connecting"), server),
                text: (model.pending == nil ? L("home.connecting") : L("home.pending"))
                    + (diagnosis.map { "\n\n" + $0 } ?? "")
            ) {
                Button(action: model.servers) { Text(L("servers")).frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    .controlSize(.large)
            }
        case .offline(let server):
            card(
                icon: "wifi.slash", tint: .gray, title: L("start.offline.title"),
                text: String(format: L("start.offline"), server)
            ) { EmptyView() }
        case .mismatch(let expected, let seen):
            card(
                icon: "exclamationmark.shield.fill", tint: .red, title: L("mismatch.title"),
                text: String(format: L("mismatch.detail"), seen, expected)
            ) {
                Button {
                    model.acceptExit(seen)
                } label: {
                    Text(L("mismatch.accept")).frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large)
                Button(action: model.servers) { Text(L("servers")).frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    .controlSize(.large)
            }
        case .failed(let message):
            card(icon: "xmark.shield.fill", tint: .red, title: L("failed.title"), text: message) {
                Button(action: model.retry) { Text(L("retry")).frame(maxWidth: .infinity) }.buttonStyle(
                    .borderedProminent
                ).controlSize(.large)
            }
        }
    }

    private func card<Buttons: View>(
        icon: String, tint: Color, title: String, text: String, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(tint)
                Text(title).font(.headline)
            }
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemBackground)))
    }
}
