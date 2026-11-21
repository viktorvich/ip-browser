import SwiftUI

/// The tab switcher: a grid of page snapshots, like Safari's.
struct TabsView: View {
    struct Item: Identifiable {
        let id: ObjectIdentifier
        let title: String
        let host: String
        let image: UIImage?
        let current: Bool
    }
    @State var items: [Item]
    /// The profile these tabs belong to («🇺🇿 Ташкент»): other profiles' tabs are not here.
    var profile: String? = nil
    let onSelect: (ObjectIdentifier) -> Void
    let onClose: (ObjectIdentifier) -> Void
    let onNew: () -> Void
    let onDone: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.id)
                        } label: {
                            VStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Button {
                                        close(item.id)
                                    } label: {
                                        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(
                                            .secondary
                                        )
                                        .frame(width: 24, height: 24)
                                    }.buttonStyle(.plain).accessibilityLabel(L("tab.close"))
                                }
                                .padding(.leading, 10).padding(.trailing, 4).frame(height: 30)
                                .background(Color(.tertiarySystemBackground))
                                Group {
                                    if let image = item.image {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        VStack(spacing: 8) {
                                            Image(systemName: "globe").font(.largeTitle).foregroundStyle(.tertiary)
                                            Text(L("tab.start")).font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(
                                            Color(.systemBackground))
                                    }
                                }
                                .frame(height: 210).clipped()
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(
                                        item.current ? Color.accentColor : Color(.separator),
                                        lineWidth: item.current ? 3 : 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle((profile.map { $0 + " · " } ?? "") + String(format: L("tabs.count"), items.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onNew) { Image(systemName: "plus") }.accessibilityLabel(L("tab.new"))
                }
                ToolbarItem(placement: .confirmationAction) { Button(L("done"), action: onDone) }
            }
        }
    }

    private func close(_ id: ObjectIdentifier) {
        withAnimation { items.removeAll { $0.id == id } }
        onClose(id)
    }
}

/// Favourites and history.
struct LibraryView: View {
    let onOpen: (URL) -> Void
    let onDone: () -> Void
    @ObservedObject var library = BrowserLibrary.shared
    @State private var section = 0
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if section == 0 {
                    if library.favorites.isEmpty {
                        Text(L("library.noFavorites")).foregroundStyle(.secondary)
                    }
                    let shown = library.favorites.filter { matches($0.title, $0.url) }
                    ForEach(shown) { f in
                        row(title: f.title, url: f.url)
                    }
                    .onDelete { idx in library.removeFavorites(Set(idx.map { shown[$0].id })) }
                    .onMove(perform: query.isEmpty ? { library.moveFavorites(from: $0, to: $1) } : nil)
                } else {
                    if library.history.isEmpty { Text(L("library.noHistory")).foregroundStyle(.secondary) }
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.visits) { v in row(title: v.title, url: v.url, time: v.date) }
                                .onDelete { idx in library.removeVisits(Set(idx.map { group.visits[$0].id })) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: L("library.search"))
            .navigationTitle(L("library.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $section) {
                        Text(L("start.favorites")).tag(0)
                        Text(L("library.history")).tag(1)
                    }.pickerStyle(.segmented).frame(width: 240)
                }
                ToolbarItem(placement: .confirmationAction) { Button(L("done"), action: onDone) }
                ToolbarItem(placement: .bottomBar) {
                    if section == 0 {
                        EditButton()
                    } else {
                        Button(L("library.clear"), role: .destructive) { confirmClear = true }.disabled(
                            library.history.isEmpty)
                    }
                }
            }
            .confirmationDialog(L("library.clear"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button(L("library.clear"), role: .destructive) { library.clearHistory() }
            }
        }
    }

    private func row(title: String, url: URL, time: Date? = nil) -> some View {
        Button {
            onOpen(url)
        } label: {
            HStack(spacing: 12) {
                SiteTile(title: title, url: url, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Color.primary).lineLimit(1)
                    Text(url.host ?? url.absoluteString).font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
                }
                Spacer()
                if let time { Text(time, style: .time).font(.caption).foregroundStyle(Color.secondary) }
            }
        }
    }

    private func matches(_ title: String, _ url: URL) -> Bool {
        let q = query.lowercased()
        return q.isEmpty || title.lowercased().contains(q) || url.absoluteString.lowercased().contains(q)
    }

    private var groups: [(title: String, visits: [BrowserLibrary.Visit])] {
        let list = library.history.filter { matches($0.title, $0.url) }
        let cal = Calendar.current
        var out: [(String, [BrowserLibrary.Visit])] = []
        for v in list {
            let title =
                cal.isDateInToday(v.date)
                ? L("library.today")
                : cal.isDateInYesterday(v.date)
                    ? L("library.yesterday")
                    : v.date.formatted(date: .complete, time: .omitted)
            if out.last?.0 == title { out[out.count - 1].1.append(v) } else { out.append((title, [v])) }
        }
        return out.map { (title: $0.0, visits: $0.1) }
    }
}
