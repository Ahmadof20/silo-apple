#if os(tvOS)
import SwiftUI

/// Turns Emby, Jellyfin, Plex, and IPTV libraries into Silo rows, so their
/// titles show inside the Movies and Series tabs with Silo's own cards,
/// focus marquee, and row layout instead of tabs of their own.
///
/// A row's cards carry ids starting with `ms:`; `origin(of:)` maps a card
/// back to its server and item when it is chosen.
@MainActor
final class MSExternalRows {
    static let shared = MSExternalRows()

    static let itemPrefix = "ms:"
    static let sectionPrefix = "ms-section:"

    struct Origin {
        let account: MediaServerAccount
        let item: MSItem
    }

    private var origins: [String: Origin] = [:]
    private var tabs: [String: MSTVTab] = [:]
    private var cache: [Bool: (date: Date, sections: [ResolvedSection])] = [:]

    static func isExternal(_ id: String) -> Bool { id.hasPrefix(itemPrefix) }
    static func isExternalSection(_ id: String) -> Bool { id.hasPrefix(sectionPrefix) }

    func origin(of contentId: String) -> Origin? { origins[contentId] }
    func tab(forSection id: String) -> MSTVTab? { tabs[id] }

    /// One row per movie (or series) library on every saved subscription:
    /// its newest titles, with an Explore all card for the whole library.
    func sections(shows: Bool) async -> [ResolvedSection] {
        if let hit = cache[shows], Date().timeIntervalSince(hit.date) < 300 { return hit.sections }
        let store = MediaServerStore.shared
        var rows: [ResolvedSection] = []
        for account in store.accounts {
            guard let client = store.client(for: account) else { continue }
            let libraries = (try? await MSSourceFinder.withTimeout(15) { try await client.libraries() }) ?? nil
            for library in libraries ?? [] where library.kind == (shows ? .shows : .movies) {
                let fetched = try? await MSSourceFinder.withTimeout(20) { try await client.recentlyAdded(in: library) }
                let items = (fetched ?? nil) ?? []
                guard !items.isEmpty else { continue }
                let sectionId = Self.sectionPrefix + account.id + ":" + library.id
                tabs[sectionId] = MSTVTab(
                    accountId: account.id, libraryId: library.id, libraryTitle: library.title,
                    serverKind: account.kind.displayName, isShows: shows
                )
                let cards = items.prefix(20).compactMap { sectionItem($0, account: account) }
                rows.append(ResolvedSection(
                    id: sectionId,
                    sectionType: "recently_added",
                    title: "\(account.kind.displayName) · \(library.title)",
                    featured: false,
                    itemLimit: cards.count,
                    totalCount: nil,
                    isCustom: true,
                    customized: false,
                    items: cards
                ))
            }
        }
        cache[shows] = (Date(), rows)
        return rows
    }

    /// A Silo card for a media-server item, decoded the way the server's own
    /// rows are, so every card feature reads it as usual.
    func sectionItem(_ item: MSItem, account: MediaServerAccount) -> SectionItem? {
        let contentId = Self.itemPrefix + account.id + ":" + item.id
        origins[contentId] = Origin(account: account, item: item)
        var json: [String: Any] = [
            "content_id": contentId,
            "type": Self.siloType(item.kind),
            "title": item.title,
            "user_state": ["played": item.isWatched, "is_favorite": false, "in_watchlist": false],
        ]
        if let year = item.year { json["year"] = year }
        if let overview = item.overview { json["overview"] = overview }
        if let poster = item.posterURL?.absoluteString { json["poster_url"] = poster }
        if let backdrop = (item.backdropURL ?? item.thumbURL)?.absoluteString { json["backdrop_url"] = backdrop }
        if !item.genres.isEmpty { json["genres"] = item.genres }
        if let rating = item.officialRating { json["content_rating"] = rating }
        if let duration = MSSafe.duration(item.duration), let minutes = MSSafe.int(duration / 60) {
            json["runtime"] = minutes
            json["duration_seconds"] = duration
        }
        if item.resumePosition > 0 { json["position_seconds"] = item.resumePosition }
        if let series = item.seriesTitle { json["series_title"] = series }
        if let season = item.seasonNumber { json["season_number"] = season }
        if let episode = item.episodeNumber { json["episode_number"] = episode }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? HTTPClient.makeJSONDecoder().decode(SectionItem.self, from: data)
    }

    static func siloType(_ kind: MSItem.Kind) -> String {
        switch kind {
        case .movie, .video: "movie"
        case .series: "series"
        case .season: "season"
        case .episode: "episode"
        case .folder, .other: "movie"
        }
    }

    func invalidate() { cache.removeAll() }
}

/// Opens media-server cards and rows from a Silo page: a title Silo also has
/// opens Silo's own page; anything else opens the media server's page.
struct MSExternalPresenter: ViewModifier {
    @Binding var request: MSExternalRequest?
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $request) { request in
            switch request.kind {
            case .detail(let client, let item):
                NavigationStack {
                    TVMSDetailView(client: client, item: item)
                }
                .environmentObject(OverlayPrefsStore.shared)
            case .library(let tab):
                TVMediaServerLibraryPage(tab: tab, focusRequest: 1, isTopMenuFocused: false, onTopMenuFocusRequest: {}) { siloId in
                    self.request = nil
                    // The cover closes first, so the Silo page lands on the
                    // stack that is on screen.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        router.navigate(to: .itemDetail(contentId: siloId))
                    }
                }
                .siloBackground()
                .environmentObject(OverlayPrefsStore.shared)
            }
        }
    }
}

struct MSExternalRequest: Identifiable {
    enum Kind {
        case detail(any MediaServerClient, MSItem)
        case library(MSTVTab)
    }
    let id = UUID()
    let kind: Kind

    /// What choosing a media-server card does: Silo's page for a title Silo
    /// also has, otherwise a request for the media server's page.
    @MainActor
    static func open(contentId: String, router: AppRouter) async -> MSExternalRequest? {
        guard let origin = MSExternalRows.shared.origin(of: contentId),
              let client = MediaServerStore.shared.client(for: origin.account) else { return nil }
        if let siloId = await MSSiloBridge.shared.siloContentId(for: origin.item, account: origin.account) {
            router.navigate(to: .itemDetail(contentId: siloId))
            return nil
        }
        return MSExternalRequest(kind: .detail(client, origin.item))
    }
}
#endif
