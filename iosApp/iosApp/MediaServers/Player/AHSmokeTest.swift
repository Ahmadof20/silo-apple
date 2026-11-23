#if os(tvOS)
import SwiftUI

/// A self-test the build machine runs in the Apple TV simulator. Launched
/// with `-AHSmokeTest`, the app opens an external title's page and then plays
/// a public sample file in Silo's player, so screenshots show both working
/// without a real Emby, Plex, or IPTV account. Without the argument it does
/// nothing.
struct AHSmokeTest: ViewModifier {
    let router: AppRouter

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-AHSmokeTest") }

    private enum Stage: Identifiable {
        case detail, player
        var id: Self { self }
    }

    @State private var stage: Stage?

    func body(content: Content) -> some View {
        content
            .task {
                guard Self.isEnabled else { return }
                try? await Task.sleep(for: .seconds(8))
                stage = .detail
                try? await Task.sleep(for: .seconds(14))
                stage = nil
                try? await Task.sleep(for: .seconds(2))
                stage = .player
            }
            .fullScreenCover(item: $stage) { stage in
                Group {
                    switch stage {
                    case .detail:
                        NavigationStack {
                            TVMSDetailView(client: AHSmokeClient(), item: AHSmokeClient.movie)
                        }
                    case .player:
                        TVExternalPlayerView(client: AHSmokeClient(), item: AHSmokeClient.movie, resume: false)
                    }
                }
                .environment(router)
                .environmentObject(OverlayPrefsStore.shared)
            }
    }
}

/// A pretend media server with one movie: a public Matroska sample with
/// several audio and subtitle tracks, plus an Arabic subtitle file.
struct AHSmokeClient: MediaServerClient {
    var account = MediaServerAccount(
        id: "smoke", kind: .emby, serverName: "Smoke Test", baseURL: "https://raw.githubusercontent.com",
        userId: "", username: "smoke", serverId: "smoke", addedAt: Date()
    )

    static let movie = MSItem(
        id: "smoke-movie", kind: .movie, title: "Elephants Dream",
        overview: "A sample film used to check playback, audio tracks, and subtitles.",
        year: 2006, duration: 654,
        posterURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/e/e8/Elephants_Dream_s5_both.jpg/640px-Elephants_Dream_s5_both.jpg"),
        backdropURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/e/e8/Elephants_Dream_s5_both.jpg/1280px-Elephants_Dream_s5_both.jpg"),
        genres: ["Animation"]
    )

    static let video = URL(string: "https://raw.githubusercontent.com/ietf-wg-cellar/matroska-test-files/master/test_files/test5.mkv")!
    static let arabic = URL(string: "https://raw.githubusercontent.com/Ahmadof20/silo-apple/emby-plex/.github/smoke/ar.srt")!

    func libraries() async throws -> [MSLibrary] { [] }
    func items(in library: MSLibrary, start: Int, limit: Int) async throws -> MSPage { throw CancellationError() }
    func children(of item: MSItem) async throws -> [MSItem] { [] }
    func detail(id: String) async throws -> MSItem { Self.movie }
    func continueWatching() async throws -> [MSItem] { [] }
    func nextUp() async throws -> [MSItem] { [] }
    func recentlyAdded(in library: MSLibrary) async throws -> [MSItem] { [] }
    func search(_ query: String) async throws -> [MSItem] { [] }
    func playbackSource(for item: MSItem, resume: Bool) async throws -> MSPlaybackSource { throw CancellationError() }
    func report(_ state: MSPlaybackState, item: MSItem, source: MSPlaybackSource, position: Double, isPaused: Bool) async {}
    func setWatched(_ watched: Bool, item: MSItem) async throws {}
    func saveResume(_ item: MSItem, position: Double) async throws {}
    func mediaInfo(for item: MSItem) async throws -> MSMediaInfo? {
        MSMediaInfo(resolution: "1080p", videoCodec: "h264", audioCodec: "aac", dynamicRange: "SDR", container: "mkv",
                    audioLanguages: ["eng", "fre"], subtitleLanguages: ["ara", "eng"])
    }
    func directStream(for item: MSItem) async throws -> MSDirectStream {
        MSDirectStream(
            url: Self.video,
            subtitles: [MSSubtitleRef(title: "العربية (ملف)", language: "ar", url: Self.arabic, isEmbedded: false)],
            info: try await mediaInfo(for: item)
        )
    }
}
#endif
