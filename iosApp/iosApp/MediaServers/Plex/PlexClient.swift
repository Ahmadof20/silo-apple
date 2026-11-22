#if !os(macOS)
import Foundation

/// Plex Media Server client. Signing in goes through plex.tv (a PIN the
/// person approves on plex.tv/link or app.plex.tv), then one of the
/// account's servers is picked and its best connection saved.
struct PlexClient: MediaServerClient {
    let account: MediaServerAccount
    let token: String

    private var base: String { account.baseURL }

    // MARK: - Headers

    static func headers(token: String?) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "X-Plex-Product": MediaServerDevice.product,
            "X-Plex-Version": MediaServerDevice.version,
            "X-Plex-Client-Identifier": MediaServerDevice.id,
            "X-Plex-Platform": MediaServerDevice.platform,
            "X-Plex-Device": MediaServerDevice.name,
            "X-Plex-Device-Name": MediaServerDevice.name,
        ]
        if let token { headers["X-Plex-Token"] = token }
        return headers
    }

    private static func request(_ url: URL, token: String?, method: String = "GET", timeout: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        for (key, value) in headers(token: token) { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    // MARK: - PIN sign-in (plex.tv)

    struct Pin: Decodable {
        let id: Int
        let code: String
        let authToken: String?
    }

    /// `strong` PINs are long and only work with the app.plex.tv web page;
    /// short ones can be typed on plex.tv/link, which suits Apple TV.
    static func createPin(strong: Bool) async throws -> Pin {
        let url = try MSHTTP.url("https://plex.tv", "/api/v2/pins", ["strong": strong ? "true" : "false"])
        let data = try await MSHTTP.send(request(url, token: nil, method: "POST"))
        return try MSHTTP.decode(Pin.self, from: data)
    }

    /// Returns the account token once the PIN is approved, nil while waiting.
    static func checkPin(_ pin: Pin) async throws -> String? {
        let url = try MSHTTP.url("https://plex.tv", "/api/v2/pins/\(pin.id)")
        do {
            let data = try await MSHTTP.send(request(url, token: nil))
            let checked = try MSHTTP.decode(Pin.self, from: data)
            if let token = checked.authToken, !token.isEmpty { return token }
            return nil
        } catch MediaServerError.http(404) {
            throw MediaServerError.pinExpired
        }
    }

    static func authURL(for pin: Pin) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "app.plex.tv"
        components.path = "/auth"
        let fragment = [
            "clientID=\(MediaServerDevice.id)",
            "code=\(pin.code)",
            "context%5Bdevice%5D%5Bproduct%5D=\(MediaServerDevice.product)",
        ].joined(separator: "&")
        components.percentEncodedFragment = "?" + fragment
        return components.url
    }

    struct PlexUser: Decodable {
        let uuid: String?
        let username: String?
        let title: String?
    }

    static func user(accountToken: String) async throws -> PlexUser {
        let url = try MSHTTP.url("https://plex.tv", "/api/v2/user")
        let data = try await MSHTTP.send(request(url, token: accountToken))
        return try MSHTTP.decode(PlexUser.self, from: data)
    }

    /// The servers this plex.tv account can open.
    static func servers(accountToken: String) async throws -> [MSPlexServerChoice] {
        struct Resource: Decodable {
            struct Connection: Decodable {
                let uri: String
                let local: Bool?
                let relay: Bool?
            }
            let name: String?
            let provides: String?
            let clientIdentifier: String
            let accessToken: String?
            let owned: Bool?
            let connections: [Connection]?
        }
        let url = try MSHTTP.url("https://plex.tv", "/api/v2/resources", ["includeHttps": "1", "includeRelay": "1"])
        let data = try await MSHTTP.send(request(url, token: accountToken))
        let resources = try MSHTTP.decode([Resource].self, from: data)
        return resources
            .filter { ($0.provides ?? "").split(separator: ",").contains("server") }
            .map { resource in
                MSPlexServerChoice(
                    name: resource.name ?? "Plex",
                    machineIdentifier: resource.clientIdentifier,
                    accessToken: resource.accessToken ?? accountToken,
                    connections: (resource.connections ?? []).map {
                        .init(uri: $0.uri, local: $0.local ?? false, relay: $0.relay ?? false)
                    },
                    owned: resource.owned ?? false
                )
            }
    }

    /// Tries every connection at once and keeps the best one that answers:
    /// local first, then direct remote, then Plex's relay.
    static func bestConnection(for server: MSPlexServerChoice) async throws -> String {
        func rank(_ c: MSPlexServerChoice.Connection) -> Int {
            if c.relay { return 2 }
            return c.local ? 0 : 1
        }
        let reachable: [(Int, String)] = await withTaskGroup(of: (Int, String)?.self) { group in
            for connection in server.connections {
                group.addTask {
                    guard let url = try? MSHTTP.url(connection.uri, "/identity") else { return nil }
                    let req = request(url, token: server.accessToken, timeout: 6)
                    guard (try? await MSHTTP.send(req)) != nil else { return nil }
                    return (rank(connection), connection.uri)
                }
            }
            var found: [(Int, String)] = []
            for await result in group { if let result { found.append(result) } }
            return found
        }
        guard let best = reachable.min(by: { $0.0 < $1.0 }) else {
            throw MediaServerError.unreachable("None of this server's addresses answered.")
        }
        var uri = best.1
        while uri.hasSuffix("/") { uri.removeLast() }
        return uri
    }

    static func makeAccount(server: MSPlexServerChoice, baseURL: String, user: PlexUser) -> MediaServerAccount {
        MediaServerAccount(
            id: "plex-\(server.machineIdentifier)-\(user.uuid ?? "user")",
            kind: .plex,
            serverName: server.name,
            baseURL: baseURL,
            userId: "",
            username: user.title ?? user.username ?? "",
            serverId: server.machineIdentifier,
            addedAt: Date()
        )
    }

    /// For servers not linked to plex.tv: an address plus an X-Plex-Token.
    static func connectManually(address: String, token: String) async throws -> MediaServerAccount {
        guard let url = MSAddress.normalize(address, defaultPort: 32400) else { throw MediaServerError.invalidAddress }
        var baseString = url.absoluteString
        while baseString.hasSuffix("/") { baseString.removeLast() }
        struct Root: Decodable {
            struct Container: Decodable { let friendlyName: String?; let machineIdentifier: String? }
            let MediaContainer: Container
        }
        let data = try await MSHTTP.send(request(try MSHTTP.url(baseString, "/"), token: token))
        let root = try MSHTTP.decode(Root.self, from: data)
        let machineId = root.MediaContainer.machineIdentifier ?? UUID().uuidString
        return MediaServerAccount(
            id: "plex-\(machineId)-manual",
            kind: .plex,
            serverName: root.MediaContainer.friendlyName ?? url.host ?? "Plex",
            baseURL: baseString,
            userId: "",
            username: "",
            serverId: machineId,
            addedAt: Date()
        )
    }

    // MARK: - Wire models

    struct Container<T: Decodable>: Decodable {
        let MediaContainer: T
    }

    struct MetadataList: Decodable {
        let totalSize: Int?
        let size: Int?
        let metadata: [Metadata]?
        enum CodingKeys: String, CodingKey { case totalSize, size, metadata = "Metadata" }
    }

    struct Metadata: Decodable {
        struct Tag: Decodable { let tag: String? }
        struct Media: Decodable {
            struct Stream: Decodable {
                let streamType: Int?
                let codec: String?
                let languageCode: String?
                let language: String?
                let displayTitle: String?
                let key: String?
                let DOVIPresent: Bool?
                let colorTrc: String?
            }
            struct Part: Decodable {
                let key: String?
                let container: String?
                let size: Int64?
                let streams: [Stream]?
                enum CodingKeys: String, CodingKey { case key, container, size, streams = "Stream" }
            }
            let container: String?
            let videoCodec: String?
            let audioCodec: String?
            let duration: Int?
            let bitrate: Int?
            let height: Int?
            let parts: [Part]?
            enum CodingKeys: String, CodingKey {
                case container, videoCodec, audioCodec, duration, bitrate, height, parts = "Part"
            }
        }
        let ratingKey: String
        let type: String?
        let title: String?
        let summary: String?
        let year: Int?
        let duration: Int?
        let viewOffset: Int?
        let viewCount: Int?
        let leafCount: Int?
        let viewedLeafCount: Int?
        let thumb: String?
        let art: String?
        let parentThumb: String?
        let grandparentThumb: String?
        let grandparentArt: String?
        let grandparentTitle: String?
        let grandparentRatingKey: String?
        let parentRatingKey: String?
        let parentIndex: Int?
        let index: Int?
        let contentRating: String?
        let audienceRating: Double?
        let rating: Double?
        let genres: [Tag]?
        let media: [Media]?
        let guids: [Tag2]?
        let addedAt: Int?
        struct Tag2: Decodable { let id: String? }

        enum CodingKeys: String, CodingKey {
            case ratingKey, type, title, summary, year, duration, viewOffset, viewCount, leafCount, viewedLeafCount
            case thumb, art, parentThumb, grandparentThumb, grandparentArt, grandparentTitle, grandparentRatingKey
            case parentRatingKey, parentIndex, index, contentRating, audienceRating, rating
            case genres = "Genre", media = "Media", guids = "Guid", addedAt
        }
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:], as type: T.Type) async throws -> T {
        let url = try MSHTTP.url(base, path, query)
        let data = try await MSHTTP.send(Self.request(url, token: token))
        return try MSHTTP.decode(type, from: data)
    }

    private func call(_ path: String, _ query: [String: String?] = [:], method: String = "GET") async throws {
        let url = try MSHTTP.url(base, path, query)
        _ = try await MSHTTP.send(Self.request(url, token: token, method: method))
    }

    private func list(_ path: String, _ query: [String: String?] = [:]) async throws -> MetadataList {
        var query = query
        query["includeGuids"] = "1"
        return try await get(path, query, as: Container<MetadataList>.self).MediaContainer
    }

    /// Plex lists external ids as "tmdb://603" or "imdb://tt0133093".
    static func guid(_ scheme: String, in guids: [Metadata.Tag2]?) -> String? {
        let prefix = scheme + "://"
        for id in (guids ?? []).compactMap({ $0.id }) where id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return nil
    }

    // MARK: - Mapping

    private func image(_ path: String?, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return try? MSHTTP.url(base, "/photo/:/transcode", [
            "url": path, "width": String(width), "height": String(height),
            "minSize": "1", "upscale": "1", "X-Plex-Token": token,
        ])
    }

    private func toItem(_ m: Metadata) -> MSItem {
        let kind: MSItem.Kind
        switch m.type {
        case "movie": kind = .movie
        case "show": kind = .series
        case "season": kind = .season
        case "episode": kind = .episode
        case "clip", "video": kind = .video
        case "collection", "folder": kind = .folder
        default: kind = .other
        }
        let poster: URL?
        switch kind {
        case .episode: poster = image(m.grandparentThumb ?? m.parentThumb ?? m.thumb, width: 400, height: 600)
        case .season: poster = image(m.thumb ?? m.parentThumb, width: 400, height: 600)
        default: poster = image(m.thumb, width: 400, height: 600)
        }
        let backdrop = image(m.art ?? m.grandparentArt, width: 1920, height: 1080)
        let thumb = (kind == .episode || kind == .video) ? image(m.thumb, width: 800, height: 450) : backdrop

        let leafs = m.leafCount.map { $0 - (m.viewedLeafCount ?? 0) }
        let watched: Bool
        if let leafCount = m.leafCount, leafCount > 0 {
            watched = (m.viewedLeafCount ?? 0) >= leafCount
        } else {
            watched = (m.viewCount ?? 0) > 0
        }
        let durationMs = m.duration ?? m.media?.first?.duration
        return MSItem(
            id: m.ratingKey,
            kind: kind,
            title: m.title ?? "",
            overview: m.summary,
            year: m.year,
            duration: durationMs.map { Double($0) / 1000 },
            resumePosition: Double(m.viewOffset ?? 0) / 1000,
            isWatched: watched,
            unwatchedCount: leafs,
            posterURL: poster,
            backdropURL: backdrop ?? thumb,
            thumbURL: thumb ?? backdrop,
            seriesId: kind == .season ? m.parentRatingKey : m.grandparentRatingKey,
            seriesTitle: m.grandparentTitle,
            seasonId: kind == .episode ? m.parentRatingKey : nil,
            seasonNumber: kind == .season ? m.index : m.parentIndex,
            episodeNumber: kind == .episode ? m.index : nil,
            genres: (m.genres ?? []).compactMap(\.tag),
            officialRating: m.contentRating,
            communityRating: m.audienceRating ?? m.rating,
            tmdbId: Self.guid("tmdb", in: m.guids),
            imdbId: Self.guid("imdb", in: m.guids)
        )
    }

    // MARK: - Browse

    func libraries() async throws -> [MSLibrary] {
        struct Sections: Decodable {
            struct Directory: Decodable { let key: String; let title: String?; let type: String?; let thumb: String? }
            let directories: [Directory]?
            enum CodingKeys: String, CodingKey { case directories = "Directory" }
        }
        let sections = try await get("/library/sections", as: Container<Sections>.self).MediaContainer
        return (sections.directories ?? []).compactMap { dir in
            let kind: MSLibrary.Kind
            switch dir.type {
            case "movie": kind = .movies
            case "show": kind = .shows
            default: return nil
            }
            return MSLibrary(id: dir.key, title: dir.title ?? "", kind: kind, imageURL: nil)
        }
    }

    func items(in library: MSLibrary, start: Int, limit: Int) async throws -> MSPage {
        let result = try await list("/library/sections/\(library.id)/all", [
            "X-Plex-Container-Start": String(start),
            "X-Plex-Container-Size": String(limit),
            "sort": "titleSort",
        ])
        let items = (result.metadata ?? []).map(toItem)
        return MSPage(items: items, total: result.totalSize ?? (start + items.count))
    }

    func children(of item: MSItem) async throws -> [MSItem] {
        let result = try await list("/library/metadata/\(item.id)/children")
        return (result.metadata ?? []).map(toItem)
    }

    func detail(id: String) async throws -> MSItem {
        let result = try await list("/library/metadata/\(id)")
        guard let first = result.metadata?.first else { throw MediaServerError.decoding }
        return toItem(first)
    }

    func continueWatching() async throws -> [MSItem] {
        do {
            let result = try await list("/hubs/continueWatching/items", ["X-Plex-Container-Size": "24"])
            return (result.metadata ?? []).map(toItem)
        } catch {
            // Older servers have only On Deck.
            let result = try await list("/library/onDeck")
            return (result.metadata ?? []).map(toItem)
        }
    }

    /// Plex's Continue Watching already folds in the next episodes.
    func nextUp() async throws -> [MSItem] { [] }

    func recentlyAdded(in library: MSLibrary) async throws -> [MSItem] {
        let result = try await list("/library/sections/\(library.id)/recentlyAdded", [
            "X-Plex-Container-Start": "0", "X-Plex-Container-Size": "20",
        ])
        return (result.metadata ?? []).map(toItem)
    }

    func search(_ query: String) async throws -> [MSItem] {
        struct Hubs: Decodable {
            struct Hub: Decodable {
                let type: String?
                let metadata: [Metadata]?
                enum CodingKeys: String, CodingKey { case type, metadata = "Metadata" }
            }
            let hubs: [Hub]?
            enum CodingKeys: String, CodingKey { case hubs = "Hub" }
        }
        let hubs = try await get("/hubs/search", ["query": query, "limit": "30", "includeGuids": "1"],
                                 as: Container<Hubs>.self).MediaContainer
        return (hubs.hubs ?? [])
            .filter { ["movie", "show", "episode"].contains($0.type ?? "") }
            .flatMap { $0.metadata ?? [] }
            .map(toItem)
    }

    // MARK: - Playback

    func playbackSource(for item: MSItem, resume: Bool) async throws -> MSPlaybackSource {
        let result = try await list("/library/metadata/\(item.id)")
        guard let meta = result.metadata?.first, let media = meta.media?.first,
              let part = media.parts?.first, let partKey = part.key else {
            throw MediaServerError.notPlayable
        }
        let session = UUID().uuidString
        let direct = MSDirectPlay.canDirectPlay(
            container: part.container ?? media.container,
            videoCodec: media.videoCodec,
            audioCodec: media.audioCodec
        )
        let url: URL
        if direct {
            url = try MSHTTP.url(base, partKey, ["X-Plex-Token": token])
        } else {
            url = try MSHTTP.url(base, "/video/:/transcode/universal/start.m3u8", [
                "path": "/library/metadata/\(item.id)",
                "mediaIndex": "0",
                "partIndex": "0",
                "protocol": "hls",
                "fastSeek": "1",
                "directPlay": "0",
                "directStream": "1",
                "directStreamAudio": "1",
                "videoQuality": "100",
                "maxVideoBitrate": "20000",
                "videoResolution": "1920x1080",
                "subtitles": "auto",
                "offset": "0",
                "session": session,
                "X-Plex-Session-Identifier": session,
                "X-Plex-Client-Identifier": MediaServerDevice.id,
                "X-Plex-Product": MediaServerDevice.product,
                "X-Plex-Platform": MediaServerDevice.platform,
                "X-Plex-Device": MediaServerDevice.name,
                "X-Plex-Token": token,
            ])
        }
        let full = toItem(meta)
        return MSPlaybackSource(
            url: url,
            startPosition: resume ? full.resumePosition : 0,
            playSessionId: session,
            mediaSourceId: nil,
            isTranscoding: !direct,
            duration: full.duration
        )
    }

    func report(_ state: MSPlaybackState, item: MSItem, source: MSPlaybackSource, position: Double, isPaused: Bool) async {
        let plexState: String
        switch state {
        case .stopped: plexState = "stopped"
        default: plexState = isPaused ? "paused" : "playing"
        }
        let durationMs = source.duration.map { String(Int($0 * 1000)) }
        try? await call("/:/timeline", [
            "ratingKey": item.id,
            "key": "/library/metadata/\(item.id)",
            "state": plexState,
            "time": String(Int(max(position, 0) * 1000)),
            "duration": durationMs,
            "X-Plex-Session-Identifier": source.playSessionId,
        ])
        if state == .stopped, source.isTranscoding {
            try? await call("/video/:/transcode/universal/stop", ["session": source.playSessionId])
        }
    }

    func setWatched(_ watched: Bool, item: MSItem) async throws {
        try await call(watched ? "/:/scrobble" : "/:/unscrobble", [
            "identifier": "com.plexapp.plugins.library",
            "key": item.id,
        ])
    }

    // MARK: - Silo engine sources

    private func fileMetadata(_ id: String) async throws -> Metadata {
        guard let meta = try await list("/library/metadata/\(id)").metadata?.first else {
            throw MediaServerError.notPlayable
        }
        return meta
    }

    private static func info(_ meta: Metadata) -> MSMediaInfo? {
        guard let media = meta.media?.first else { return nil }
        let part = media.parts?.first
        let streams = part?.streams ?? []
        let video = streams.first { $0.streamType == 1 }
        var range = "SDR"
        if video?.DOVIPresent == true {
            range = "DV"
        } else if let trc = video?.colorTrc?.lowercased() {
            if trc.contains("2084") { range = "HDR10" } else if trc.contains("hlg") || trc.contains("b67") { range = "HLG" }
        }
        let durationMs = media.duration ?? meta.duration
        return MSMediaInfo(
            resolution: MSMediaInfo.resolution(height: media.height),
            videoCodec: media.videoCodec,
            audioCodec: media.audioCodec,
            dynamicRange: range,
            container: part?.container ?? media.container,
            bitrate: media.bitrate.map { $0 * 1000 },
            size: part?.size,
            duration: durationMs.map { Double($0) / 1000 },
            addedAt: meta.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            audioLanguages: streams.filter { $0.streamType == 2 }.compactMap { $0.languageCode ?? $0.language },
            subtitleLanguages: streams.filter { $0.streamType == 3 }.compactMap { $0.languageCode ?? $0.language }
        )
    }

    func mediaInfo(for item: MSItem) async throws -> MSMediaInfo? {
        Self.info(try await fileMetadata(item.id))
    }

    func directStream(for item: MSItem) async throws -> MSDirectStream {
        let meta = try await fileMetadata(item.id)
        guard let part = meta.media?.first?.parts?.first, let partKey = part.key else {
            throw MediaServerError.notPlayable
        }
        let url = try MSHTTP.url(base, partKey, ["X-Plex-Token": token])
        // Plex serves sidecar subtitle files by key; embedded tracks are read
        // from the file by the engine itself.
        let subtitles: [MSSubtitleRef] = (part.streams ?? []).compactMap { stream in
            guard stream.streamType == 3, let key = stream.key,
                  let subURL = try? MSHTTP.url(base, key, ["X-Plex-Token": token]) else { return nil }
            return MSSubtitleRef(
                title: stream.displayTitle ?? stream.language ?? "Subtitle",
                language: stream.languageCode,
                url: subURL,
                isEmbedded: false
            )
        }
        return MSDirectStream(url: url, subtitles: subtitles, info: Self.info(meta))
    }

    func saveResume(_ item: MSItem, position: Double) async throws {
        try await call("/:/progress", [
            "identifier": "com.plexapp.plugins.library",
            "key": item.id,
            "time": String(Int(max(0, position) * 1000)),
            "state": "stopped",
        ])
    }
}
#endif
