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
