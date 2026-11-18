#if !os(macOS)
import Foundation

/// The third-party media servers this app can sign in to directly, beside
/// Silo servers. The Emby client also works against Jellyfin, which kept
/// Emby's REST API and its `X-Emby-Authorization` header.
enum MediaServerKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case emby
    case plex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .emby: "Emby"
        case .plex: "Plex"
        }
    }

    var systemImage: String {
        switch self {
        case .emby: "server.rack"
        case .plex: "play.rectangle.on.rectangle"
        }
    }
}

/// One signed-in server. The access token is kept in the keychain
/// (`MediaServerKeychain`), never in this Codable record.
struct MediaServerAccount: Codable, Identifiable, Hashable {
    var id: String
    var kind: MediaServerKind
    /// The server's own name ("Living Room Emby").
    var serverName: String
    /// The address requests go to, with no trailing slash.
    var baseURL: String
    /// Emby/Jellyfin user id. Plex leaves it empty.
    var userId: String
    var username: String
    /// Emby ServerId or Plex machineIdentifier.
    var serverId: String
    var addedAt: Date

    var url: URL? { URL(string: baseURL) }
}

struct MSLibrary: Identifiable, Hashable {
    enum Kind: Hashable { case movies, shows, music, photos, mixed }
    var id: String
    var title: String
    var kind: Kind
    var imageURL: URL?
}

/// A playable or browsable item, mapped from either server into one shape
/// so every screen in this section is shared.
struct MSItem: Identifiable, Hashable {
    enum Kind: String, Hashable { case movie, series, season, episode, folder, video, other }

    var id: String
    var kind: MSItem.Kind
    var title: String
    var overview: String?
    var year: Int?
    /// Seconds. Nil when the server does not know.
    var duration: Double?
    /// Resume point in seconds; 0 when unstarted.
    var resumePosition: Double = 0
    var isWatched: Bool = false
    /// Unwatched episode count for a series or season.
    var unwatchedCount: Int?
    var posterURL: URL?
    var backdropURL: URL?
    /// Episode still / wide artwork.
    var thumbURL: URL?
    var seriesId: String?
    var seriesTitle: String?
    var seasonId: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var genres: [String] = []
    var officialRating: String?
    var communityRating: Double?

    var isPlayable: Bool {
        switch kind {
        case .movie, .episode, .video: true
        default: false
        }
    }

    var isContainer: Bool {
        switch kind {
        case .series, .season, .folder: true
        default: false
        }
    }

    var progressFraction: Double? {
        guard let duration, duration > 0, resumePosition > 0 else { return nil }
        return min(max(resumePosition / duration, 0), 1)
    }

    /// "S2 · E5" for episodes.
    var episodeLabel: String? {
        guard kind == .episode else { return nil }
        switch (seasonNumber, episodeNumber) {
        case let (s?, e?): return "S\(s) · E\(e)"
        case let (nil, e?): return "E\(e)"
        default: return nil
        }
    }

    var subtitleLine: String? {
        var parts: [String] = []
        if let episodeLabel { parts.append(episodeLabel) }
        if let year, kind != .episode { parts.append(String(year)) }
        if let duration, duration > 0 { parts.append(MSFormat.runtime(duration)) }
        if let officialRating, !officialRating.isEmpty { parts.append(officialRating) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct MSPage {
    var items: [MSItem]
    var total: Int
}

/// What the player needs to start one item.
struct MSPlaybackSource {
    var url: URL
    var startPosition: Double
    /// Server-side bookkeeping for progress reports and stopping transcodes.
    var playSessionId: String
    var mediaSourceId: String?
    var isTranscoding: Bool
    var duration: Double?
}

enum MSPlaybackState {
    case started, playing, paused, stopped
}

/// A server that a Plex account can reach. Picked once while adding Plex.
struct MSPlexServerChoice: Identifiable, Hashable {
    var id: String { machineIdentifier }
    var name: String
    var machineIdentifier: String
    var accessToken: String
    var connections: [Connection]
    var owned: Bool

    struct Connection: Hashable {
        var uri: String
        var local: Bool
        var relay: Bool
    }
}

enum MediaServerError: LocalizedError {
    case invalidAddress
    case unauthorized
    case http(Int)
    case unreachable(String)
    case decoding
    case noServers
    case notPlayable
    case pinExpired

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "The server address isn't valid."
        case .unauthorized: "Wrong username or password, or the session has expired."
        case .http(let code): "The server answered with an error (\(code))."
        case .unreachable(let detail): "Couldn't reach the server. \(detail)"
        case .decoding: "The server sent a reply this app can't read."
        case .noServers: "No Plex servers were found for this account."
        case .notPlayable: "This item can't be played."
        case .pinExpired: "The sign-in code expired. Try again."
        }
    }
}

enum MSFormat {
    static func runtime(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    static func remaining(_ item: MSItem) -> String? {
        guard let duration = item.duration, item.resumePosition > 0 else { return nil }
        let left = max(duration - item.resumePosition, 0)
        return "\(runtime(left)) left"
    }
}

/// Normalizes what a person types ("192.168.1.5:8096", "emby.example.com")
/// into a base URL with a scheme and no trailing slash.
enum MSAddress {
    static func normalize(_ raw: String, defaultPort: Int?) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return nil
        }
        if components.port == nil, components.scheme == "http", let defaultPort {
            components.port = defaultPort
        }
        return components.url
    }
}
#endif
