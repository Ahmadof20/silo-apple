#if !os(macOS)
import Foundation
import OSLog

/// Plays Emby, Jellyfin, Plex, and IPTV files in Silo's own player.
///
/// Silo's player already plays a downloaded file with no server session: the
/// download id routes the prepare through `OfflinePlaybackBuilder`, and every
/// server call (reconnect, track prefs, markers, progress) stays off while it
/// plays. An external title takes that same road with an id that starts with
/// `idPrefix`. This type builds the prepared playback for that id from the
/// media server's original file, and sends progress back to that server.
@MainActor
final class MSExternalPlayback {
    static let shared = MSExternalPlayback()
    static let idPrefix = "ms-ext:"
    static let sessionPrefix = "ms-ext-"

    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "MSExternalPlayback")

    struct Entry {
        let client: any MediaServerClient
        let item: MSItem
        let resume: Bool
        var lastSaved: Date = .distantPast
        var markedWatched = false
    }

    private var entries: [String: Entry] = [:]

    nonisolated static func isExternal(_ id: String?) -> Bool {
        id?.hasPrefix(idPrefix) == true
    }

    nonisolated static func isExternalSession(_ id: String?) -> Bool {
        id?.hasPrefix(sessionPrefix) == true
    }

    /// The id the player is opened with for this item.
    func register(client: any MediaServerClient, item: MSItem, resume: Bool) -> String {
        // The same title always gets the same id, so a view that rebuilds
        // registers it once.
        let id = Self.idPrefix + client.account.id + "|" + item.id + (resume ? "|r" : "|0")
        if entries[id]?.item != item {
            entries[id] = Entry(client: client, item: item, resume: resume)
        }
        return id
    }

    func entry(_ id: String) -> Entry? { entries[id] }

    /// The content id the player keys the title by. It names no Silo title,
    /// so nothing on the Silo server is read or written for it.
    func contentId(for id: String) -> String {
        guard let entry = entries[id] else { return id }
        return "ms:\(entry.client.account.id):\(entry.item.id)"
    }

    // MARK: - Prepare

    enum PrepareError: LocalizedError {
        case expired
        var errorDescription: String? { "انتهت صلاحية هذا التشغيل. افتح العنوان مرة أخرى." }
    }

    /// The same shape the server's start-playback answer has, built from the
    /// media server's original file. The engine probes the file itself, so
    /// every embedded audio and subtitle track shows in Silo's menus; the
    /// server's separate subtitle files are added as sidecar tracks.
    func preparedPlayback(
        for id: String,
        startFromBeginning: Bool,
        resumePositionOverride: Double?
    ) async throws -> PreparedPlayback {
        guard let entry = entries[id] else { throw PrepareError.expired }
        let stream = try await entry.client.directStream(for: entry.item)
        let item = entry.item
        let info = stream.info

        let duration = MSSafe.duration(info?.duration ?? item.duration)
        let resume: Double? = {
            if startFromBeginning { return 0 }
            if let resumePositionOverride, resumePositionOverride.isFinite, resumePositionOverride >= 0 {
                return resumePositionOverride
            }
            guard entry.resume, item.resumePosition > 5 else { return nil }
            if let duration, item.resumePosition >= duration - 5 { return 0 }
            return item.resumePosition
        }()

        let version = FileVersion(
            fileId: 0,
            fileName: nil,
            resolution: info?.resolution,
            codecVideo: info?.videoCodec,
            codecAudio: info?.audioCodec,
            hdr: info?.dynamicRange.map { $0 != "SDR" },
            container: info?.container,
            fileSize: info?.size,
            duration: duration,
            bitrate: info?.bitrate.flatMap { MSSafe.int(Double($0) / 1_000) },
            videoTracks: nil,
            audioTracks: nil,
            subtitleTracks: nil,
            chapters: nil,
            intro: nil,
            credits: nil,
            recap: nil,
            markerSegments: nil,
            effectiveAudioLanguage: nil
        )

        let isEpisode = item.kind == .episode
        let watchDetail = WatchDetail(
            contentId: contentId(for: id),
            type: isEpisode ? "episode" : "movie",
            title: item.title,
            year: item.year,
            overview: item.overview,
            versions: [version],
            subtitles: nil,
            intro: nil,
            credits: nil,
            recap: nil,
            userData: nil,
            seriesId: nil,
            seriesTitle: isEpisode ? item.seriesTitle : nil,
            seasonNumber: isEpisode ? item.seasonNumber : nil,
            episodeNumber: isEpisode ? item.episodeNumber : nil,
            // Subtitles in the viewer's translation language show on their
            // own when the audio is in another language, as Silo does.
            effectiveSubtitleLanguage: MSAISettings.targetLanguage,
            effectiveSubtitleMode: "auto",
            effectiveShowForcedSubtitles: nil,
            effectiveSubtitleTrackSignature: nil
        )

        // Tracks inside the file are probed by the engine; only separate
        // subtitle files go in as sidecars.
        let sidecars = stream.subtitles.filter { !$0.isEmbedded }
        let subtitleURLs = sidecars.enumerated().map { index, ref in
            SubtitleUrl(
                index: index,
                language: ref.language,
                codec: Self.codec(of: ref.url),
                label: ref.title,
                source: "external",
                forced: false,
                url: ref.url.absoluteString
            )
        }

        let session = PlaybackSessionResponse(
            sessionId: Self.sessionPrefix + UUID().uuidString,
            userId: nil,
            profileId: nil,
            mediaFileId: nil,
            playMethod: "direct",
            position: resume ?? 0,
            isPaused: false,
            streamUrl: stream.url.absoluteString,
            audioTrackIndex: nil,
            durationSeconds: duration,
            timelineOffsetSeconds: 0,
            subtitleUrls: subtitleURLs.isEmpty ? nil : subtitleURLs,
            playbackInfo: nil
        )

        Task { await entry.client.reportStart(item) }
        return PreparedPlayback(watchDetail: watchDetail, selectedVersion: version, session: session)
    }

    static func codec(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "srt", "subrip": return "subrip"
        case "vtt", "webvtt": return "webvtt"
        case "ass", "ssa": return ext
        default: return ext.isEmpty ? nil : ext
        }
    }

    static func artworkURL(for id: String) -> URL? {
        guard let item = shared.entries[id]?.item else { return nil }
        return item.posterURL ?? item.thumbURL ?? item.backdropURL
    }

    // MARK: - Progress

    /// Where the viewer is, sent to the media server at most every 15
    /// seconds, and always at the end. Past 90% the title counts as watched.
    func recordProgress(id: String, position: Double, duration: Double, completed: Bool, force: Bool = false) {
        guard var entry = entries[id], position.isFinite, position >= 0 else { return }
        let watched = completed || (duration > 0 && position / duration >= 0.9)
        if watched {
            guard !entry.markedWatched else { return }
            entry.markedWatched = true
            entries[id] = entry
            let client = entry.client, item = entry.item
            Task { try? await client.setWatched(true, item: item) }
            return
        }
        guard position > 5, force || Date().timeIntervalSince(entry.lastSaved) >= 15 else { return }
        entry.lastSaved = Date()
        entries[id] = entry
        let client = entry.client, item = entry.item
        Task {
            do {
                try await client.saveResume(item, position: position)
            } catch {
                Self.logger.debug("Resume save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func release(_ id: String) {
        entries[id] = nil
    }
}
#endif

#if !os(macOS)
extension MediaServerClient {
    /// Lets the server show the title as playing where it supports it.
    func reportStart(_ item: MSItem) async {}
}
#endif
