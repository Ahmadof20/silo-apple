#if !os(macOS)
import Foundation
import OSLog

/// Joins Emby, Jellyfin, and Plex titles to the signed-in Silo server.
///
/// When Silo has the same movie or series, the title opens in Silo's own
/// detail page and player, so description translation, subtitle search, and
/// AI subtitles all work. After Silo playback ends, the watched state or
/// resume point is written back to the media server the title came from.
@MainActor
final class MSSiloBridge {
    static let shared = MSSiloBridge()

    /// The media-server title a Silo content id was opened from.
    struct Link: Codable, Hashable {
        let accountId: String
        let itemId: String
        let isSeries: Bool
    }

    private static let linksKey = "mediaServers.siloLinks.v1"
    private static let matchesKey = "mediaServers.siloMatches.v1"
    /// A miss is retried after this long, in case Silo adds the title.
    private static let missLifetime: TimeInterval = 10 * 60

    /// Silo content id → where it came from. Persisted so playback started
    /// after a relaunch still syncs back.
    private var links: [String: Link]
    /// "accountId|itemId" → Silo content id.
    private var matches: [String: String]
    private var misses: [String: Date] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo", category: "MediaServers")

    private init() {
        let defaults = UserDefaults.standard
        links = defaults.data(forKey: Self.linksKey)
            .flatMap { try? JSONDecoder().decode([String: Link].self, from: $0) } ?? [:]
        matches = defaults.dictionary(forKey: Self.matchesKey) as? [String: String] ?? [:]
    }

    // MARK: - Matching

    /// The Silo content id of the same movie or series, or nil when Silo has
    /// no copy (or nobody is signed in to Silo).
    func siloContentId(for item: MSItem, account: MediaServerAccount) async -> String? {
        guard item.kind == .movie || item.kind == .series else { return nil }
        let key = account.id + "|" + item.id
        if let hit = matches[key] { return hit }
        if let missedAt = misses[key], Date().timeIntervalSince(missedAt) < Self.missLifetime { return nil }

        guard let found = await findOnSilo(item) else {
            misses[key] = Date()
            return nil
        }
        matches[key] = found
        links[found] = Link(accountId: account.id, itemId: item.id, isSeries: item.kind == .series)
        save()
        return found
    }

    /// Forgets a match that turned out wrong (the Silo title failed to open).
    func forgetMatch(for item: MSItem, account: MediaServerAccount) {
        let key = account.id + "|" + item.id
        if let id = matches.removeValue(forKey: key) { links.removeValue(forKey: id) }
        save()
    }

    private func findOnSilo(_ item: MSItem) async -> String? {
        let isSeries = item.kind == .series
        let siloType = isSeries ? "series" : "movie"

        // 1. Exact: Silo's TMDB lookup names its own library copy.
        if let tmdb = item.tmdbId.flatMap({ Int($0) }),
           let detail = try? await SiloAPI.shared.requestsDetail(mediaType: isSeries ? .series : .movie, tmdbId: tmdb),
           let id = detail.libraryContentId, !id.isEmpty {
            return id
        }

        // 2. Title search, confirmed by TMDB or IMDb id when known.
        guard !item.title.isEmpty,
              let page = try? await SiloAPI.shared.catalogPage(.search(item.title, type: siloType, limit: 12)) else {
            return nil
        }
        let wanted = Self.normalize(item.title)
        let candidates = page.response.items.filter { candidate in
            candidate.type == siloType
                && Self.normalize(candidate.title) == wanted
                && Self.yearsAgree(candidate.year, item.year)
        }
        guard !candidates.isEmpty else { return nil }

        if item.tmdbId != nil || item.imdbId != nil {
            for candidate in candidates.prefix(4) {
                guard let detail = try? await SiloAPI.shared.itemDetail(contentId: candidate.contentId) else { continue }
                if let tmdb = item.tmdbId, let siloTmdb = detail.tmdbId {
                    if siloTmdb == tmdb { return candidate.contentId }
                    continue
                }
                if let imdb = item.imdbId, let siloImdb = detail.imdbId {
                    if siloImdb.lowercased() == imdb.lowercased() { return candidate.contentId }
                    continue
                }
                if candidates.count == 1 { return candidate.contentId }
            }
            return nil
        }
        return candidates.count == 1 ? candidates[0].contentId : nil
    }

    static func normalize(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func yearsAgree(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= 1
    }

    // MARK: - Watch state back to the media server

    /// Called by the Silo player when it leaves an item.
    func siloPlaybackEnded(contentId: String, seriesId: String?, seasonNumber: Int?, episodeNumber: Int?,
                           position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, position > 0 else { return }
        let link: Link
        if let movie = links[contentId], !movie.isSeries {
            link = movie
        } else if let seriesId, let series = links[seriesId], series.isSeries {
            link = series
        } else {
            return
        }
        Task { await sync(link, seasonNumber: seasonNumber, episodeNumber: episodeNumber,
                          position: position, duration: duration) }
    }

    private func sync(_ link: Link, seasonNumber: Int?, episodeNumber: Int?,
                      position: Double, duration: Double) async {
        let store = MediaServerStore.shared
        guard let account = store.accounts.first(where: { $0.id == link.accountId }),
              let client = store.client(for: account) else { return }
        do {
            let target: MSItem
            if link.isSeries {
                guard let seasonNumber, let episodeNumber else { return }
                let series = try await client.detail(id: link.itemId)
                let seasons = try await client.children(of: series)
                guard let season = seasons.first(where: { $0.seasonNumber == seasonNumber }) else { return }
                let episodes = try await client.children(of: season)
                guard let episode = episodes.first(where: { $0.episodeNumber == episodeNumber }) else { return }
                target = episode
            } else {
                target = try await client.detail(id: link.itemId)
            }

            let finished = duration > 0 && position / duration >= 0.9
            if finished {
                if !target.isWatched { try await client.setWatched(true, item: target) }
            } else if position >= 60 {
                try await client.saveResume(target, position: position)
            }
        } catch {
            logger.warning("Watch-state sync to \(account.kind.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(links) { defaults.set(data, forKey: Self.linksKey) }
        defaults.set(matches, forKey: Self.matchesKey)
    }
}
#endif
