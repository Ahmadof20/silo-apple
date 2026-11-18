#if !os(macOS)
import SwiftUI

/// Detail page for a movie, series, season, episode, or folder. Series and
/// seasons list their episodes; folders list their contents.
struct MSItemDetailView: View {
    let client: any MediaServerClient

    @State private var item: MSItem
    @State private var seasons: [MSItem] = []
    @State private var selectedSeasonId: String?
    @State private var episodes: [MSItem] = []
    @State private var children: [MSItem] = []
    @State private var error: String?
    @State private var playRequest: MSPlayRequest?
    @State private var isUpdatingWatched = false

    init(client: any MediaServerClient, item: MSItem) {
        self.client = client
        _item = State(initialValue: item)
    }

    private var account: MediaServerAccount { client.account }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: MSMetrics.edge > 40 ? 36 : 18) {
                    actions
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(MSMetrics.edge > 40 ? Font.system(size: 26) : Font.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(MSMetrics.edge > 40 ? 6 : nil)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                    if !item.genres.isEmpty {
                        Text(item.genres.prefix(4).joined(separator: " · "))
                            .font(MSMetrics.captionFont)
                            .foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, MSMetrics.edge)
                .padding(.top, 16)

                if item.kind == .series {
                    seasonPicker.padding(.top, 24)
                }
                if item.kind == .series || item.kind == .season {
                    episodeList.padding(.top, 12)
                }
                if item.kind == .folder {
                    folderGrid.padding(.top, 24)
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .fullScreenCover(item: $playRequest, onDismiss: { Task { await load() } }) { request in
            MSPlayerView(client: client, item: request.item, resume: request.resume)
        }
    }

    // MARK: - Header

    private var headerHeight: CGFloat { MSMetrics.edge > 40 ? 620 : 300 }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            MSArtwork(url: item.backdropURL ?? item.thumbURL ?? item.posterURL)
                .frame(maxWidth: .infinity)
                .frame(height: headerHeight)
                .overlay(
                    LinearGradient(colors: [.clear, Color.black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                )
            HStack(alignment: .bottom, spacing: 18) {
                if item.kind != .episode {
                    MSArtwork(url: item.posterURL)
                        .frame(width: MSMetrics.posterWidth, height: MSMetrics.posterWidth * 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(radius: 10)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let series = item.seriesTitle, item.kind == .episode || item.kind == .season {
                        Text(series)
                            .font(MSMetrics.edge > 40 ? Font.title3 : Font.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Text(item.title)
                        .font(MSMetrics.edge > 40 ? Font.system(size: 52, weight: .heavy) : Font.title.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let line = item.subtitleLine {
                        Text(line)
                            .font(MSMetrics.captionFont)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            .padding(MSMetrics.edge)
        }
        .frame(height: headerHeight)
        .clipped()
    }

    // MARK: - Actions

    private var playTarget: MSItem? {
        if item.isPlayable { return item }
        // A series or season plays its first unwatched (or partly watched) episode.
        return episodes.first { !$0.isWatched } ?? episodes.first
    }

    private var actions: some View {
        HStack(spacing: 14) {
            if let target = playTarget {
                let resumes = target.resumePosition > 30
                Button {
                    playRequest = MSPlayRequest(account: account, item: target, resume: resumes)
                } label: {
                    Label(playLabel(target, resumes: resumes), systemImage: "play.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)

                if resumes {
                    Button {
                        playRequest = MSPlayRequest(account: account, item: target, resume: false)
                    } label: {
                        Label("From Start", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if item.kind != .folder {
                Button {
                    toggleWatched(item)
                } label: {
                    Label(item.isWatched ? "Watched" : "Mark Watched",
                          systemImage: item.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isUpdatingWatched)
            }
        }
    }

    private func playLabel(_ target: MSItem, resumes: Bool) -> String {
        let prefix = target.id == item.id ? "" : (target.episodeLabel.map { "\($0) " } ?? "")
        if resumes, let left = MSFormat.remaining(target) { return "Resume \(prefix)· \(left)" }
        return "Play \(prefix)".trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Seasons and episodes

    private var seasonPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(seasons) { season in
                    Button {
                        selectedSeasonId = season.id
                        Task { await loadEpisodes(for: season) }
                    } label: {
                        Text(season.title)
                            .padding(.horizontal, 6)
                            .fontWeight(season.id == selectedSeasonId ? .bold : .regular)
                    }
                    .buttonStyle(.bordered)
                    .tint(season.id == selectedSeasonId ? Color.accentColor : Color.gray)
                }
            }
            .padding(.horizontal, MSMetrics.edge)
            #if os(tvOS)
            .padding(.vertical, 20)
            #endif
        }
        #if os(tvOS)
        .scrollClipDisabled()
        .focusSection()
        #endif
    }

    private var episodeList: some View {
        LazyVStack(alignment: .leading, spacing: MSMetrics.edge > 40 ? 40 : 14) {
            ForEach(episodes) { episode in
                Button {
                    playRequest = MSPlayRequest(account: account, item: episode, resume: episode.resumePosition > 30)
                } label: {
                    episodeRow(episode)
                }
                .msCardButtonStyle()
                .contextMenu {
                    Button(episode.isWatched ? "Mark Unwatched" : "Mark Watched") { toggleWatched(episode) }
                    Button("Play from Start") {
                        playRequest = MSPlayRequest(account: account, item: episode, resume: false)
                    }
                }
            }
        }
        .padding(.horizontal, MSMetrics.edge)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func episodeRow(_ episode: MSItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            MSArtwork(url: episode.thumbURL, systemImage: "play.rectangle")
                .frame(width: MSMetrics.thumbWidth * 0.75, height: MSMetrics.thumbWidth * 0.75 * 9 / 16)
                .overlay(alignment: .topTrailing) { MSWatchedBadge(item: episode) }
                .overlay(alignment: .bottom) {
                    if let fraction = episode.progressFraction { MSProgressBar(fraction: fraction).padding(6) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text([episode.episodeLabel, episode.title].compactMap { $0 }.joined(separator: " · "))
                    .font(MSMetrics.titleFont)
                    .lineLimit(2)
                if let duration = episode.duration {
                    Text(MSFormat.remaining(episode) ?? MSFormat.runtime(duration))
                        .font(MSMetrics.captionFont)
                        .foregroundStyle(.secondary)
                }
                if let overview = episode.overview {
                    Text(overview)
                        .font(MSMetrics.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MSMetrics.edge > 40 ? 16 : 0)
        .contentShape(Rectangle())
    }

    private var folderGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MSMetrics.gridMin), spacing: MSMetrics.rowSpacing, alignment: .top)],
                  spacing: MSMetrics.edge > 40 ? 50 : 18) {
            ForEach(children) { child in
                NavigationLink(value: MSRoute.item(account, child)) {
                    MSPosterCard(item: child, width: MSMetrics.gridMin)
                }
                .msCardButtonStyle()
            }
        }
        .padding(.horizontal, MSMetrics.edge)
    }

    // MARK: - Loading

    private func load() async {
        do {
            let fresh = try await client.detail(id: item.id)
            item = fresh
            error = nil
        } catch {
            // Keep showing what the list already gave us.
            self.error = error.msMessage
        }
        switch item.kind {
        case .series:
            seasons = (try? await client.children(of: item)) ?? []
            let current = seasons.first { $0.id == selectedSeasonId }
                ?? seasons.first { !$0.isWatched && ($0.seasonNumber ?? 0) > 0 }
                ?? seasons.first
            if let current {
                selectedSeasonId = current.id
                await loadEpisodes(for: current)
            }
        case .season:
            episodes = (try? await client.children(of: item)) ?? []
        case .folder:
            children = (try? await client.children(of: item)) ?? []
        default:
            break
        }
    }

    private func loadEpisodes(for season: MSItem) async {
        var season = season
        if season.seriesId == nil { season.seriesId = item.id }
        let loaded = (try? await client.children(of: season)) ?? []
        if selectedSeasonId == season.id { episodes = loaded }
    }

    private func toggleWatched(_ target: MSItem) {
        isUpdatingWatched = true
        Task {
            defer { isUpdatingWatched = false }
            do {
                try await client.setWatched(!target.isWatched, item: target)
                await load()
            } catch {
                self.error = error.msMessage
            }
        }
    }
}
#endif
