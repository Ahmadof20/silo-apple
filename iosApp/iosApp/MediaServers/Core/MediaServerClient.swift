#if !os(macOS)
import Foundation

/// What every screen in the Emby/Plex section asks of a server. `EmbyClient`
/// and `PlexClient` map their APIs into the shared `MSItem` shape.
protocol MediaServerClient {
    var account: MediaServerAccount { get }

    func libraries() async throws -> [MSLibrary]
    func items(in library: MSLibrary, start: Int, limit: Int) async throws -> MSPage
    /// Series → seasons, season → episodes, folder → its contents.
    func children(of item: MSItem) async throws -> [MSItem]
    func detail(id: String) async throws -> MSItem
    func continueWatching() async throws -> [MSItem]
    func nextUp() async throws -> [MSItem]
    func recentlyAdded(in library: MSLibrary) async throws -> [MSItem]
    func search(_ query: String) async throws -> [MSItem]

    func playbackSource(for item: MSItem, resume: Bool) async throws -> MSPlaybackSource
    func report(_ state: MSPlaybackState, item: MSItem, source: MSPlaybackSource, position: Double, isPaused: Bool) async
    func setWatched(_ watched: Bool, item: MSItem) async throws
    /// Saves a resume point without a playback session, for titles watched
    /// in the Silo player.
    func saveResume(_ item: MSItem, position: Double) async throws

    /// File facts for a source card: resolution, codecs, size, bitrate.
    func mediaInfo(for item: MSItem) async throws -> MSMediaInfo?
    /// The original file, for Silo's own player engine (which opens MKV,
    /// HEVC, Dolby Vision, and lossless audio without a server transcode).
    func directStream(for item: MSItem) async throws -> MSDirectStream
    /// The same movie or episode on this server, or nil.
    func findMatch(_ query: MSMatchQuery) async throws -> MSItem?
}

extension MediaServerClient {
    /// Title search, confirmed by TMDB or IMDb id when both sides know one.
    func findMatch(_ query: MSMatchQuery) async throws -> MSItem? {
        switch query.kind {
        case .movie:
            let found = try await search(query.title)
            return MSMatcher.best(found.filter { $0.kind == .movie || $0.kind == .video },
                                  title: query.title, year: query.year,
                                  tmdbId: query.tmdbId, imdbId: query.imdbId)
        case .episode:
            guard let seriesTitle = query.seriesTitle, let season = query.seasonNumber,
                  let episode = query.episodeNumber else { return nil }
            let found = try await search(seriesTitle)
            guard let series = MSMatcher.best(found.filter { $0.kind == .series },
                                              title: seriesTitle, year: query.seriesYear,
                                              tmdbId: query.seriesTmdbId, imdbId: nil) else { return nil }
            return try await self.episode(in: series, season: season, episode: episode)
        }
    }

    /// One episode of a series by its season and episode numbers.
    func episode(in series: MSItem, season: Int, episode: Int) async throws -> MSItem? {
        let seasons = try await children(of: series)
        guard let match = seasons.first(where: { $0.seasonNumber == season }) else { return nil }
        let episodes = try await children(of: match)
        return episodes.first { $0.episodeNumber == episode }
    }
}

/// Compares titles across servers, which spell them differently: IPTV
/// lists add language prefixes and quality tags ("EN - Dune 4K (2021)").
enum MSMatcher {
    static func best(_ candidates: [MSItem], title: String, year: Int?, tmdbId: String?, imdbId: String?) -> MSItem? {
        // An id both sides know decides on its own.
        if let tmdbId, let hit = candidates.first(where: { $0.tmdbId == tmdbId }) { return hit }
        if let imdbId, let hit = candidates.first(where: { $0.imdbId?.lowercased() == imdbId.lowercased() }) { return hit }
        let wanted = normalize(title)
        guard !wanted.isEmpty else { return nil }
        let named = candidates.filter { candidate in
            // A candidate whose id disagrees is another title of the same name.
            if let tmdbId, let other = candidate.tmdbId, other != tmdbId { return false }
            return normalize(candidate.title) == wanted && yearsAgree(year, candidate.year ?? yearIn(candidate.title))
        }
        if named.count == 1 { return named[0] }
        // Several of one name: the one whose year matches exactly.
        if let year { return named.first { ($0.year ?? yearIn($0.title)) == year } }
        return nil
    }

    static func yearsAgree(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= 1
    }

    /// A four-digit year written in a title, "Dune (2021)" → 2021.
    static func yearIn(_ title: String) -> Int? {
        let pattern = #"[\(\[ ]((19|20)\d{2})[\)\] ]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else { return nil }
        return Int(title[range])
    }

    private static let noiseWords: Set<String> = [
        "4k", "uhd", "fhd", "hd", "sd", "hdr", "hdr10", "dv", "dolby", "vision", "2160p", "1080p", "720p",
        "480p", "multi", "sub", "subs", "dual", "audio", "remux", "bluray", "webdl", "web", "x264", "x265",
        "hevc", "h264", "h265", "atmos", "imax", "vip", "new", "multisub",
    ]

    /// Lowercase letters and digits only, without IPTV prefixes, brackets,
    /// years, and quality tags. Arabic and other scripts are kept.
    static func normalize(_ title: String) -> String {
        var text = title
        // "EN - ", "AR| ", "|NF| ", "[EN] " at the start.
        if let regex = try? NSRegularExpression(pattern: #"^\s*[\[\|(]?[A-Z]{2,3}[\]\|)]?\s*[-:|]\s*"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: #"[\[(][^\])]*[\])]"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !noiseWords.contains($0) }
            .filter { word in !(word.count == 4 && Int(word).map { (1900...2099).contains($0) } == true) }
        return words.joined()
    }
}

/// Small shared HTTP layer for the Emby and Plex clients.
enum MSHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest, session: URLSession = MSHTTP.session) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw MediaServerError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MediaServerError.decoding }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw MediaServerError.unauthorized
        default: throw MediaServerError.http(http.statusCode)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            #if DEBUG
            print("[MediaServers] decode \(T.self) failed: \(error)")
            #endif
            throw MediaServerError.decoding
        }
    }

    /// Joins a base URL and a path ("/Users/x/Items") and adds query items.
    static func url(_ base: String, _ path: String, _ query: [String: String?] = [:]) throws -> URL {
        // Plex part keys carry file names that may hold spaces or non-Latin
        // letters; existing %-escapes are kept as they are.
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert("%")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        guard var components = URLComponents(string: base + encodedPath) else { throw MediaServerError.invalidAddress }
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty {
            components.queryItems = (components.queryItems ?? []) + items.sorted { $0.name < $1.name }
        }
        // `+` must survive in values such as search text and tokens.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw MediaServerError.invalidAddress }
        return url
    }
}

/// Containers AVPlayer opens directly. Anything else goes through the
/// server's HLS stream (a remux when the codecs fit, a transcode otherwise).
enum MSDirectPlay {
    static let containers: Set<String> = ["mp4", "m4v", "mov"]
    static let videoCodecs: Set<String> = ["h264", "hevc", "h265", "avc"]
    static let audioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]

    static func canDirectPlay(container: String?, videoCodec: String?, audioCodec: String?) -> Bool {
        guard let container else { return false }
        let containerOK = container.lowercased().split(separator: ",").contains { containers.contains(String($0)) }
        let videoOK = videoCodec.map { videoCodecs.contains($0.lowercased()) } ?? true
        let audioOK = audioCodec.map { audioCodecs.contains($0.lowercased()) } ?? true
        return containerOK && videoOK && audioOK
    }
}
#endif
