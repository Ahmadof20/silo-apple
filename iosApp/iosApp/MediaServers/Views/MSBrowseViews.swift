#if !os(macOS)
import SwiftUI

// MARK: - Account home

/// One server's home: Continue Watching, Next Up, libraries, and the newest
/// items in each library.
struct MSAccountHomeView: View {
    let client: any MediaServerClient

    @State private var libraries: [MSLibrary] = []
    @State private var continueWatching: [MSItem] = []
    @State private var nextUp: [MSItem] = []
    @State private var latest: [String: [MSItem]] = [:]
    @State private var isLoading = true
    @State private var error: String?
    @State private var playRequest: MSPlayRequest?

    private var account: MediaServerAccount { client.account }

    var body: some View {
        Group {
            if let error, libraries.isEmpty {
                MSErrorView(message: error) { Task { await load() } }
            } else if isLoading, libraries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle(account.serverName)
        .msScreen()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: MSRoute.search(account)) {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $playRequest, onDismiss: { Task { await load() } }) { request in
            #if os(tvOS)
            TVExternalPlayerView(client: client, item: request.item, resume: request.resume)
            #else
            MSPlayerView(client: client, item: request.item, resume: request.resume)
            #endif
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSMetrics.edge > 40 ? 50 : 26) {
                MSShelf(title: "Continue Watching", items: continueWatching, card: { MSWideCard(item: $0) }) { item in
                    playRequest = MSPlayRequest(account: account, item: item, resume: true)
                }
                MSShelf(title: "Next Up", items: nextUp, card: { MSWideCard(item: $0) }) { item in
                    playRequest = MSPlayRequest(account: account, item: item, resume: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Libraries")
                        .font(.title3.bold())
                        .padding(.horizontal, MSMetrics.edge)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: MSMetrics.rowSpacing) {
                            ForEach(libraries) { library in
                                NavigationLink(value: MSRoute.library(account, library)) {
                                    libraryTile(library)
                                }
                                .msCardButtonStyle()
                            }
                        }
                        .padding(.horizontal, MSMetrics.edge)
                        #if os(tvOS)
                        .padding(.vertical, 30)
                        #endif
                    }
                    #if os(tvOS)
                    .scrollClipDisabled()
                    #endif
                }

                ForEach(libraries) { library in
                    if let items = latest[library.id], !items.isEmpty {
                        MSLatestShelf(account: account, title: "Recently Added in \(library.title)", items: items)
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }

    private func libraryTile(_ library: MSLibrary) -> some View {
        ZStack {
            if let url = library.imageURL {
                MSArtwork(url: url, systemImage: "rectangle.stack")
                Color.black.opacity(0.35)
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(spacing: 6) {
                Image(systemName: library.kind == .shows ? "tv" : library.kind == .movies ? "film" : "folder")
                    .font(.title2)
                Text(library.title)
                    .font(MSMetrics.titleFont)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .frame(width: MSMetrics.thumbWidth * 0.8, height: MSMetrics.thumbWidth * 0.8 * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            libraries = try await client.libraries()
            error = nil
        } catch {
            self.error = error.msMessage
            return
        }
        continueWatching = (try? await client.continueWatching()) ?? []
        let resumingIds = Set(continueWatching.map(\.id))
        nextUp = ((try? await client.nextUp()) ?? []).filter { !resumingIds.contains($0.id) }
        var newest: [String: [MSItem]] = [:]
        for library in libraries {
            newest[library.id] = (try? await client.recentlyAdded(in: library)) ?? []
        }
        latest = newest
    }
}

/// A poster shelf whose cards open the item's detail page.
struct MSLatestShelf: View {
    let account: MediaServerAccount
    let title: String
    let items: [MSItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, MSMetrics.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: MSMetrics.rowSpacing) {
                    ForEach(items) { item in
                        NavigationLink(value: MSRoute.item(account, item)) {
                            MSPosterCard(item: item)
                        }
                        .msCardButtonStyle()
                    }
                }
                .padding(.horizontal, MSMetrics.edge)
                #if os(tvOS)
                .padding(.vertical, 30)
                #endif
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }
}

// MARK: - Library grid

struct MSLibraryView: View {
    let client: any MediaServerClient
    let library: MSLibrary

    @State private var items: [MSItem] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var error: String?

    private let pageSize = 60

    var body: some View {
        Group {
            if let error, items.isEmpty {
                MSErrorView(message: error) { Task { await loadMore(reset: true) } }
            } else if items.isEmpty, !didLoad {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("This library is empty.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .navigationTitle(library.title)
        .msScreen()
        .task { if items.isEmpty { await loadMore(reset: true) } }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MSMetrics.gridMin), spacing: MSMetrics.rowSpacing, alignment: .top)],
                      spacing: MSMetrics.edge > 40 ? 50 : 18) {
                ForEach(items) { item in
                    NavigationLink(value: MSRoute.item(client.account, item)) {
                        MSPosterCard(item: item, width: MSMetrics.gridMin)
                    }
                    .msCardButtonStyle()
                    .onAppear {
                        if item.id == items.last?.id, items.count < total {
                            Task { await loadMore(reset: false) }
                        }
                    }
                }
            }
            .padding(MSMetrics.edge)
            if isLoading, !items.isEmpty {
                ProgressView().padding()
            }
        }
    }

    private func loadMore(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            didLoad = true
        }
        do {
            let page = try await client.items(in: library, start: reset ? 0 : items.count, limit: pageSize)
            if reset { items = page.items } else {
                let known = Set(items.map(\.id))
                items += page.items.filter { !known.contains($0.id) }
            }
            total = page.items.isEmpty ? items.count : page.total
            error = nil
        } catch {
            self.error = error.msMessage
        }
    }
}

// MARK: - Search

struct MSSearchView: View {
    let client: any MediaServerClient

    @State private var query = ""
    @State private var results: [MSItem] = []
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let error {
                Text(error).foregroundStyle(.secondary).padding()
            } else if results.isEmpty, !query.isEmpty, !isSearching {
                Text("No results").foregroundStyle(.secondary).padding(40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MSMetrics.gridMin), spacing: MSMetrics.rowSpacing, alignment: .top)],
                      spacing: MSMetrics.edge > 40 ? 50 : 18) {
                ForEach(results) { item in
                    NavigationLink(value: MSRoute.item(client.account, item)) {
                        MSPosterCard(item: item, width: MSMetrics.gridMin)
                    }
                    .msCardButtonStyle()
                }
            }
            .padding(MSMetrics.edge)
        }
        .navigationTitle("Search")
        .msScreen()
        .searchable(text: $query, prompt: "Movies, shows, episodes")
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { results = []; return }
            // Wait for typing to pause.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                results = try await client.search(text)
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.msMessage }
            }
        }
    }
}
#endif
