#if os(tvOS)
import SwiftUI

/// One Emby, Jellyfin, or Plex movie or series library shown as its own tab
/// in the Apple TV top bar, next to Silo's tabs.
struct MSTVTab: Hashable, Codable {
    let accountId: String
    let libraryId: String
    let libraryTitle: String
    let serverKind: String
    let isShows: Bool

    var title: String { "\(serverKind) · \(libraryTitle)" }

    var library: MSLibrary {
        MSLibrary(id: libraryId, title: libraryTitle, kind: isShows ? .shows : .movies)
    }
}

/// The media-server tabs for every saved account. Cached so the bar's first
/// frame already has them.
@MainActor
@Observable
final class MSTVTabStore {
    static let shared = MSTVTabStore()

    private static let cacheKey = "mediaServers.tvTabs.v1"
    private(set) var tabs: [MSTVTab]

    private init() {
        tabs = UserDefaults.standard.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode([MSTVTab].self, from: $0) } ?? []
    }

    func refresh() async {
        let store = MediaServerStore.shared
        var result: [MSTVTab] = []
        for account in store.accounts {
            guard let client = store.client(for: account) else { continue }
            do {
                let libraries = try await client.libraries()
                for library in libraries where library.kind == .movies || library.kind == .shows {
                    result.append(MSTVTab(
                        accountId: account.id,
                        libraryId: library.id,
                        libraryTitle: library.title,
                        serverKind: account.kind.displayName,
                        isShows: library.kind == .shows
                    ))
                }
            } catch {
                // Server unreachable right now: keep its last known tabs.
                result.append(contentsOf: tabs.filter { $0.accountId == account.id })
            }
        }
        guard result != tabs else { return }
        tabs = result
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

/// Refreshes the media-server tabs whenever the saved accounts change.
struct MSTVTabRefresh: ViewModifier {
    @State private var store = MediaServerStore.shared

    func body(content: Content) -> some View {
        content.task(id: store.accounts.map { $0.id }) {
            await MSTVTabStore.shared.refresh()
        }
    }
}

/// A media-server library page under the top bar. A title Silo also has
/// opens in Silo's own detail page (translation, subtitles, AI subtitles);
/// anything else opens the media server's own detail page and player.
struct TVMediaServerLibraryPage: View {
    let tab: MSTVTab
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onTopMenuFocusRequest: () -> Void

    @Environment(AppRouter.self) private var router
    @State private var items: [MSItem] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var error: String?
    @State private var openingId: String?
    @State private var serverDetail: MSItem?
    @FocusState private var focusedId: String?

    private static let pageSize = 60
    private static let columnCount = 6
    private let columns = Array(
        repeating: GridItem(.fixed(MSMetrics.posterWidth), spacing: 48, alignment: .top),
        count: columnCount
    )

    private var account: MediaServerAccount? {
        MediaServerStore.shared.accounts.first { $0.id == tab.accountId }
    }

    private var client: (any MediaServerClient)? {
        account.flatMap { MediaServerStore.shared.client(for: $0) }
    }

    var body: some View {
        Group {
            if let error, items.isEmpty {
                MSErrorView(message: error) { Task { await load(reset: true) } }
                    .padding(.top, TVTopMenuLayout.contentTopInset)
            } else if didLoad, items.isEmpty {
                Text("This library is empty.")
                    .font(MSMetrics.titleFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .task(id: tab) { await load(reset: true) }
        .onChange(of: focusRequest) { _, _ in
            guard !isTopMenuFocused else { return }
            focusedId = items.first?.id
        }
        .fullScreenCover(item: $serverDetail) { item in
            if let client {
                MSTVServerDetailCover(client: client, item: item)
            }
        }
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { open(item) } label: {
                        MSPosterCard(item: item)
                            .overlay {
                                if openingId == item.id {
                                    ProgressView()
                                        .padding(24)
                                        .background(.black.opacity(0.55), in: Circle())
                                }
                            }
                    }
                    .msCardButtonStyle()
                    .focused($focusedId, equals: item.id)
                    .onMoveCommand { direction in
                        if direction == .up, index < Self.columnCount { onTopMenuFocusRequest() }
                    }
                    .onAppear {
                        if index == items.count - 1 { Task { await load(reset: false) } }
                    }
                }
            }
            .padding(.horizontal, MSMetrics.edge)
            .padding(.top, TVTopMenuLayout.contentTopInset)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
    }

    private func load(reset: Bool) async {
        guard let client, !isLoading else { return }
        if !reset, didLoad, items.count >= total { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.items(in: tab.library, start: reset ? 0 : items.count, limit: Self.pageSize)
            if reset { items = page.items } else { items.append(contentsOf: page.items) }
            total = page.total
            error = nil
        } catch {
            self.error = error.msMessage
        }
        didLoad = true
        if reset, focusedId == nil, !isTopMenuFocused { focusedId = items.first?.id }
    }

    private func open(_ item: MSItem) {
        guard openingId == nil, let account else { return }
        openingId = item.id
        Task { @MainActor in
            defer { openingId = nil }
            if let contentId = await MSSiloBridge.shared.siloContentId(for: item, account: account) {
                router.navigate(to: .itemDetail(contentId: contentId))
            } else {
                serverDetail = item
            }
        }
    }
}

/// The media server's own detail page, for titles Silo does not have.
private struct MSTVServerDetailCover: View {
    let client: any MediaServerClient
    let item: MSItem

    var body: some View {
        NavigationStack {
            TVMSDetailView(client: client, item: item)
                .navigationDestination(for: MSRoute.self) { route in
                    switch route {
                    case .item(_, let child):
                        TVMSDetailView(client: client, item: child)
                    case .library(_, let library):
                        MSLibraryView(client: client, library: library)
                    default:
                        EmptyView()
                    }
                }
        }
    }
}
#endif
