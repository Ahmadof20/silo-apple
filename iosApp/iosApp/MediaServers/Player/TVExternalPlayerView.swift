#if os(tvOS)
import AetherEngine
import AVFoundation
import Combine
import SwiftUI

/// Plays an Emby, Jellyfin, Plex, or IPTV file with Silo's own player
/// engine, so MKV, HEVC, Dolby Vision, HDR10, and lossless audio play
/// directly without a server transcode. Subtitles inside the file show the
/// way Silo shows them; a text track can also be translated by AI.
struct TVExternalPlayerView: View {
    let client: any MediaServerClient
    let item: MSItem
    let resume: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var playback = TVExternalPlayback()
    @State private var showsChrome = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focus: FocusTarget?

    private enum FocusTarget: Hashable { case surface, playPause, audio, subtitles, ai }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = playback.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
                if let subtitles = playback.subtitles {
                    AetherSubtitleOverlay(
                        engine: engine,
                        assSubtitles: subtitles.ass,
                        cueHold: subtitles.hold,
                        sourceTime: playback.currentTime,
                        primaryUsesMovieTimeline: false,
                        secondaryUsesMovieTimeline: false,
                        livePrimaryCues: [],
                        liveSecondaryCues: [],
                        appearance: PlayerSettings.shared.effectiveSubtitleAppearance,
                        subtitleSyncMs: 0,
                        bottomObstruction: showsChrome ? 260 : 0
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }

            if let line = playback.aiLine {
                Text(line)
                    .font(.system(size: 46, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 4)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, showsChrome ? 280 : 80)
                    .allowsHitTesting(false)
            }

            if playback.isLoading {
                ProgressView().scaleEffect(1.6)
            }

            if let error = playback.error {
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 60))
                    Text(error).font(.title3).multilineTextAlignment(.center)
                    Button("إغلاق") { close() }
                }
                .padding(60)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
            }

            // Takes the remote's presses while the controls are hidden.
            Button { revealChrome() } label: { Color.clear }
                .buttonStyle(.plain)
                .focused($focus, equals: .surface)
                .opacity(showsChrome ? 0 : 1)
                .disabled(showsChrome)

            if showsChrome, playback.error == nil {
                chrome
                    .transition(.opacity)
            }
        }
        .onPlayPauseCommand {
            playback.togglePlayPause()
            revealChrome()
        }
        .onMoveCommand { direction in
            guard !showsChrome else { scheduleHide(); return }
            switch direction {
            case .left: playback.skip(-10)
            case .right: playback.skip(10)
            default: revealChrome()
            }
        }
        .onExitCommand {
            if showsChrome, playback.isPlaying {
                hideChrome()
            } else {
                close()
            }
        }
        .task {
            await playback.start(client: client, item: item, resume: resume)
            scheduleHide()
        }
        .onDisappear { playback.stop() }
        .animation(.easeInOut(duration: 0.25), value: showsChrome)
    }

    // MARK: - Controls

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                if let series = item.seriesTitle, item.kind == .episode {
                    Text(series).font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(item.episodeLabel.map { "\($0) · \(item.title)" } ?? item.title)
                    .font(.system(size: 44, weight: .bold))
                    .lineLimit(1)
                Text(playback.sourceLine)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white)
                            .frame(width: proxy.size.width * playback.progress)
                    }
                }
                .frame(height: 10)
                HStack {
                    Text(MSFormat.clock(playback.currentTime))
                    Spacer()
                    Text("-" + MSFormat.clock(max(playback.duration - playback.currentTime, 0)))
                }
                .font(.system(size: 24, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 60)
                }
                .focused($focus, equals: .playPause)

                Button { playback.skip(-10) } label: { Image(systemName: "gobackward.10") }
                Button { playback.skip(10) } label: { Image(systemName: "goforward.10") }

                audioMenu.focused($focus, equals: .audio)
                subtitleMenu.focused($focus, equals: .subtitles)
                aiMenu.focused($focus, equals: .ai)
                speedMenu

                if let status = playback.aiStatus {
                    Text(status).font(.system(size: 22)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 60)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 520)
                .ignoresSafeArea()
        }
        .onAppear { focus = .playPause }
        .onChange(of: focus) { _, _ in scheduleHide() }
    }

    private var audioMenu: some View {
        Menu {
            ForEach(playback.audioTracks, id: \.id) { track in
                Button {
                    playback.selectAudio(track.id)
                } label: {
                    if track.id == playback.activeAudio {
                        Label(Self.trackName(track), systemImage: "checkmark")
                    } else {
                        Text(Self.trackName(track))
                    }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2")
        }
    }

    private var subtitleMenu: some View {
        Menu {
            Button("بدون ترجمة") { playback.clearSubtitles() }
            ForEach(playback.subtitleTracks, id: \.id) { track in
                Button(Self.trackName(track)) { playback.selectSubtitle(track.id) }
            }
            ForEach(playback.sidecars) { ref in
                Button(ref.title) { playback.selectSidecar(ref) }
            }
        } label: {
            Image(systemName: "captions.bubble")
        }
    }

    private var aiMenu: some View {
        Menu {
            if !MSAISettings.isConfigured {
                Text("أضف مفتاح الذكاء الاصطناعي من الإعدادات")
            } else if playback.translatableSubtitles.isEmpty {
                Text("لا توجد ترجمة نصية لهذا المصدر")
            } else {
                ForEach(playback.translatableSubtitles) { ref in
                    Button("ترجمة \(ref.title) بالذكاء الاصطناعي") { playback.translateWithAI(ref) }
                }
                if playback.aiTranslation.isActive {
                    Button("إيقاف ترجمة الذكاء الاصطناعي", role: .destructive) { playback.stopAI() }
                }
            }
        } label: {
            Label("AI", systemImage: "translate")
        }
    }

    /// Playback speed, as in KSPlayer and most IPTV players.
    private var speedMenu: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                Button {
                    playback.setRate(Float(rate))
                } label: {
                    if Float(rate) == playback.rate {
                        Label(Self.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(Self.rateLabel(Double(playback.rate)))
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
        }
    }

    static func rateLabel(_ rate: Double) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }

    static func trackName(_ track: TrackInfo) -> String {
        let language = track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        let parts = [language, track.name.isEmpty ? nil : track.name, track.codec.uppercased()]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Chrome timing

    private func revealChrome() {
        showsChrome = true
        focus = .playPause
        scheduleHide()
    }

    private func hideChrome() {
        hideTask?.cancel()
        showsChrome = false
        focus = .surface
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, playback.isPlaying else { return }
            hideChrome()
        }
    }

    private func close() {
        playback.stop()
        dismiss()
    }
}

/// The engine and the state the controls read. Clock ticks are sampled at
/// 4 Hz so the screen redraws only as often as a viewer can see.
@MainActor
@Observable
final class TVExternalPlayback {
    struct Subtitles {
        let ass: ASSSubtitleSession
        let hold: SubtitleCueHold
    }

    private(set) var engine: AetherEngine?
    private(set) var subtitles: Subtitles?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isLoading = true
    private(set) var error: String?
    private(set) var audioTracks: [TrackInfo] = []
    private(set) var subtitleTracks: [TrackInfo] = []
    private(set) var activeAudio: Int?
    private(set) var sidecars: [MSSubtitleRef] = []
    private(set) var translatableSubtitles: [MSSubtitleRef] = []
    private(set) var sourceLine = ""
    let aiTranslation = MSAISubtitleTranslation()
    private(set) var aiLine: String?
    private(set) var rate: Float = 1

    private var client: (any MediaServerClient)?
    private var item: MSItem?
    private var cancellables: Set<AnyCancellable> = []
    private var lastSaved: Double = 0
    private var stopped = false

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var aiStatus: String? {
        switch aiTranslation.phase {
        case .idle, .ready: nil
        case .loading: "جارٍ تحميل الترجمة…"
        case .translating(let done, let total): "ترجمة AI \(done)/\(total)"
        case .failed(let message): message
        }
    }

    func start(client: any MediaServerClient, item: MSItem, resume: Bool) async {
        self.client = client
        self.item = item
        do {
            let engine = try AetherEngine()
            let ass = ASSSubtitleSession(engine: engine)
            let hold = SubtitleCueHold()
            ass.cueHold = hold
            self.engine = engine
            subtitles = Subtitles(ass: ass, hold: hold)
            observe(engine)

            let stream = try await client.directStream(for: item)
            sidecars = stream.subtitles.filter { !$0.isEmbedded }
            translatableSubtitles = stream.subtitles
            sourceLine = Self.describe(client.account, stream.info)
            let start = resume ? item.resumePosition : 0
            try await engine.load(url: stream.url, startPosition: start > 5 ? start : nil)
            guard !stopped else { return }
            engine.setExternalMetadata(Self.metadata(item))
            engine.play()
            isLoading = false
            Task { await client.reportStart(item) }
        } catch {
            isLoading = false
            self.error = error.msMessage
        }
    }

    private func observe(_ engine: AetherEngine) {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.isPlaying = state == .playing
                if state == .ended { self.finish() }
            }
            .store(in: &cancellables)
        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.duration = $0 }
            .store(in: &cancellables)
        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.audioTracks = $0 }
            .store(in: &cancellables)
        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in self?.subtitleTracks = tracks.filter { !$0.isExternal } }
            .store(in: &cancellables)
        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.activeAudio = $0 }
            .store(in: &cancellables)
        engine.clock.$currentTime
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] time in self?.tick(time) }
            .store(in: &cancellables)
    }

    private func tick(_ time: Double) {
        currentTime = time
        aiLine = aiTranslation.isActive ? aiTranslation.text(at: time) : nil
        // A resume point every 15 seconds of play, so a crash loses little.
        if abs(time - lastSaved) >= 15, isPlaying {
            lastSaved = time
            saveProgress()
        }
    }

    // MARK: - Commands

    func togglePlayPause() { engine?.togglePlayPause() }

    func skip(_ seconds: Double) {
        guard let engine else { return }
        let target = min(max(currentTime + seconds, 0), max(duration - 1, 0))
        Task { await engine.seek(to: target) }
    }

    func selectAudio(_ index: Int) { engine?.selectAudioTrack(index: index) }

    func setRate(_ value: Float) {
        rate = value
        engine?.setRate(value)
    }

    func selectSubtitle(_ index: Int) {
        stopAI()
        engine?.selectSubtitleTrack(index: index)
    }

    func selectSidecar(_ ref: MSSubtitleRef) {
        stopAI()
        engine?.selectSidecarSubtitle(url: ref.url)
    }

    func clearSubtitles() {
        stopAI()
        engine?.clearSubtitle()
    }

    func translateWithAI(_ ref: MSSubtitleRef) {
        engine?.clearSubtitle()
        aiTranslation.start(ref, from: currentTime)
    }

    func stopAI() {
        aiTranslation.stop()
        aiLine = nil
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        saveProgress()
        aiTranslation.stop()
        engine?.stop()
        cancellables.removeAll()
    }

    private func finish() {
        guard let client, let item else { return }
        Task { try? await client.setWatched(true, item: item) }
    }

    private func saveProgress() {
        guard let client, let item, currentTime > 5 else { return }
        let position = currentTime
        let total = duration > 0 ? duration : (item.duration ?? 0)
        Task {
            if total > 0, position / total >= 0.9 {
                try? await client.setWatched(true, item: item)
            } else {
                try? await client.saveResume(item, position: position)
            }
        }
    }

    // MARK: - Labels

    static func describe(_ account: MediaServerAccount, _ info: MSMediaInfo?) -> String {
        var parts = [account.kind.displayName, account.serverName]
        if let info {
            parts += [info.resolution, info.dynamicRange, info.videoCodec?.uppercased(), info.audioCodec?.uppercased()]
                .compactMap { $0 }
        }
        return parts.joined(separator: " · ")
    }

    static func metadata(_ item: MSItem) -> [AVMetadataItem] {
        func entry(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let metadata = AVMutableMetadataItem()
            metadata.identifier = id
            metadata.value = value as NSString
            metadata.extendedLanguageTag = "und"
            return metadata.copy() as! AVMetadataItem
        }
        var items = [entry(.commonIdentifierTitle, item.title)]
        if let overview = item.overview { items.append(entry(.commonIdentifierDescription, overview)) }
        return items
    }
}

extension MediaServerClient {
    /// Lets the server show the title as playing where it supports it.
    func reportStart(_ item: MSItem) async {}
}
#endif
