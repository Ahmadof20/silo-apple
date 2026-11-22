#if os(tvOS)
import SwiftUI

/// The detail page of an Emby, Jellyfin, Plex, or IPTV title, laid out like
/// Silo's own: the artwork behind, title, facts, the description (translated
/// by AI when a key is set), the file's version, audio, and subtitles, the
/// play buttons, episodes, and the other places the title can play from.
struct TVMSDetailView: View {
    let client: any MediaServerClient

    @State private var item: MSItem
    @State private var seasons: [MSItem] = []
    @State private var selectedSeasonId: String?
    @State private var episodes: [MSItem] = []
    @State private var info: MSMediaInfo?
    @State private var overview: String?
    @State private var overviewTranslated = false
    @State private var isTranslating = false
    @State private var playRequest: PlayRequest?
    @State private var error: String?
    @FocusState private var playFocused: Bool

    private struct PlayRequest: Identifiable {
        let id = UUID()
        let client: any MediaServerClient
        let item: MSItem
        let resume: Bool
    }

    init(client: any MediaServerClient, item: MSItem) {
        self.client = client
        _item = State(initialValue: item)
    }

    /// What Play starts: the movie or episode itself, or a series' next episode.
    private var playTarget: MSItem? {
        if item.isPlayable { return item }
        return episodes.first { $0.resumePosition > 0 && !$0.isWatched }
            ?? episodes.first { !$0.isWatched }
            ?? episodes.first
    }

    var body: some View {
        TVDetailPageSurface(backdropURL: (item.backdropURL ?? item.thumbURL)?.absoluteString) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
                    ZStack(alignment: .bottomLeading) {
                        backdrop
                        hero.padding(.horizontal, TVDetailLayout.horizontalInset)
                    }
                    VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
                        if item.kind == .series {
                            episodesSection
                        }
                        otherSources
                    }
                    .padding(.horizontal, TVDetailLayout.horizontalInset)
                }
                .padding(.bottom, TVDetailLayout.pageBottomPadding)
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        .task(id: item.id) { await load() }
        .fullScreenCover(item: $playRequest, onDismiss: { Task { await refresh() } }) { request in
            TVExternalPlayerView(client: request.client, item: request.item, resume: request.resume)
        }
    }

    // MARK: - Hero

    /// The artwork across the top, fading into the page and darkened on the
    /// leading side under the text.
    private var backdrop: some View {
        MSArtwork(url: item.backdropURL ?? item.thumbURL ?? item.posterURL)
            .frame(maxWidth: .infinity)
            .frame(height: TVDetailLayout.heroHeight + 160)
            .clipped()
            .overlay {
                LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.25), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
            .mask {
                LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            Text(item.kind == .episode ? (item.seriesTitle ?? item.title) : item.title)
                .font(.system(size: 78, weight: .heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.4), radius: 8)

            factsRow

            if let text = overview ?? item.overview, !text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.kind == .episode ? "\(item.title) · \(text)" : text)
                        .font(.system(size: 28))
                        .lineLimit(4)
                        .foregroundStyle(.white.opacity(0.92))
                    if isTranslating {
                        Text(DescriptionTranslationStatus.translating.resource)
                            .font(.system(size: 22)).foregroundStyle(.secondary)
                    } else if overviewTranslated {
                        Label {
                            Text(MachineTranslation.label)
                        } icon: {
                            Image(systemName: MachineTranslation.symbol)
                        }
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            fileLine
            actionRow
        }
        .frame(maxWidth: TVDetailLayout.heroContentWidth, alignment: .leading)
        .frame(minHeight: TVDetailLayout.heroHeight - TVDetailLayout.heroTopInset, alignment: .bottomLeading)
        .padding(.top, TVDetailLayout.heroTopInset)
    }

    private var factsRow: some View {
        HStack(spacing: 18) {
            if let rating = item.officialRating, !rating.isEmpty {
                Text(rating)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.7), lineWidth: 2))
            }
            ForEach(facts, id: \.self) { fact in
                Text(fact)
            }
            Text(client.account.kind.displayName + " · " + client.account.serverName)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 26, weight: .medium))
        .lineLimit(1)
    }

    private var facts: [String] {
        var list: [String] = []
        if let year = item.year { list.append(String(year)) }
        if let duration = (item.isPlayable ? item.duration : playTarget?.duration), duration > 0 {
            list.append(MSFormat.runtime(duration))
        }
        if let season = item.seasonNumber, item.kind == .episode {
            list.append("الموسم \(season)")
            if let episode = item.episodeNumber { list.append("الحلقة \(episode)") }
        }
        if let score = item.communityRating, score > 0 { list.append(String(format: "★ %.1f", score)) }
        list.append(contentsOf: item.genres.prefix(2))
        return list
    }

    /// VERSION / AUDIO / SUBTITLES, as on Silo's detail page.
    @ViewBuilder
    private var fileLine: some View {
        if let info {
            HStack(spacing: 34) {
                fact("VERSION", [info.resolution, info.dynamicRange].compactMap { $0 })
                fact("AUDIO", [info.audioLanguages.first.map(Self.languageName), info.audioCodec?.uppercased()].compactMap { $0 })
                if !info.subtitleLanguages.isEmpty {
                    fact("SUBTITLES", info.subtitleLanguages.prefix(3).map(Self.languageName))
                }
            }
            .font(.system(size: 22, weight: .medium))
        }
    }

    private func fact(_ title: String, _ values: [String]) -> some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.heavy).foregroundStyle(.secondary)
            Text(values.isEmpty ? "Auto" : values.joined(separator: " · "))
        }
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private var actionRow: some View {
        HStack(spacing: 22) {
            if let target = playTarget {
                Button {
                    playRequest = PlayRequest(client: client, item: target, resume: true)
                } label: {
                    Label(playTitle(target), systemImage: "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .padding(.horizontal, 30)
                }
                .focused($playFocused)

                if target.resumePosition > 0 {
                    Button {
                        playRequest = PlayRequest(client: client, item: target, resume: false)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                }

                Button {
                    Task { await toggleWatched(target) }
                } label: {
                    Image(systemName: target.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                }
            }
        }
        .padding(.top, 8)
    }

    private func playTitle(_ target: MSItem) -> String {
        let label = target.kind == .episode ? target.episodeLabel.map { " \($0)" } ?? "" : ""
        return (target.resumePosition > 0 ? "متابعة" : "تشغيل") + label
    }

    // MARK: - Episodes

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(seasons) { season in
                            Button {
                                Task { await selectSeason(season) }
                            } label: {
                                Text(season.title)
                                    .font(.system(size: 24, weight: .semibold))
                                    .padding(.horizontal, 18)
                            }
                            .buttonStyle(.bordered)
                            .tint(season.id == selectedSeasonId ? .white : nil)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(episodes) { episode in
                        Button {
                            playRequest = PlayRequest(client: client, item: episode, resume: true)
                        } label: {
                            episodeCard(episode)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func episodeCard(_ episode: MSItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MSArtwork(url: episode.thumbURL ?? episode.backdropURL ?? episode.posterURL)
                .frame(width: 420, height: 236)
                .clipped()
                .overlay(alignment: .bottom) {
                    if let fraction = episode.progressFraction {
                        MSProgressBar(fraction: fraction).padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) { MSWatchedBadge(item: episode) }
            VStack(alignment: .leading, spacing: 4) {
                Text([episode.episodeLabel, episode.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                if let duration = episode.duration, duration > 0 {
                    Text(MSFormat.runtime(duration))
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 420, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Other sources

    @ViewBuilder
    private var otherSources: some View {
        if let target = playTarget, MediaServerStore.shared.accounts.count > 1 {
            TVOtherSourcesRow(current: client.account, item: target, seriesTitle: item.kind == .series ? item.title : item.seriesTitle,
                              seriesYear: item.kind == .series ? item.year : nil,
                              seriesTmdb: item.kind == .series ? item.tmdbId : nil)
        }
    }

    // MARK: - Loading

    private func load() async {
        do {
            item = try await client.detail(id: item.id)
            error = nil
        } catch {
            self.error = error.msMessage
        }
        if item.kind == .series {
            seasons = (try? await client.children(of: item)) ?? []
            let season = seasons.first { ($0.unwatchedCount ?? 1) > 0 } ?? seasons.first
            if let season { await selectSeason(season) }
        }
        if let target = playTarget {
            info = try? await client.mediaInfo(for: target)
        }
        playFocused = true
        await translateOverview()
    }

    private func refresh() async {
        if let fresh = try? await client.detail(id: item.id) { item = fresh }
        if let season = seasons.first(where: { $0.id == selectedSeasonId }) {
            episodes = (try? await client.children(of: season)) ?? episodes
        }
    }

    private func selectSeason(_ season: MSItem) async {
        selectedSeasonId = season.id
        episodes = (try? await client.children(of: season)) ?? []
    }

    private func toggleWatched(_ target: MSItem) async {
        try? await client.setWatched(!target.isWatched, item: target)
        await refresh()
    }

    /// Translates the description with the person's AI key when it is not
    /// already in their language.
    private func translateOverview() async {
        guard MSAISettings.isConfigured, let text = item.overview, !text.isEmpty,
              !MSAITranslator.isInTargetLanguage(text) else { return }
        isTranslating = true
        defer { isTranslating = false }
        if let translated = try? await MSAITranslator.shared.translate(text) {
            overview = translated
            overviewTranslated = true
        }
    }
}

/// The same movie or episode on the person's other subscriptions.
struct TVOtherSourcesRow: View {
    let current: MediaServerAccount
    let item: MSItem
    let seriesTitle: String?
    let seriesYear: Int?
    let seriesTmdb: String?

    @State private var sources: [MSSource] = []
    @State private var playing: MSSource?

    var body: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            if !sources.isEmpty {
                TVSectionHeader(title: "المصادر")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 36) {
                        ForEach(sources) { source in
                            Button { playing = source } label: {
                                TVSourceCard(name: source.account.kind.displayName, server: source.account.serverName,
                                             info: source.info, style: .init(kind: source.account.kind))
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
        }
        .task(id: item.id) {
            let query: MSMatchQuery
            if item.kind == .episode {
                query = MSMatchQuery(kind: .episode, title: item.title, seriesTitle: seriesTitle ?? item.seriesTitle,
                                     seriesYear: seriesYear, seriesTmdbId: seriesTmdb,
                                     seasonNumber: item.seasonNumber, episodeNumber: item.episodeNumber)
            } else {
                query = MSMatchQuery(kind: .movie, title: item.title, year: item.year, tmdbId: item.tmdbId, imdbId: item.imdbId)
            }
            sources = await MSSourceFinder.shared.sources(for: query).filter { $0.account.id != current.id }
        }
        .fullScreenCover(item: Binding(get: { playing.map(MSOtherPlay.init) }, set: { if $0 == nil { playing = nil } })) { play in
            if let client = MediaServerStore.shared.client(for: play.source.account) {
                TVExternalPlayerView(client: client, item: play.source.item, resume: true)
            }
        }
    }
}

private struct MSOtherPlay: Identifiable {
    let source: MSSource
    var id: String { source.id }
}
#endif
