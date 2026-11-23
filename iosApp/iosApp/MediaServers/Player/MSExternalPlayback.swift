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
        var stream: MSDirectStream?
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
        entries[id]?.stream = stream
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
            // The engine reads the real length from the file. A server's
            // runtime is often rounded (IPTV), and a length longer than the
            // file made its end look like a dropped connection.
            duration: nil,
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
            durationSeconds: nil,
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

    // MARK: - AI subtitles

    struct AISubtitle {
        let url: URL
        let label: String
        let language: String
    }

    /// The title's subtitles translated into the viewer's language with
    /// their own AI key, as an SRT file the player adds as a track. Nil when
    /// no key is set, a subtitle in that language already exists, or the
    /// source has no text subtitle to translate. `onStart` runs only when
    /// work actually begins. A translated file is kept, so playing the
    /// title again is instant.
    func aiSubtitle(for id: String, onStart: @MainActor () -> Void) async throws -> AISubtitle? {
        guard MSAISettings.isConfigured, let entry = entries[id], let stream = entry.stream else { return nil }
        let target = MSAISettings.targetLanguage
        let label = "\(MSAISettings.languageName(target)) · AI"
        if stream.subtitles.contains(where: { Self.sameLanguage($0.language, target) }) { return nil }
        let textual = stream.subtitles.filter { ref in
            let codec = Self.codec(of: ref.url) ?? ""
            return ["subrip", "webvtt"].contains(codec) || ref.url.absoluteString.lowercased().contains(".srt")
        }
        guard let source = textual.first(where: { Self.sameLanguage($0.language, "en") }) ?? textual.first else { return nil }

        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ms-ai-subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String("\(entry.client.account.id)-\(entry.item.id)-\(target)".map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let file = folder.appendingPathComponent(name + ".srt")
        if FileManager.default.fileExists(atPath: file.path) {
            return AISubtitle(url: file, label: label, language: target)
        }

        onStart()
        let (data, _) = try await MSHTTP.session.data(from: source.url)
        let cues = MSSubtitleParser.parse(String(decoding: data, as: UTF8.self))
        guard !cues.isEmpty else { return nil }

        // Batches of 40 lines, four at a time.
        let batches: [[MSCue]] = stride(from: 0, to: cues.count, by: 40).map { Array(cues[$0..<min($0 + 40, cues.count)]) }
        var translated = [[String]](repeating: [], count: batches.count)
        try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var next = 0
            for _ in 0..<min(4, batches.count) {
                let index = next
                let lines = batches[index].map(\.text)
                next += 1
                group.addTask { (index, try await MSAITranslator.shared.translate(lines)) }
            }
            while let (index, lines) = try await group.next() {
                translated[index] = lines
                if next < batches.count {
                    let nextIndex = next
                    let nextLines = batches[nextIndex].map(\.text)
                    next += 1
                    group.addTask { (nextIndex, try await MSAITranslator.shared.translate(nextLines)) }
                }
            }
        }

        var srt = ""
        var number = 1
        for (batch, lines) in zip(batches, translated) {
            for (cue, line) in zip(batch, lines) {
                srt += "\(number)\n\(Self.srtTime(cue.start)) --> \(Self.srtTime(cue.end))\n\(line)\n\n"
                number += 1
            }
        }
        try Data(srt.utf8).write(to: file, options: .atomic)
        return AISubtitle(url: file, label: label, language: target)
    }

    nonisolated static func sameLanguage(_ code: String?, _ target: String) -> Bool {
        guard let code = code?.lowercased(), !code.isEmpty else { return false }
        let map = ["ara": "ar", "eng": "en", "fre": "fr", "fra": "fr", "spa": "es", "ger": "de", "deu": "de",
                   "tur": "tr", "urd": "ur", "per": "fa", "fas": "fa", "ind": "id", "hin": "hi"]
        return (map[code] ?? String(code.prefix(2))) == target
    }

    nonisolated static func srtTime(_ seconds: Double) -> String {
        let total = MSSafe.int((max(seconds, 0) * 1000).rounded()) ?? 0
        return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
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
