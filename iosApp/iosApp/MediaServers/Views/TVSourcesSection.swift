#if os(tvOS)
import SwiftUI

/// One place a title can be played from: the Silo file, or the same movie
/// or episode on an Emby, Jellyfin, Plex, or IPTV subscription.
struct MSSource: Identifiable {
    var id: String { account.id + "|" + item.id }
    let account: MediaServerAccount
    let item: MSItem
    let info: MSMediaInfo?
}

/// Finds a title on every saved subscription at once. Answers are kept for
/// ten minutes so moving between pages stays instant.
@MainActor
final class MSSourceFinder {
    static let shared = MSSourceFinder()

    private var cache: [MSMatchQuery: (date: Date, sources: [MSSource])] = [:]
    private var seriesFacts: [String: (title: String, year: Int?, tmdb: String?)] = [:]

    func sources(for query: MSMatchQuery) async -> [MSSource] {
        if let hit = cache[query], Date().timeIntervalSince(hit.date) < 600 { return hit.sources }
        let store = MediaServerStore.shared
        let clients = store.accounts.compactMap { account in store.client(for: account).map { (account, $0) } }
        var found: [MSSource] = []
        await withTaskGroup(of: MSSource?.self) { group in
            for (account, client) in clients {
                group.addTask {
                    // A slow or offline server must not hold the page back.
                    let match = try? await Self.withTimeout(12) { try await client.findMatch(query) }
                    guard let outer = match, let item = outer, item.isPlayable else { return nil }
                    let infoResult = try? await Self.withTimeout(8) { try await client.mediaInfo(for: item) }
                    let info: MSMediaInfo? = infoResult.flatMap { $0 }
                    return MSSource(account: account, item: item, info: info)
                }
            }
            for await source in group {
                if let source { found.append(source) }
            }
        }
        let order = store.accounts.map(\.id)
        found.sort { (order.firstIndex(of: $0.account.id) ?? 0) < (order.firstIndex(of: $1.account.id) ?? 0) }
        cache[query] = (Date(), found)
        return found
    }

    /// The query for a Silo movie or episode. An episode needs its series'
    /// name, year, and TMDB id, read once from the Silo server.
    func query(for detail: ItemDetail) async -> MSMatchQuery? {
        if detail.type == "episode" {
            guard let season = detail.seasonNumber, let episode = detail.episodeNumber else { return nil }
            var title = detail.seriesTitle ?? ""
            var year: Int?
            var tmdb: String?
            if let seriesId = detail.seriesId {
                if let facts = seriesFacts[seriesId] {
                    (title, year, tmdb) = (facts.title, facts.year, facts.tmdb)
                } else if let series = try? await SiloAPI.shared.itemDetail(contentId: seriesId) {
                    title = series.title
                    year = series.year
                    tmdb = series.tmdbId
                    seriesFacts[seriesId] = (series.title, series.year, series.tmdbId)
                }
            }
            guard !title.isEmpty else { return nil }
            return MSMatchQuery(kind: .episode, title: detail.title, seriesTitle: title, seriesYear: year,
                                seriesTmdbId: tmdb, seasonNumber: season, episodeNumber: episode)
        }
        guard detail.type == "movie" else { return nil }
        return MSMatchQuery(kind: .movie, title: detail.title, year: detail.year,
                            tmdbId: detail.tmdbId, imdbId: detail.imdbId)
    }

    nonisolated static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// "Sources" under a Silo title: the Silo file first, then every
/// subscription that has the same movie or episode. Choosing a card plays
/// from that place.
struct TVSourcesSection: View {
    let detail: ItemDetail
    let onPlaySilo: () -> Void

    @State private var sources: [MSSource] = []
    @State private var isSearching = false
    @State private var playing: MSSource?

    private var hasSubscriptions: Bool { !MediaServerStore.shared.accounts.isEmpty }

    var body: some View {
        if hasSubscriptions {
            VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
                TVSectionHeader(title: "المصادر")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 36) {
                        siloCard
                        ForEach(sources) { source in
                            Button { playing = source } label: {
                                TVSourceCard(
                                    name: source.account.kind.displayName,
                                    server: source.account.serverName,
                                    info: source.info,
                                    style: .init(kind: source.account.kind)
                                )
                            }
                            .buttonStyle(.card)
                        }
                        if isSearching {
                            ProgressView()
                                .frame(width: 120, height: TVSourceCard.height)
                        }
                    }
                    .padding(.vertical, 24)
                    .padding(.horizontal, 4)
                }
                .scrollClipDisabled()
            }
            .focusSection()
            .task(id: detail.contentId) { await load() }
            .fullScreenCover(item: Binding(get: { playing.map(MSSourcePlay.init) }, set: { if $0 == nil { playing = nil } })) { play in
                if let client = MediaServerStore.shared.client(for: play.source.account) {
                    TVExternalPlayerView(client: client, item: play.source.item, resume: true)
                }
            }
        }
    }

    private var siloCard: some View {
        let version = detail.versions?.first
        let info = MSMediaInfo(
            resolution: version?.resolution.map(Self.resolutionLabel),
            videoCodec: version?.codecVideo,
            audioCodec: version?.codecAudio,
            dynamicRange: (version?.hdr ?? false) ? "HDR" : "SDR",
            container: version?.container,
            bitrate: version?.bitrate,
            size: version?.fileSize,
            duration: version?.duration ?? detail.runtime.map { Double($0) * 60 }
        )
        return Button(action: onPlaySilo) {
            TVSourceCard(name: "Silo", server: ServerRegistry.shared.activeServer?.displayName ?? "Silo",
                         info: info, style: .silo)
        }
        .buttonStyle(.card)
    }

    private func load() async {
        guard hasSubscriptions, let query = await MSSourceFinder.shared.query(for: detail) else { return }
        isSearching = true
        sources = await MSSourceFinder.shared.sources(for: query)
        isSearching = false
    }

    /// Silo reports "2160p", "4K", or a bare height.
    static func resolutionLabel(_ raw: String) -> String {
        if let height = Int(raw) { return MSMediaInfo.resolution(height: height) ?? raw }
        if raw.lowercased() == "4k" { return "2160p" }
        return raw
    }
}

private struct MSSourcePlay: Identifiable {
    let source: MSSource
    var id: String { source.id }
}

/// A source card, as on the Silo web app: name and server on top, the file's
/// resolution and codecs in the middle, length, bitrate, and size below.
struct TVSourceCard: View {
    struct Style {
        let tint: Color
        let symbol: String

        static let silo = Style(tint: Color(red: 0.16, green: 0.32, blue: 0.86), symbol: "play.square.stack.fill")

        init(tint: Color, symbol: String) {
            self.tint = tint
            self.symbol = symbol
        }

        init(kind: MediaServerKind) {
            switch kind {
            case .emby: self.init(tint: Color(red: 0.18, green: 0.62, blue: 0.28), symbol: "server.rack")
            case .plex: self.init(tint: Color(red: 0.80, green: 0.55, blue: 0.08), symbol: "play.rectangle.on.rectangle.fill")
            case .iptv: self.init(tint: Color(red: 0.50, green: 0.26, blue: 0.80), symbol: "tv.fill")
            }
        }
    }

    static let width: CGFloat = 470
    static let height: CGFloat = 210

    let name: String
    let server: String
    let info: MSMediaInfo?
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: style.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 32, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let range = info?.dynamicRange {
                    Text(range)
                        .font(.system(size: 20, weight: .heavy))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.2), in: Capsule())
                }
            }
            Text(formatLine)
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 20) {
                if let duration = info?.duration, duration > 0 {
                    Label(MSFormat.clock(duration), systemImage: "clock")
                }
                if let bitrate = info?.bitrate, bitrate > 0 {
                    Label(MSFormat.bitrate(bitrate), systemImage: "waveform")
                }
                if let size = info?.size, size > 0 {
                    Label(MSFormat.size(size), systemImage: "internaldrive")
                }
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(
            LinearGradient(colors: [style.tint, style.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var subtitle: String {
        var parts = [server]
        if let added = info?.addedAt { parts.append(MSFormat.relative(added)) }
        return parts.joined(separator: " · ")
    }

    private var formatLine: String {
        let parts = [info?.resolution, info?.videoCodec?.lowercased(), info?.audioCodec?.lowercased()].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
#endif
