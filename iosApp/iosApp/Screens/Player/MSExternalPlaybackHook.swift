import Foundation

/// The player's door to Emby, Plex, and IPTV files (`MSExternalPlayback`).
/// The Mac app has no media-server support, so there it names nothing.
@MainActor
enum MSExternalPlaybackHook {
    nonisolated static func isExternal(_ id: String?) -> Bool {
        #if os(macOS)
        false
        #else
        MSExternalPlayback.isExternal(id)
        #endif
    }

    nonisolated static func isExternalSession(_ id: String?) -> Bool {
        #if os(macOS)
        false
        #else
        MSExternalPlayback.isExternalSession(id)
        #endif
    }

    static func prepare(
        id: String,
        startFromBeginning: Bool,
        resumePositionOverride: Double?
    ) async throws -> PreparedPlayback {
        #if os(macOS)
        throw CancellationError()
        #else
        try await MSExternalPlayback.shared.preparedPlayback(
            for: id,
            startFromBeginning: startFromBeginning,
            resumePositionOverride: resumePositionOverride
        )
        #endif
    }

    static func artworkURL(for id: String) -> URL? {
        #if os(macOS)
        nil
        #else
        MSExternalPlayback.artworkURL(for: id)
        #endif
    }

    static func recordProgress(id: String, position: Double, duration: Double, completed: Bool, force: Bool) {
        #if !os(macOS)
        MSExternalPlayback.shared.recordProgress(
            id: id, position: position, duration: duration, completed: completed, force: force
        )
        #endif
    }

    /// The title's subtitles translated with the viewer's own AI key, ready
    /// to add as a track: file URL, label, language.
    static func aiSubtitle(id: String, onStart: @MainActor () -> Void) async throws -> (url: URL, label: String, language: String)? {
        #if os(macOS)
        nil
        #else
        guard let result = try await MSExternalPlayback.shared.aiSubtitle(for: id, onStart: onStart) else { return nil }
        return (result.url, result.label, result.language)
        #endif
    }
}
