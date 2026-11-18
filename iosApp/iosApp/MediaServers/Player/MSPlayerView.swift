#if !os(macOS)
import AVKit
import SwiftUI

/// Full-screen system player for Emby and Plex items. Uses AVPlayer with
/// the server's direct file when Apple can play it, and the server's HLS
/// stream otherwise. Reports start, progress every 10 seconds, pause, and
/// stop so watch state and Continue Watching stay in sync on the server.
struct MSPlayerView: View {
    let client: any MediaServerClient
    let item: MSItem
    let resume: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var controller = MSPlaybackController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = controller.player {
                MSSystemPlayer(player: player, title: item.title, subtitle: item.seriesTitle) {
                    dismiss()
                }
                .ignoresSafeArea()
            } else if let error = controller.error {
                VStack(spacing: 16) {
                    Text(error).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding(40)
            } else {
                ProgressView().tint(.white).controlSize(.large)
            }
        }
        #if os(iOS)
        // The embedded system player has no Done button of its own.
        // Sits under AVKit's own top control bar so the two don't overlap.
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .padding(.top, 56)
                    .padding(.leading, 16)
            }
            .accessibilityLabel("Close")
        }
        #endif
        .task { await controller.start(client: client, item: item, resume: resume) }
        .onDisappear { controller.stop() }
    }
}

@MainActor
@Observable
final class MSPlaybackController {
    private(set) var player: AVPlayer?
    private(set) var error: String?

    private var client: (any MediaServerClient)?
    private var item: MSItem?
    private var source: MSPlaybackSource?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var lastReport = Date.distantPast
    private var lastPaused = false
    private var stopped = false

    func start(client: any MediaServerClient, item: MSItem, resume: Bool) async {
        guard player == nil else { return }
        self.client = client
        self.item = item
        do {
            let source = try await client.playbackSource(for: item, resume: resume)
            guard !stopped else { return }
            self.source = source

            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)

            let playerItem = AVPlayerItem(url: source.url)
            playerItem.externalMetadata = metadata(for: item)
            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true

            itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
                Task { @MainActor in self?.itemStatusChanged(observed) }
            }
            statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
                Task { @MainActor in self?.timeControlChanged(observed) }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }

            self.player = player
            await client.report(.started, item: item, source: source, position: source.startPosition, isPaused: false)
        } catch {
            self.error = error.msMessage
        }
    }

    private var didSeekToStart = false

    private func itemStatusChanged(_ playerItem: AVPlayerItem) {
        switch playerItem.status {
        case .readyToPlay:
            guard !didSeekToStart, let player, let source else { return }
            didSeekToStart = true
            if source.startPosition > 5 {
                player.seek(to: CMTime(seconds: source.startPosition, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in self.player?.play() }
                }
            } else {
                player.play()
            }
        case .failed:
            error = playerItem.error?.localizedDescription ?? "Playback failed."
            player = nil
        default:
            break
        }
    }

    private func timeControlChanged(_ player: AVPlayer) {
        let paused = player.timeControlStatus == .paused
        guard paused != lastPaused else { return }
        lastPaused = paused
        report(paused ? .paused : .playing, force: true)
    }

    private func tick() {
        report(.playing, force: false)
    }

    private var position: Double {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return seconds
    }

    private func report(_ state: MSPlaybackState, force: Bool) {
        guard !stopped, let client, let item, let source else { return }
        guard force || Date().timeIntervalSince(lastReport) >= 10 else { return }
        guard didSeekToStart else { return }
        lastReport = Date()
        let position = self.position
        let paused = lastPaused
        Task { await client.report(state, item: item, source: source, position: position, isPaused: paused) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let position = self.position
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        itemStatusObservation = nil
        player?.pause()
        player = nil
        if let client, let item, let source, didSeekToStart {
            Task { await client.report(.stopped, item: item, source: source, position: position, isPaused: true) }
        }
    }

    private func metadata(for item: MSItem) -> [AVMetadataItem] {
        func entry(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let meta = AVMutableMetadataItem()
            meta.identifier = id
            meta.value = value as NSString
            meta.extendedLanguageTag = "und"
            return meta.copy() as? AVMetadataItem
        }
        let title = item.kind == .episode ? [item.episodeLabel, item.title].compactMap { $0 }.joined(separator: " · ") : item.title
        return [
            entry(.commonIdentifierTitle, title),
            entry(.iTunesMetadataTrackSubTitle, item.seriesTitle),
            entry(.commonIdentifierDescription, item.overview),
        ].compactMap { $0 }
    }
}

/// AVPlayerViewController in SwiftUI. Done on iPhone and Menu on Apple TV
/// close the player.
private struct MSSystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let subtitle: String?
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        #if os(iOS)
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = true
        #endif
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        #if os(tvOS)
        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            onClose()
            return false
        }
        #endif
    }
}
#endif
