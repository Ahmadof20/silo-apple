#if os(tvOS)
import SwiftUI

/// Plays an Emby, Jellyfin, Plex, or IPTV title in Silo's own player: the
/// same controls, scrubber, audio and subtitle menus, subtitle styling,
/// stream info panel, and engine (MKV, HEVC, AV1, Dolby Vision, HDR10,
/// TrueHD and DTS) as a Silo title. `MSExternalPlayback` hands the player
/// the media server's original file the way a download is handed to it.
struct TVExternalPlayerView: View {
    let client: any MediaServerClient
    let item: MSItem
    let resume: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var playbackId: String

    init(client: any MediaServerClient, item: MSItem, resume: Bool) {
        self.client = client
        self.item = item
        self.resume = resume
        _playbackId = State(initialValue: MSExternalPlayback.shared.register(client: client, item: item, resume: resume))
    }

    var body: some View {
        PlayerView(
            contentId: MSExternalPlayback.shared.contentId(for: playbackId),
            startFromBeginning: !resume,
            offlineDownloadId: playbackId,
            posterURLHint: (item.posterURL ?? item.thumbURL)?.absoluteString,
            backdropURLHint: (item.backdropURL ?? item.thumbURL)?.absoluteString,
            onDismissRequested: { dismiss() }
        )
        .background(Color.black.ignoresSafeArea())
    }
}
#endif
