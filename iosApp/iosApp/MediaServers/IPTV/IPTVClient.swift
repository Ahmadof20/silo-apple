#if !os(macOS)
import Foundation

/// An IPTV subscription that speaks the Xtream Codes API
/// (`player_api.php`). Movies and series become two libraries; live
/// channels are not shown. Xtream has no watch state, so resume points and
/// watched marks are kept on this device.
struct IPTVClient: MediaServerClient {
    let account: MediaServerAccount
    let password: String

    private var base: String { account.baseURL }
    private var username: String { account.username }

    static let moviesLibraryId = "vod"
    static let seriesLibraryId = "series"

    // MARK: - Sign in

    static func signIn(address: String, username: String, password: String) async throws -> (MediaServerAccount, String) {
        guard let url = MSAddress.normalize(address, defaultPort: nil) else { throw MediaServerError.invalidAddress }
        // People paste the whole "get.php?username=…" link; keep scheme, host and port.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        guard let base = components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw MediaServerError.invalidAddress
        }
        struct Login: Decodable {
            struct User: Decodable {
                let auth: Flex?
                let status: String?
                let username: String?
            }
            struct Server: Decodable { let url: String? }
            let user_info: User?
            let server_info: Server?
        }
        let request = URLRequest(url: try MSHTTP.url(base, "/player_api.php", ["username": username, "password": password]))
        let login = try MSHTTP.decode(Login.self, from: try await MSHTTP.send(request))
        guard login.user_info?.auth?.int == 1 else { throw MediaServerError.unauthorized }
        let host = URL(string: base)?.host ?? base
        let account = MediaServerAccount(
            id: "iptv-\(host)-\(username)",
            kind: .iptv,
            serverName: login.server_info?.url.flatMap { $0.isEmpty ? nil : $0 } ?? host,
            baseURL: base,
            userId: username,
            username: username,
            serverId: host,
            addedAt: Date()
        )
        return (account, password)
    }

    // MARK: - Wire types

    /// Xtream panels send the same field as a number or a string.
    struct Flex: Decodable, Hashable {
        let string: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                string = value
            } else if let value = try? container.decode(Int.self) {
                string = String(value)
            } else if let value = try? container.decode(Double.self) {
                string = String(value)
            } else if let value = try? container.decode(Bool.self) {
                string = value ? "1" : "0"
            } else {
                string = nil
            }
        }
        var int: Int? { string.flatMap { Int($0) ?? Double($0).map { Int($0) } } }
        var double: Double? { string.flatMap(Double.init) }
        var nonEmpty: String? { string.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 } }
    }

    struct Movie: Codable, Hashable {
        let id: String
        let name: String
        let icon: String?
        let ext: String?
        let added: Int?
        let rating: Double?
        let tmdb: String?
        let year: Int?
    }

    struct Series: Codable, Hashable {
        let id: String
        let name: String
        let cover: String?
        let plot: String?
        let year: Int?
        let rating: Double?
        let tmdb: String?
        let backdrop: String?
        let modified: Int?
    }

    private struct MovieWire: Decodable {
        let stream_id: Flex?
        let name: Flex?
        let stream_icon: String?
        let container_extension: String?
        let added: Flex?
        let rating: Flex?
        let tmdb: Flex?
        let tmdb_id: Flex?
        let year: Flex?
    }

    private struct SeriesWire: Decodable {
        let series_id: Flex?
        let name: Flex?
        let cover: String?
        let plot: String?
        let releaseDate: String?
        let release_date: String?
        let rating: Flex?
        let tmdb: Flex?
        let tmdb_id: Flex?
        let backdrop_path: BackdropList?
        let last_modified: Flex?
        let year: Flex?
    }

    /// `backdrop_path` is a list on most panels and a string on a few.
    struct BackdropList: Decodable {
        let first: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([String].self) {
                first = list.first
            } else {
                first = try? container.decode(String.self)
            }
        }
    }

    struct SeriesInfo: Decodable {
        struct Info: Decodable {
            let name: String?
            let cover: String?
            let plot: String?
            let genre: String?
            let releaseDate: String?
            let rating: Flex?
            let tmdb: Flex?
            let tmdb_id: Flex?
            let backdrop_path: BackdropList?
        }
        struct Episode: Decodable {
            struct EpisodeInfo: Decodable {
                let duration_secs: Flex?
                let plot: String?
                let movie_image: String?
                let bitrate: Flex?
                let video: StreamInfo?
                let audio: StreamInfo?
            }
            let id: Flex?
            let episode_num: Flex?
            let title: String?
            let container_extension: String?
            let season: Flex?
            let added: Flex?
            let info: EpisodeInfo?
        }
        let info: Info?
        let episodes: [String: [Episode]]

        enum CodingKeys: String, CodingKey { case info, episodes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            info = try? container.decode(Info.self, forKey: .info)
            if let map = try? container.decode([String: [Episode]].self, forKey: .episodes) {
                episodes = map
            } else if let list = try? container.decode([[Episode]].self, forKey: .episodes) {
                // A few panels send seasons as a plain list.
                var map: [String: [Episode]] = [:]
                for group in list {
                    let season = group.first?.season?.string ?? String(map.count + 1)
                    map[season] = group
                }
                episodes = map
            } else {
                episodes = [:]
            }
        }
    }

    /// `video` / `audio` in vod and episode info: ffprobe output.
    struct StreamInfo: Decodable {
        let codec_name: String?
        let height: Flex?
        let color_transfer: String?
    }

    struct VodInfo: Decodable {
        struct Info: Decodable {
            let plot: String?
            let description: String?
            let genre: String?
            let releasedate: String?
            let duration_secs: Flex?
            let backdrop_path: BackdropList?
            let movie_image: String?
            let tmdb_id: Flex?
            let rating: Flex?
            let bitrate: Flex?
            let video: StreamInfo?
            let audio: StreamInfo?
        }
        struct MovieData: Decodable {
            let stream_id: Flex?
            let container_extension: String?
            let added: Flex?
            let name: String?
        }
        let info: Info?
        let movie_data: MovieData?

        enum CodingKeys: String, CodingKey { case info, movie_data }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // An unknown id answers `"info": []`.
            info = try? container.decode(Info.self, forKey: .info)
            movie_data = try? container.decode(MovieData.self, forKey: .movie_data)
        }
    }

    // MARK: - Requests

    private func api(_ action: String, _ extra: [String: String?] = [:]) async throws -> Data {
        var query: [String: String?] = ["username": username, "password": password, "action": action]
        for (key, value) in extra { query[key] = value }
        var request = URLRequest(url: try MSHTTP.url(base, "/player_api.php", query))
        request.timeoutInterval = 60
        return try await MSHTTP.send(request, session: IPTVCatalog.session)
    }

    func fetchMovies() async throws -> [Movie] {
        let wires = try MSHTTP.decode([MovieWire].self, from: try await api("get_vod_streams"))
        return wires.compactMap { wire in
            guard let id = wire.stream_id?.string, let name = wire.name?.string else { return nil }
            return Movie(
                id: id,
                name: name,
                icon: wire.stream_icon.flatMap { $0.isEmpty ? nil : $0 },
                ext: wire.container_extension,
                added: wire.added?.int,
                rating: wire.rating?.double,
                tmdb: wire.tmdb?.nonEmpty ?? wire.tmdb_id?.nonEmpty,
                year: wire.year?.int ?? MSMatcher.yearIn(name)
            )
        }
    }

    func fetchSeries() async throws -> [Series] {
        let wires = try MSHTTP.decode([SeriesWire].self, from: try await api("get_series"))
        return wires.compactMap { wire in
            guard let id = wire.series_id?.string, let name = wire.name?.string else { return nil }
            let date = wire.releaseDate ?? wire.release_date
            return Series(
                id: id,
                name: name,
                cover: wire.cover.flatMap { $0.isEmpty ? nil : $0 },
                plot: wire.plot,
                year: wire.year?.int ?? date.flatMap { Int($0.prefix(4)) } ?? MSMatcher.yearIn(name),
                rating: wire.rating?.double,
                tmdb: wire.tmdb?.nonEmpty ?? wire.tmdb_id?.nonEmpty,
                backdrop: wire.backdrop_path?.first,
                modified: wire.last_modified?.int
            )
        }
    }

    private func seriesInfo(_ seriesId: String) async throws -> SeriesInfo {
        if let cached = await IPTVCatalog.shared.seriesInfo(account.id, seriesId) { return cached }
        let info = try MSHTTP.decode(SeriesInfo.self, from: try await api("get_series_info", ["series_id": seriesId]))
        await IPTVCatalog.shared.store(info, account: account.id, seriesId: seriesId)
        return info
    }

    private func catalog() async throws -> IPTVCatalog.Entry {
        try await IPTVCatalog.shared.entry(for: self)
    }

    // MARK: - Ids

    /// movie "m|id|ext", series "s|id", season "z|seriesId|number",
    /// episode "e|id|ext|seriesId|season".
    private enum ItemId {
        case movie(id: String, ext: String)
        case series(id: String)
        case season(seriesId: String, number: Int)
        case episode(id: String, ext: String, seriesId: String, season: Int)

        init?(_ raw: String) {
            let parts = raw.components(separatedBy: "|")
            switch parts.first {
            case "m" where parts.count >= 3: self = .movie(id: parts[1], ext: parts[2])
            case "s" where parts.count >= 2: self = .series(id: parts[1])
            case "z" where parts.count >= 3: self = .season(seriesId: parts[1], number: Int(parts[2]) ?? 1)
            case "e" where parts.count >= 5:
                self = .episode(id: parts[1], ext: parts[2], seriesId: parts[3], season: Int(parts[4]) ?? 1)
            default: return nil
            }
        }

        var raw: String {
            switch self {
            case .movie(let id, let ext): "m|\(id)|\(ext)"
            case .series(let id): "s|\(id)"
            case .season(let seriesId, let number): "z|\(seriesId)|\(number)"
            case .episode(let id, let ext, let seriesId, let season): "e|\(id)|\(ext)|\(seriesId)|\(season)"
            }
        }
    }

    // MARK: - Mapping

    /// "EN - Dune (2021)" → "Dune (2021)" for display.
    static func displayTitle(_ name: String) -> String {
        name.replacingOccurrences(of: #"^\s*[\[\|(]?[A-Z]{2,3}[\]\|)]?\s*[-:|]\s*"#, with: "", options: .regularExpression)
    }

    private func toItem(_ movie: Movie) -> MSItem {
        let id = ItemId.movie(id: movie.id, ext: movie.ext ?? "mp4").raw
        let state = IPTVWatchStore.state(account.id, id)
        return MSItem(
            id: id,
            kind: .movie,
            title: Self.displayTitle(movie.name),
            year: movie.year,
            resumePosition: state.position,
            isWatched: state.watched,
            posterURL: movie.icon.flatMap(URL.init(string:)),
            communityRating: movie.rating,
            tmdbId: movie.tmdb
        )
    }

    private func toItem(_ series: Series) -> MSItem {
        MSItem(
            id: ItemId.series(id: series.id).raw,
            kind: .series,
            title: Self.displayTitle(series.name),
            overview: series.plot,
            year: series.year,
            posterURL: series.cover.flatMap(URL.init(string:)),
            backdropURL: series.backdrop.flatMap(URL.init(string:)),
            communityRating: series.rating,
            tmdbId: series.tmdb
        )
    }

    private func episodeItem(_ episode: SeriesInfo.Episode, seriesId: String, info: SeriesInfo) -> MSItem? {
        guard let id = episode.id?.string else { return nil }
        let season = episode.season?.int ?? 1
        let itemId = ItemId.episode(id: id, ext: episode.container_extension ?? "mp4", seriesId: seriesId, season: season).raw
        let state = IPTVWatchStore.state(account.id, itemId)
        let still = episode.info?.movie_image.flatMap(URL.init(string:))
        return MSItem(
            id: itemId,
            kind: .episode,
            title: episode.title.map(Self.displayTitle) ?? "Episode \(episode.episode_num?.int ?? 0)",
            overview: episode.info?.plot,
            duration: episode.info?.duration_secs?.double,
            resumePosition: state.position,
            isWatched: state.watched,
            posterURL: info.info?.cover.flatMap(URL.init(string:)),
            backdropURL: info.info?.backdrop_path?.first.flatMap(URL.init(string:)) ?? still,
            thumbURL: still,
            seriesId: ItemId.series(id: seriesId).raw,
            seriesTitle: info.info?.name.map(Self.displayTitle),
            seasonId: ItemId.season(seriesId: seriesId, number: season).raw,
            seasonNumber: season,
            episodeNumber: episode.episode_num?.int
        )
    }

    // MARK: - Browse

    func libraries() async throws -> [MSLibrary] {
        [
            MSLibrary(id: Self.moviesLibraryId, title: "Movies", kind: .movies),
            MSLibrary(id: Self.seriesLibraryId, title: "Series", kind: .shows),
        ]
    }

    func items(in library: MSLibrary, start: Int, limit: Int) async throws -> MSPage {
        let entry = try await catalog()
        if library.id == Self.seriesLibraryId {
            let all = entry.series
            let slice = all.dropFirst(start).prefix(limit)
            return MSPage(items: slice.map(toItem), total: all.count)
        }
        let all = entry.movies
        let slice = all.dropFirst(start).prefix(limit)
        return MSPage(items: slice.map(toItem), total: all.count)
    }

    func children(of item: MSItem) async throws -> [MSItem] {
        switch ItemId(item.id) {
        case .series(let seriesId):
            let info = try await seriesInfo(seriesId)
            let numbers = info.episodes.keys.compactMap { Int($0) }.sorted()
            return numbers.map { number in
                MSItem(
                    id: ItemId.season(seriesId: seriesId, number: number).raw,
                    kind: .season,
                    title: "Season \(number)",
                    posterURL: info.info?.cover.flatMap(URL.init(string:)),
                    seriesId: item.id,
                    seriesTitle: info.info?.name.map(Self.displayTitle) ?? item.title,
                    seasonNumber: number
                )
            }
        case .season(let seriesId, let number):
            let info = try await seriesInfo(seriesId)
            let episodes = info.episodes[String(number)] ?? []
            return episodes
                .compactMap { episodeItem($0, seriesId: seriesId, info: info) }
                .sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
        default:
            return []
        }
    }

    func detail(id: String) async throws -> MSItem {
        switch ItemId(id) {
        case .movie(let streamId, _):
            let entry = try await catalog()
            guard let movie = entry.movies.first(where: { $0.id == streamId }) else { throw MediaServerError.notPlayable }
            var item = toItem(movie)
            if let vod = try? MSHTTP.decode(VodInfo.self, from: try await api("get_vod_info", ["vod_id": streamId])),
               let info = vod.info {
                item.overview = info.plot ?? info.description
                item.duration = info.duration_secs?.double
                item.backdropURL = info.backdrop_path?.first.flatMap(URL.init(string:))
                item.genres = (info.genre ?? "").components(separatedBy: CharacterSet(charactersIn: ",/"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if item.tmdbId == nil { item.tmdbId = info.tmdb_id?.nonEmpty }
            }
            return item
        case .series(let seriesId):
            let entry = try await catalog()
            let info = try await seriesInfo(seriesId)
            var item = entry.series.first(where: { $0.id == seriesId }).map(toItem)
                ?? MSItem(id: id, kind: .series, title: info.info?.name.map(Self.displayTitle) ?? "")
            item.overview = info.info?.plot ?? item.overview
            item.genres = (info.info?.genre ?? "").components(separatedBy: CharacterSet(charactersIn: ",/"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if item.backdropURL == nil { item.backdropURL = info.info?.backdrop_path?.first.flatMap(URL.init(string:)) }
            if item.tmdbId == nil { item.tmdbId = info.info?.tmdb?.nonEmpty ?? info.info?.tmdb_id?.nonEmpty }
            return item
        case .episode(let episodeId, _, let seriesId, let season):
            let info = try await seriesInfo(seriesId)
            guard let episode = info.episodes[String(season)]?.first(where: { $0.id?.string == episodeId }),
                  let item = episodeItem(episode, seriesId: seriesId, info: info) else {
                throw MediaServerError.notPlayable
            }
            return item
        case .season(let seriesId, let number):
            let info = try await seriesInfo(seriesId)
            return MSItem(id: id, kind: .season, title: "Season \(number)",
                          posterURL: info.info?.cover.flatMap(URL.init(string:)),
                          seriesId: ItemId.series(id: seriesId).raw, seasonNumber: number)
        case nil:
            throw MediaServerError.notPlayable
        }
    }

    func continueWatching() async throws -> [MSItem] { [] }
    func nextUp() async throws -> [MSItem] { [] }

    func recentlyAdded(in library: MSLibrary) async throws -> [MSItem] {
        let entry = try await catalog()
        if library.id == Self.seriesLibraryId {
            return entry.series.sorted { ($0.modified ?? 0) > ($1.modified ?? 0) }.prefix(20).map(toItem)
        }
        return entry.movies.prefix(20).map(toItem)
    }

    func search(_ query: String) async throws -> [MSItem] {
        let wanted = MSMatcher.normalize(query)
        guard !wanted.isEmpty else { return [] }
        let entry = try await catalog()
        let movies = entry.movies.lazy.filter { MSMatcher.normalize($0.name).contains(wanted) }.prefix(40).map(toItem)
        let series = entry.series.lazy.filter { MSMatcher.normalize($0.name).contains(wanted) }.prefix(40).map(toItem)
        return Array(movies) + Array(series)
    }

    // MARK: - Matching

    func findMatch(_ query: MSMatchQuery) async throws -> MSItem? {
        let entry = try await catalog()
        switch query.kind {
        case .movie:
            return MSMatcher.best(entry.movieCandidates(for: query.title, tmdb: query.tmdbId).map(toItem),
                                  title: query.title, year: query.year, tmdbId: query.tmdbId, imdbId: nil)
        case .episode:
            guard let seriesTitle = query.seriesTitle, let season = query.seasonNumber,
                  let episode = query.episodeNumber else { return nil }
            guard let series = MSMatcher.best(entry.seriesCandidates(for: seriesTitle, tmdb: query.seriesTmdbId).map(toItem),
                                              title: seriesTitle, year: query.seriesYear,
                                              tmdbId: query.seriesTmdbId, imdbId: nil) else { return nil }
            return try await self.episode(in: series, season: season, episode: episode)
        }
    }

    // MARK: - Playback

    private func streamURL(for item: MSItem) throws -> URL {
        switch ItemId(item.id) {
        case .movie(let id, let ext):
            return try MSHTTP.url(base, "/movie/\(username)/\(password)/\(id).\(ext)")
        case .episode(let id, let ext, _, _):
            return try MSHTTP.url(base, "/series/\(username)/\(password)/\(id).\(ext)")
        default:
            throw MediaServerError.notPlayable
        }
    }

    func playbackSource(for item: MSItem, resume: Bool) async throws -> MSPlaybackSource {
        MSPlaybackSource(
            url: try streamURL(for: item),
            startPosition: resume ? IPTVWatchStore.state(account.id, item.id).position : 0,
            playSessionId: UUID().uuidString,
            mediaSourceId: item.id,
            isTranscoding: false,
            duration: item.duration
        )
    }

    func report(_ state: MSPlaybackState, item: MSItem, source: MSPlaybackSource, position: Double, isPaused: Bool) async {
        guard state != .started else { return }
        IPTVWatchStore.save(account.id, item.id, position: position, duration: source.duration ?? item.duration)
    }

    func setWatched(_ watched: Bool, item: MSItem) async throws {
        IPTVWatchStore.setWatched(account.id, item.id, watched)
    }

    func saveResume(_ item: MSItem, position: Double) async throws {
        IPTVWatchStore.save(account.id, item.id, position: position, duration: item.duration)
    }

    func mediaInfo(for item: MSItem) async throws -> MSMediaInfo? {
        switch ItemId(item.id) {
        case .movie(let id, let ext):
            let vod = try MSHTTP.decode(VodInfo.self, from: try await api("get_vod_info", ["vod_id": id]))
            let added = try await catalog().movies.first { $0.id == id }?.added
            return Self.info(video: vod.info?.video, audio: vod.info?.audio, bitrateKbps: vod.info?.bitrate?.int,
                             duration: vod.info?.duration_secs?.double, container: ext, added: added)
        case .episode(let id, let ext, let seriesId, let season):
            let info = try await seriesInfo(seriesId)
            let episode = info.episodes[String(season)]?.first { $0.id?.string == id }
            return Self.info(video: episode?.info?.video, audio: episode?.info?.audio,
                             bitrateKbps: episode?.info?.bitrate?.int,
                             duration: episode?.info?.duration_secs?.double, container: ext,
                             added: episode?.added?.int)
        default:
            return nil
        }
    }

    private static func info(video: StreamInfo?, audio: StreamInfo?, bitrateKbps: Int?, duration: Double?,
                             container: String, added: Int?) -> MSMediaInfo {
        var range = "SDR"
        if let transfer = video?.color_transfer?.lowercased() {
            if transfer.contains("2084") { range = "HDR10" } else if transfer.contains("b67") { range = "HLG" }
        }
        return MSMediaInfo(
            resolution: MSMediaInfo.resolution(height: video?.height?.int),
            videoCodec: video?.codec_name,
            audioCodec: audio?.codec_name,
            dynamicRange: range,
            container: container,
            bitrate: bitrateKbps.flatMap { $0 > 0 ? $0 * 1000 : nil },
            duration: duration,
            addedAt: added.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    func directStream(for item: MSItem) async throws -> MSDirectStream {
        MSDirectStream(url: try streamURL(for: item), info: try? await mediaInfo(for: item))
    }
}

/// The movie and series lists of each IPTV subscription. They are large
/// (tens of thousands of entries), so they are fetched once, kept in
/// memory, and cached on disk for six hours.
actor IPTVCatalog {
    static let shared = IPTVCatalog()

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    struct Entry: Codable {
        /// Newest first.
        var movies: [IPTVClient.Movie]
        var series: [IPTVClient.Series]
        var loadedAt: Date

        func movieCandidates(for title: String, tmdb: String?) -> [IPTVClient.Movie] {
            if let tmdb {
                let byId = movies.filter { $0.tmdb == tmdb }
                if !byId.isEmpty { return byId }
            }
            let wanted = MSMatcher.normalize(title)
            guard !wanted.isEmpty else { return [] }
            return movies.filter { MSMatcher.normalize($0.name) == wanted }
        }

        func seriesCandidates(for title: String, tmdb: String?) -> [IPTVClient.Series] {
            if let tmdb {
                let byId = series.filter { $0.tmdb == tmdb }
                if !byId.isEmpty { return byId }
            }
            let wanted = MSMatcher.normalize(title)
            guard !wanted.isEmpty else { return [] }
            return series.filter { MSMatcher.normalize($0.name) == wanted }
        }
    }

    private static let lifetime: TimeInterval = 6 * 3600
    private var entries: [String: Entry] = [:]
    private var loads: [String: Task<Entry, Error>] = [:]
    private var seriesInfos: [String: IPTVClient.SeriesInfo] = [:]

    func entry(for client: IPTVClient) async throws -> Entry {
        let key = client.account.id
        if let entry = entries[key], Date().timeIntervalSince(entry.loadedAt) < Self.lifetime { return entry }
        if let disk = Self.readDisk(key), Date().timeIntervalSince(disk.loadedAt) < Self.lifetime {
            entries[key] = disk
            return disk
        }
        if let running = loads[key] { return try await running.value }
        let task = Task<Entry, Error> {
            async let movies = client.fetchMovies()
            async let series = client.fetchSeries()
            let entry = Entry(
                movies: try await movies.sorted { ($0.added ?? 0) > ($1.added ?? 0) },
                series: try await series.sorted { ($0.modified ?? 0) > ($1.modified ?? 0) },
                loadedAt: Date()
            )
            Self.writeDisk(entry, key: key)
            return entry
        }
        loads[key] = task
        defer { loads[key] = nil }
        do {
            let entry = try await task.value
            entries[key] = entry
            return entry
        } catch {
            // Offline or the panel is busy: an older copy beats nothing.
            if let stale = Self.readDisk(key) {
                entries[key] = stale
                return stale
            }
            throw error
        }
    }

    func seriesInfo(_ account: String, _ seriesId: String) -> IPTVClient.SeriesInfo? {
        seriesInfos[account + "|" + seriesId]
    }

    func store(_ info: IPTVClient.SeriesInfo, account: String, seriesId: String) {
        if seriesInfos.count > 200 { seriesInfos.removeAll() }
        seriesInfos[account + "|" + seriesId] = info
    }

    private static func fileURL(_ key: String) -> URL? {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("iptv-\(safe).json")
    }

    private static func readDisk(_ key: String) -> Entry? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private static func writeDisk(_ entry: Entry, key: String) {
        guard let url = fileURL(key), let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Resume points and watched marks for IPTV items, kept on this device.
enum IPTVWatchStore {
    private static let key = "mediaServers.iptvWatch.v1"

    struct State {
        var position: Double = 0
        var watched = false
    }

    private static var all: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func state(_ account: String, _ item: String) -> State {
        guard let values = all[account + "#" + item], values.count >= 2 else { return State() }
        return State(position: values[0], watched: values[1] > 0)
    }

    static func save(_ account: String, _ item: String, position: Double, duration: Double?) {
        guard position.isFinite, position >= 0 else { return }
        let finished = (duration ?? 0) > 0 && position / (duration ?? 1) >= 0.9
        var map = all
        map[account + "#" + item] = [finished ? 0 : position, finished ? 1 : 0]
        all = map
    }

    static func setWatched(_ account: String, _ item: String, _ watched: Bool) {
        var map = all
        map[account + "#" + item] = [0, watched ? 1 : 0]
        all = map
    }
}
#endif
