#if !os(macOS)
import Foundation

/// Emby REST client. Jellyfin kept the same endpoints and accepts the same
/// `X-Emby-Authorization` header, so this also signs in to Jellyfin servers.
struct EmbyClient: MediaServerClient {
    let account: MediaServerAccount
    let token: String

    private var base: String { account.baseURL }
    private var userId: String { account.userId }

    private static let listFields = "Overview,Genres,ProductionYear,OfficialRating,CommunityRating,PrimaryImageAspectRatio,ProviderIds"
    private static let ticksPerSecond = 10_000_000.0

    // MARK: - Sign in

    struct PublicInfo: Decodable {
        let ServerName: String?
        let Id: String?
        let Version: String?
    }

    /// Checks the address answers as Emby/Jellyfin, then signs in.
    static func signIn(address: String, username: String, password: String) async throws -> (MediaServerAccount, String) {
        guard let url = MSAddress.normalize(address, defaultPort: 8096) else { throw MediaServerError.invalidAddress }
        var baseString = url.absoluteString
        while baseString.hasSuffix("/") { baseString.removeLast() }

        let info = try await publicInfo(base: baseString)

        var request = URLRequest(url: try MSHTTP.url(baseString, "/Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password, "Password": password])

        struct AuthResult: Decodable {
            struct UserInfo: Decodable { let Id: String; let Name: String? }
            let AccessToken: String
            let User: UserInfo
            let ServerId: String?
        }
        let data = try await MSHTTP.send(request)
        let result = try MSHTTP.decode(AuthResult.self, from: data)

        let account = MediaServerAccount(
            id: "emby-\(result.ServerId ?? info.Id ?? UUID().uuidString)-\(result.User.Id)",
            kind: .emby,
            serverName: info.ServerName ?? url.host ?? "Emby",
            baseURL: baseString,
            userId: result.User.Id,
            username: result.User.Name ?? username,
            serverId: result.ServerId ?? info.Id ?? "",
            addedAt: Date()
        )
        return (account, result.AccessToken)
    }

    private static func publicInfo(base: String) async throws -> PublicInfo {
        var request = URLRequest(url: try MSHTTP.url(base, "/System/Info/Public"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await MSHTTP.send(request)
        return try MSHTTP.decode(PublicInfo.self, from: data)
    }

    static func authorizationHeader(token: String?) -> String {
        var parts = [
            "Client=\"\(MediaServerDevice.product)\"",
            "Device=\"\(MediaServerDevice.name)\"",
            "DeviceId=\"\(MediaServerDevice.id)\"",
            "Version=\"\(MediaServerDevice.version)\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:], as type: T.Type) async throws -> T {
        let data = try await MSHTTP.send(request(path, query))
        return try MSHTTP.decode(type, from: data)
    }

    private func post(_ path: String, _ query: [String: String?] = [:], body: [String: Any]? = nil, method: String = "POST") async throws {
        var req = try request(path, query)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        _ = try await MSHTTP.send(req)
    }

    private func request(_ path: String, _ query: [String: String?]) throws -> URLRequest {
        var req = URLRequest(url: try MSHTTP.url(base, path, query))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        req.setValue(Self.authorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        return req
    }

    // MARK: - Wire models

    struct ItemsResult: Decodable {
        let Items: [DTO]
        let TotalRecordCount: Int?
    }

    struct DTO: Decodable {
        struct UserState: Decodable {
            let PlaybackPositionTicks: Int64?
            let Played: Bool?
            let UnplayedItemCount: Int?
        }
        struct MediaSource: Decodable {
            let Id: String?
            let Container: String?
            let MediaStreams: [MediaStream]?
            let RunTimeTicks: Int64?
        }
        struct MediaStream: Decodable {
            let kind: String?
            let Codec: String?
            enum CodingKeys: String, CodingKey { case kind = "Type", Codec }
        }
        let Id: String
        let Name: String?
        let kind: String?
        let CollectionType: String?
        let IsFolder: Bool?
        let Overview: String?
        let ProductionYear: Int?
        let RunTimeTicks: Int64?
        let UserData: UserState?
        let ImageTags: [String: String]?
        let BackdropImageTags: [String]?
        let ParentBackdropItemId: String?
        let ParentBackdropImageTags: [String]?
        let ParentThumbItemId: String?
        let ParentThumbImageTag: String?
        let SeriesId: String?
        let SeriesName: String?
        let SeriesPrimaryImageTag: String?
        let SeasonId: String?
        let ParentIndexNumber: Int?
        let IndexNumber: Int?
        let Genres: [String]?
        let OfficialRating: String?
        let CommunityRating: Double?
        let MediaSources: [MediaSource]?
        let ProviderIds: [String: String]?

        enum CodingKeys: String, CodingKey {
            case Id, Name, kind = "Type", CollectionType, IsFolder, Overview, ProductionYear, RunTimeTicks
            case UserData, ImageTags, BackdropImageTags, ParentBackdropItemId, ParentBackdropImageTags
            case ParentThumbItemId, ParentThumbImageTag, SeriesId, SeriesName, SeriesPrimaryImageTag
            case SeasonId, ParentIndexNumber, IndexNumber, Genres, OfficialRating, CommunityRating, MediaSources, ProviderIds
        }
    }

    // MARK: - Mapping

    private func imageURL(_ itemId: String, _ type: String, tag: String?, index: Int? = nil, maxWidth: Int) -> URL? {
        guard let tag else { return nil }
        let path = index.map { "/Items/\(itemId)/Images/\(type)/\($0)" } ?? "/Items/\(itemId)/Images/\(type)"
        return try? MSHTTP.url(base, path, ["tag": tag, "maxWidth": String(maxWidth), "quality": "90"])
    }

    private func toItem(_ dto: DTO) -> MSItem {
        let kind: MSItem.Kind
        switch dto.kind {
        case "Movie": kind = .movie
        case "Series": kind = .series
        case "Season": kind = .season
        case "Episode": kind = .episode
        case "Video", "MusicVideo", "Trailer": kind = .video
        case "Folder", "CollectionFolder", "BoxSet", "Playlist": kind = .folder
        default: kind = (dto.IsFolder ?? false) ? .folder : .other
        }

        let ownPrimary = imageURL(dto.Id, "Primary", tag: dto.ImageTags?["Primary"], maxWidth: 500)
        let seriesPrimary = dto.SeriesId.flatMap { imageURL($0, "Primary", tag: dto.SeriesPrimaryImageTag, maxWidth: 500) }
        let poster: URL?
        switch kind {
        case .episode: poster = seriesPrimary ?? ownPrimary
        case .season: poster = ownPrimary ?? seriesPrimary
        default: poster = ownPrimary
        }

        var backdrop = imageURL(dto.Id, "Backdrop", tag: dto.BackdropImageTags?.first, index: 0, maxWidth: 1920)
        if backdrop == nil, let parent = dto.ParentBackdropItemId {
            backdrop = imageURL(parent, "Backdrop", tag: dto.ParentBackdropImageTags?.first, index: 0, maxWidth: 1920)
        }

        var thumb: URL?
        if kind == .episode || kind == .video {
            thumb = imageURL(dto.Id, "Primary", tag: dto.ImageTags?["Primary"], maxWidth: 800)
        } else {
            thumb = imageURL(dto.Id, "Thumb", tag: dto.ImageTags?["Thumb"], maxWidth: 800)
                ?? dto.ParentThumbItemId.flatMap { imageURL($0, "Thumb", tag: dto.ParentThumbImageTag, maxWidth: 800) }
        }

        let ticks = dto.RunTimeTicks ?? dto.MediaSources?.first?.RunTimeTicks
        return MSItem(
            id: dto.Id,
            kind: kind,
            title: dto.Name ?? "",
            overview: dto.Overview,
            year: dto.ProductionYear,
            duration: ticks.map { Double($0) / Self.ticksPerSecond },
            resumePosition: Double(dto.UserData?.PlaybackPositionTicks ?? 0) / Self.ticksPerSecond,
            isWatched: dto.UserData?.Played ?? false,
            unwatchedCount: dto.UserData?.UnplayedItemCount,
            posterURL: poster,
            backdropURL: backdrop ?? thumb,
            thumbURL: thumb ?? backdrop,
            seriesId: dto.SeriesId,
            seriesTitle: dto.SeriesName,
            seasonId: dto.SeasonId,
            seasonNumber: kind == .season ? dto.IndexNumber : dto.ParentIndexNumber,
            episodeNumber: kind == .episode ? dto.IndexNumber : nil,
            genres: dto.Genres ?? [],
            officialRating: dto.OfficialRating,
            communityRating: dto.CommunityRating,
            tmdbId: Self.providerId("tmdb", in: dto.ProviderIds),
            imdbId: Self.providerId("imdb", in: dto.ProviderIds)
        )
    }

    // MARK: - Browse

    func libraries() async throws -> [MSLibrary] {
        let result = try await get("/Users/\(userId)/Views", as: ItemsResult.self)
        return result.Items.compactMap { dto in
            let kind: MSLibrary.Kind
            switch dto.CollectionType?.lowercased() {
            case "movies": kind = .movies
            case "tvshows": kind = .shows
            case "music", "musicvideos", "books", "playlists", "livetv", "photos": return nil
            default: kind = .mixed
            }
            return MSLibrary(
                id: dto.Id,
                title: dto.Name ?? "",
                kind: kind,
                imageURL: imageURL(dto.Id, "Primary", tag: dto.ImageTags?["Primary"], maxWidth: 800)
            )
        }
    }

    func items(in library: MSLibrary, start: Int, limit: Int) async throws -> MSPage {
        var query: [String: String?] = [
            "ParentId": library.id,
            "StartIndex": String(start),
            "Limit": String(limit),
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Fields": Self.listFields,
            "EnableImageTypes": "Primary,Backdrop,Thumb",
            "ImageTypeLimit": "1",
        ]
        switch library.kind {
        case .movies:
            query["Recursive"] = "true"
            query["IncludeItemTypes"] = "Movie"
        case .shows:
            query["Recursive"] = "true"
            query["IncludeItemTypes"] = "Series"
        default:
            break
        }
        let result = try await get("/Users/\(userId)/Items", query, as: ItemsResult.self)
        return MSPage(items: result.Items.map(toItem), total: result.TotalRecordCount ?? result.Items.count)
    }

    func children(of item: MSItem) async throws -> [MSItem] {
        switch item.kind {
        case .series:
            let result = try await get("/Shows/\(item.id)/Seasons", [
                "UserId": userId, "Fields": Self.listFields,
            ], as: ItemsResult.self)
            return result.Items.map(toItem)
        case .season:
            guard let seriesId = item.seriesId else { return [] }
            let result = try await get("/Shows/\(seriesId)/Episodes", [
                "UserId": userId, "SeasonId": item.id, "Fields": Self.listFields,
            ], as: ItemsResult.self)
            return result.Items.map(toItem)
        default:
            let result = try await get("/Users/\(userId)/Items", [
                "ParentId": item.id, "SortBy": "SortName", "Fields": Self.listFields,
            ], as: ItemsResult.self)
            return result.Items.map(toItem)
        }
    }

    func detail(id: String) async throws -> MSItem {
        let dto = try await get("/Users/\(userId)/Items/\(id)", [
            "Fields": Self.listFields + ",MediaSources",
        ], as: DTO.self)
        return toItem(dto)
    }

    func continueWatching() async throws -> [MSItem] {
        let result = try await get("/Users/\(userId)/Items/Resume", [
            "Limit": "24", "MediaTypes": "Video", "Fields": Self.listFields,
            "EnableImageTypes": "Primary,Backdrop,Thumb",
        ], as: ItemsResult.self)
        return result.Items.map(toItem)
    }

    func nextUp() async throws -> [MSItem] {
        let result = try await get("/Shows/NextUp", [
            "UserId": userId, "Limit": "24", "Fields": Self.listFields,
        ], as: ItemsResult.self)
        return result.Items.map(toItem)
    }

    func recentlyAdded(in library: MSLibrary) async throws -> [MSItem] {
        let items = try await get("/Users/\(userId)/Items/Latest", [
            "ParentId": library.id, "Limit": "20", "Fields": Self.listFields,
        ], as: [DTO].self)
        return items.map(toItem)
    }

    func search(_ query: String) async throws -> [MSItem] {
        let result = try await get("/Users/\(userId)/Items", [
            "SearchTerm": query, "Recursive": "true", "Limit": "60",
            "IncludeItemTypes": "Movie,Series,Episode", "Fields": Self.listFields,
        ], as: ItemsResult.self)
        return result.Items.map(toItem)
    }

    // MARK: - Playback

    func playbackSource(for item: MSItem, resume: Bool) async throws -> MSPlaybackSource {
        struct PlaybackInfo: Decodable {
            let MediaSources: [DTO.MediaSource]?
            let PlaySessionId: String?
        }
        let info = try await get("/Items/\(item.id)/PlaybackInfo", ["UserId": userId], as: PlaybackInfo.self)
        guard let source = info.MediaSources?.first else { throw MediaServerError.notPlayable }
        let mediaSourceId = source.Id ?? item.id
        let playSessionId = info.PlaySessionId ?? UUID().uuidString
        let video = source.MediaStreams?.first { $0.kind == "Video" }?.Codec
        let audio = source.MediaStreams?.first { $0.kind == "Audio" }?.Codec
        let direct = MSDirectPlay.canDirectPlay(container: source.Container, videoCodec: video, audioCodec: audio)

        let url: URL
        if direct {
            url = try MSHTTP.url(base, "/Videos/\(item.id)/stream", [
                "Static": "true",
                "MediaSourceId": mediaSourceId,
                "PlaySessionId": playSessionId,
                "DeviceId": MediaServerDevice.id,
                "api_key": token,
            ])
        } else {
            url = try MSHTTP.url(base, "/Videos/\(item.id)/master.m3u8", [
                "MediaSourceId": mediaSourceId,
                "PlaySessionId": playSessionId,
                "DeviceId": MediaServerDevice.id,
                "api_key": token,
                "VideoCodec": "h264",
                "AudioCodec": "aac,ac3,eac3",
                "TranscodingMaxAudioChannels": "6",
                "MaxStreamingBitrate": "40000000",
                "SegmentContainer": "ts",
                "BreakOnNonKeyFrames": "True",
                "RequireAvc": "false",
            ])
        }
        let duration = source.RunTimeTicks.flatMap { $0 > 0 ? Double($0) / Self.ticksPerSecond : nil } ?? item.duration
        return MSPlaybackSource(
            url: url,
            startPosition: resume ? item.resumePosition : 0,
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            isTranscoding: !direct,
            duration: duration
        )
    }

    func report(_ state: MSPlaybackState, item: MSItem, source: MSPlaybackSource, position: Double, isPaused: Bool) async {
        let body: [String: Any] = [
            "ItemId": item.id,
            "MediaSourceId": source.mediaSourceId ?? item.id,
            "PlaySessionId": source.playSessionId,
            "PositionTicks": Int64(max(position, 0) * Self.ticksPerSecond),
            "IsPaused": isPaused,
            "CanSeek": true,
            "PlayMethod": source.isTranscoding ? "Transcode" : "DirectPlay",
            "EventName": isPaused ? "pause" : "timeupdate",
        ]
        let path: String
        switch state {
        case .started: path = "/Sessions/Playing"
        case .playing, .paused: path = "/Sessions/Playing/Progress"
        case .stopped: path = "/Sessions/Playing/Stopped"
        }
        try? await post(path, body: body)
        if state == .stopped, source.isTranscoding {
            try? await post("/Videos/ActiveEncodings", [
                "DeviceId": MediaServerDevice.id, "PlaySessionId": source.playSessionId,
            ], method: "DELETE")
        }
    }

    func setWatched(_ watched: Bool, item: MSItem) async throws {
        try await post("/Users/\(userId)/PlayedItems/\(item.id)", method: watched ? "POST" : "DELETE")
    }

    func saveResume(_ item: MSItem, position: Double) async throws {
        let body: [String: Any] = ["PlaybackPositionTicks": Int64(max(0, position) * Self.ticksPerSecond)]
        do {
            // Emby and Jellyfin up to 10.8.
            try await post("/Users/\(userId)/Items/\(item.id)/UserData", body: body)
        } catch MediaServerError.http(let code) where code == 404 || code == 405 {
            // Jellyfin 10.9 and later.
            try await post("/UserItems/\(item.id)/UserData", ["userId": userId], body: body)
        }
    }

    /// Provider ids arrive as "Tmdb", "tmdb", or "TMDB" depending on the server.
    static func providerId(_ name: String, in ids: [String: String]?) -> String? {
        guard let ids else { return nil }
        for (key, value) in ids where key.lowercased() == name && !value.isEmpty { return value }
        return nil
    }
}
#endif
