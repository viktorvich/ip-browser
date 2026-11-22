import SwiftUI

/// What the profile bar shows and what it can ask the browser to do.
final class ProfileBarModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let title: String
        let flag: String?
    }
    enum Dot: Equatable { case ok, wait, bad }
    @Published var items: [Item] = []
    @Published var active: UUID?
    @Published var dot: Dot = .wait
    var select: (UUID) -> Void = { _ in }
    var install: () -> Void = {}
    var haveKey: () -> Void = {}
    var manage: () -> Void = {}
    var duplicate: (UUID) -> Void = { _ in }
}

/// Profiles on top of the browser, like Safari's profiles: one per server, each a separate
/// browser (its own logins, site data, tabs, favourites, history and clock). One tap
/// switches; the tunnel of the chosen server starts and only its pages exist.
struct ProfileBar: View {
    @ObservedObject var model: ProfileBarModel

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.items) { item in chip(item).id(item.id) }
                    Menu {
                        Button {
                            model.install()
                        } label: {
                            Label(L("servers.install"), systemImage: "server.rack")
                        }
                        Button {
                            model.haveKey()
                        } label: {
                            Label(L("servers.import"), systemImage: "qrcode.viewfinder")
                        }
                        Divider()
                        Button {
                            model.manage()
                        } label: {
                            Label(L("profiles.manage"), systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(
                            Color.accentColor
                        )
                        .frame(width: 34, height: 32)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                    }
                    .accessibilityIdentifier("profileAdd").accessibilityLabel(L("profiles.add"))
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .onChange(of: model.active) {
                if let a = model.active { withAnimation { scroller.scrollTo(a, anchor: .center) } }
            }
        }
        .background(Color(.systemBackground))
    }

    private func chip(_ item: ProfileBarModel.Item) -> some View {
        let on = item.id == model.active
        return Button {
            model.select(item.id)
        } label: {
            HStack(spacing: 6) {
                if let flag = item.flag { Text(flag) } else { Image(systemName: "globe").foregroundStyle(.secondary) }
                Text(item.title).lineLimit(1)
                if on { Circle().fill(color).frame(width: 7, height: 7) }
            }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground)))
            .overlay(Capsule().strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile:" + item.title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .contextMenu {
            Button { model.duplicate(item.id) } label: {
                Label(L("profiles.copy"), systemImage: "doc.on.doc")
            }
            Button {
                model.manage()
            } label: {
                Label(L("profiles.manage"), systemImage: "slider.horizontal.3")
            }
        }
    }

    private var color: Color {
        switch model.dot {
        case .ok: .green
        case .wait: .orange
        case .bad: .red
        }
    }
}
