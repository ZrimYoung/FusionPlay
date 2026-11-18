import AVFAudio
import SwiftUI
import UIKit

private final class ReceiverEvents: StateListener, @unchecked Sendable {
    weak var model: ReceiverModel?
    let generation: UInt64

    init(model: ReceiverModel, generation: UInt64) {
        self.model = model
        self.generation = generation
    }

    func onState(state: Snapshot) {
        DispatchQueue.main.async { [weak model, generation] in
            model?.receive(state, generation: generation)
        }
    }
}

@MainActor
final class ReceiverModel: ObservableObject {
    static let syncAdjustmentRange = -200...200

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var lyrics = LyricsDocument("")
    @Published private(set) var lyricsLoading = false
    @Published private(set) var initialized = false
    @Published private(set) var busy = false
    // Read the launch preference once. Foreground transitions use the current intent.
    @Published private(set) var wantsReceiving =
        UserDefaults.standard.object(forKey: "autoStartReceiver") as? Bool ?? true
    @Published private(set) var error = ""
    @Published private(set) var controlMessage = ""
    @Published private(set) var syncAdjustment = 0
    @Published private(set) var syncAdjustmentBusy = false
    @Published private(set) var syncAdjustmentError = ""
    @Published private(set) var name = UserDefaults.standard.string(forKey: "receiverName")
        ?? (UIDevice.current.userInterfaceIdiom == .pad ? "FusionPlay-iPad" : "FusionPlay-iPhone")

    @Published private var timeline = PlaybackTimeline()
    @Published private var volumeState = VolumeInteraction()
    @Published private var controlBusy = false
    private var currentControl: UUID?
    private var systemCommandTask: UIBackgroundTaskIdentifier = .invalid
    private var receiver: Receiver?
    private var subscription: UInt64?
    private let backend = DispatchQueue(label: "tech.zrim.fusionplay.ios.receiver", qos: .userInitiated)
    private var foreground = false
    private var playedInCurrentSession = false
    private var backgroundGrace: (length: Duration, task: Task<Void, Never>)?
    @Published private var interrupted = false
    private var runningName: String?
    private var generation: UInt64 = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var audioSessionActive = false
    private var audioSessionRelease: Task<Void, Never>?
    private var seekTimeout: Task<Void, Never>?
    private var volumeTimeout: Task<Void, Never>?
    private var metadataKey: TrackKey?
    private var requestedArtwork: ArtworkRequest?
    private var loadedArtwork: ArtworkRequest?
    private var artworkTask: Task<Void, Never>?
    private var artworkGraceTask: Task<Void, Never>?
    private var lyricsSource = ""
    private var lyricsTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private lazy var systemMedia = SystemMediaController(
        seek: { [weak self] request in self?.handleSystemSeek(request) },
        send: { [weak self] command in self?.control(command, fromSystem: true) }
    )

    private struct TrackKey: Equatable {
        let id: String
        let fallbackTitle: String
        init(_ state: Snapshot) {
            id = state.trackId
            fallbackTitle = id.isEmpty ? state.title : ""
        }
    }

    private struct ArtworkRequest: Equatable {
        let track: TrackKey
        let source: String

        init(_ state: Snapshot) {
            track = TrackKey(state)
            source = state.artworkUrl
        }
    }

    init() {
        prepare()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let mayResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            Task { @MainActor [weak self] in
                self?.handleInterruption(type, mayResume: mayResume)
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        audioSessionRelease?.cancel()
        let token = subscription
        let releaseAudioSession = audioSessionActive
        if let receiver {
            backend.async {
                if let token { receiver.unsubscribe(token: token) }
                receiver.stop()
                if releaseAudioSession {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }
    }

    var volume: Double { volumeState.value }
    var displayedPositionMs: UInt64? { timeline.displayPosition(now: ProcessInfo.processInfo.systemUptime) }
    private var hasRemoteControlSession: Bool {
        wantsReceiving && !interrupted && !busy && snapshot?.controlsAvailable == true
            && (foreground || canContinueBackgroundPlayback)
    }
    var canControl: Bool { hasRemoteControlSession && !controlBusy }
    var canSeek: Bool { canControl && timeline.source?.canSeek == true }

    private var canContinueBackgroundPlayback: Bool {
        guard playedInCurrentSession, let snapshot else { return false }
        if snapshot.phase == .ready { return true }
        guard snapshot.controlsAvailable else { return false }
        return snapshot.phase == .playing || snapshot.phase == .paused || snapshot.phase == .connected
    }

    var statusText: String {
        if !error.isEmpty { return String(localized: "需要处理") }
        if busy { return String(localized: "正在更新接收器…") }
        if interrupted { return String(localized: "系统音频已中断") }
        switch snapshot?.phase {
        case .starting: return String(localized: "正在启动接收…")
        case .ready: return String(localized: "等待投送")
        case .connected: return String(localized: "已连接")
        case .playing: return String(localized: "正在播放")
        case .paused: return String(localized: "已暂停")
        case .failed: return String(localized: "接收失败")
        default: return String(localized: "接收已停止")
        }
    }

    private var displayMetadata: DisplayMetadata? {
        guard let snapshot else { return nil }
        return DisplayMetadata(snapshot, correctLyricTitles: UserDefaults.standard.bool(forKey: "uiCorrectLyricTitles"))
    }

    var displayTitle: String {
        if let title = displayMetadata?.title, !title.isEmpty { return title }
        return snapshot?.controlsAvailable == true ? String(localized: "手机正在投送") : String(localized: "等待你的音乐")
    }

    var displaySubtitle: String {
        guard let displayMetadata else { return "" }
        return [displayMetadata.artist, displayMetadata.album].filter { !$0.isEmpty }.joined(separator: " - ")
    }

    func start() {
        interrupted = false
        wantsReceiving = true
        error = ""
        if receiver == nil { prepare() }
        else { reconcile() }
    }

    func stop() {
        wantsReceiving = false
        error = ""
        reconcile()
    }

    func saveName(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...63).contains(trimmed.utf8.count),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            error = String(localized: "设备名称为空、过长或包含控制字符。")
            return
        }
        guard trimmed != name else { return }
        name = trimmed
        UserDefaults.standard.set(trimmed, forKey: "receiverName")
        error = ""
        reconcile()
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active, snapshot?.controlsAvailable != true { playedInCurrentSession = false }
        reconcile()
        if snapshot != nil { publishSystemMedia() }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, mayResume: Bool) {
        switch type {
        case .began:
            guard audioSessionActive else { return }
            interrupted = true
        case .ended:
            guard interrupted else { return }
            interrupted = false
            if !mayResume { wantsReceiving = false }
        @unknown default:
            return
        }
        reconcile()
    }

    private func prepare() {
        guard !busy, receiver == nil else { return }
        busy = true
        backend.async { [weak self] in
            let result = Result {
                let base = try FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                )
                var data = base.appendingPathComponent("FusionPlay", isDirectory: true)
                try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try data.setResourceValues(values)
                let receiver = try Receiver(dataDirectory: data.path)
                return (receiver, Result { try receiver.syncAdjustment() })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let (receiver, adjustment)):
                    self.receiver = receiver
                    switch adjustment {
                    case .success(let millis):
                        self.syncAdjustment = Int(millis)
                    case .failure:
                        self.syncAdjustmentError = String(localized: "无法读取同步微调。")
                    }
                    self.initialized = true
                    self.volumeState.observe(Double(receiver.settings().volume))
                case .failure(let error):
                    self.wantsReceiving = false
                    self.error = String(describing: error)
                }
                self.reconcile()
            }
        }
    }

    private func reconcile() {
        let target: String?
        if wantsReceiving && !interrupted {
            // Only the foreground starts discovery. A background transition
            // may keep the same receiver if its media session has played audio.
            target = foreground ? name : (canContinueBackgroundPlayback ? runningName : nil)
        } else {
            target = nil
        }
        updateBackgroundGrace(keepingReceiver: !foreground && target != nil)
        if !foreground, target == nil, runningName != nil || busy {
            beginBackgroundCleanup()
        }
        guard !busy else { return }
        guard let receiver else { endBackgroundCleanup(); return }
        guard target != runningName else { endBackgroundCleanup(); return }
        busy = true
        generation &+= 1
        let nextGeneration = generation
        let previous = subscription
        subscription = nil
        snapshot = nil
        playedInCurrentSession = false
        audioSessionRelease?.cancel()
        audioSessionRelease = nil
        let releaseAudioSession = audioSessionActive
        audioSessionActive = false
        clearMedia()
        let startSettings = target.map {
            Settings(name: $0, interfaceName: "", outputDevice: "", volume: UInt32(volume.rounded()))
        }
        let listener = ReceiverEvents(model: self, generation: nextGeneration)
        backend.async { [weak self] in
            if let previous { receiver.unsubscribe(token: previous) }
            receiver.stop()
            let session = AVAudioSession.sharedInstance()
            if releaseAudioSession {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            let result = Result<UInt64?, Error> {
                guard let startSettings else { return nil }
                // Configure the output for CPAL before opening the listener.
                // Activation waits for a phone to establish a playback route.
                try session.setCategory(.playback, mode: .default)
                try receiver.start(settings: startSettings)
                return receiver.subscribe(listener: listener)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if case .success(let token) = result, let token {
                        receiver.unsubscribe(token: token)
                        selfStop(receiver)
                    }
                    return
                }
                self.busy = false
                switch result {
                case .success(let token):
                    self.subscription = token
                    self.runningName = target
                    if token != nil { self.receive(receiver.snapshot(), generation: nextGeneration) }
                case .failure(let error):
                    self.runningName = nil
                    self.wantsReceiving = false
                    self.error = String(describing: error)
                }
                self.reconcile()
            }
        }
    }

    private func updateBackgroundGrace(keepingReceiver: Bool) {
        let length: Duration?
        if keepingReceiver, let phase = snapshot?.phase, phase != .playing, phase != .paused {
            // RTSP may briefly close while the phone opens the next track.
            // Only a previously playing cast gets this short route handoff.
            length = .seconds(phase == .ready ? 2 : 30)
        } else {
            length = nil
        }
        guard backgroundGrace?.length != length else { return }
        backgroundGrace?.task.cancel()
        guard let length else {
            backgroundGrace = nil
            return
        }
        backgroundGrace = (length, Task { [weak self] in
            do { try await Task.sleep(for: length) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.backgroundGrace = nil
            guard !self.foreground, self.snapshot?.phase != .playing else { return }
            self.playedInCurrentSession = false
            self.reconcile()
        })
    }

    private func beginBackgroundCleanup() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Stop FusionPlay receiver") { [weak self] in
            Task { @MainActor [weak self] in self?.endBackgroundCleanup() }
        }
    }

    private func endBackgroundCleanup() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func prepareAudioSession(for state: Snapshot) -> Bool {
        if state.controlsAvailable && (state.phase == .connected || state.phase == .playing || state.phase == .paused) {
            audioSessionRelease?.cancel()
            audioSessionRelease = nil
            if !audioSessionActive {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    audioSessionActive = true
                } catch {
                    self.error = error.localizedDescription
                    wantsReceiving = false
                    reconcile()
                    return false
                }
            }
        } else if foreground, state.phase == .ready, audioSessionActive, audioSessionRelease == nil {
            // The phone can replace its media route between tracks.
            audioSessionRelease = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                self.audioSessionRelease = nil
                guard !Task.isCancelled, self.snapshot?.phase == .ready, self.audioSessionActive else { return }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.audioSessionActive = false
            }
        }
        return true
    }

    fileprivate func receive(_ state: Snapshot, generation: UInt64) {
        guard generation == self.generation, runningName != nil, !interrupted else { return }
        if snapshot != state { snapshot = state }
        guard prepareAudioSession(for: state) else { return }
        if state.controlsAvailable, state.phase == .playing {
            playedInCurrentSession = true
        } else if !state.controlsAvailable, foreground || state.phase != .ready {
            playedInCurrentSession = false
        }
        volumeState.observe(Double(state.volume))
        timeline.observe(PlaybackObservation(trackID: state.trackId, title: state.title, duration: state.durationMs,
            position: state.positionMs, connected: state.controlsAvailable, playing: state.phase == .playing),
            now: ProcessInfo.processInfo.systemUptime)
        let artworkChanged = updateMetadata(state)
        publishSystemMedia(force: artworkChanged)
        if state.phase == .failed {
            error = state.message.isEmpty ? String(localized: "接收失败") : state.message
            wantsReceiving = false
        }
        if !foreground || state.phase == .failed { reconcile() }
    }

    private func clearMedia() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkGraceTask?.cancel()
        artworkGraceTask = nil
        requestedArtwork = nil
        loadedArtwork = nil
        lyricsTask?.cancel()
        seekTimeout?.cancel()
        volumeTimeout?.cancel()
        metadataKey = nil
        lyricsSource = ""
        lyrics = LyricsDocument("")
        lyricsLoading = false
        artwork = nil
        timeline = PlaybackTimeline()
        currentControl = nil
        controlBusy = false
        controlMessage = ""
        systemMedia.clear()
        endSystemCommandTask()
    }

    private func updateMetadata(_ state: Snapshot) -> Bool {
        guard state.controlsAvailable else {
            if metadataKey != nil { clearMedia() }
            return false
        }
        let key = TrackKey(state)
        if metadataKey != key {
            metadataKey = key
            controlMessage = ""
            lyricsTask?.cancel()
            lyricsSource = ""
            lyrics = LyricsDocument("")
            lyricsLoading = false
        }
        if state.lyricsText != lyricsSource {
            lyricsSource = state.lyricsText
            lyricsTask?.cancel()
            let source = lyricsSource
            lyricsLoading = !source.isEmpty
            if source.isEmpty { lyrics = LyricsDocument("") }
            else {
                lyricsTask = Task { [weak self] in
                    let document = await Task.detached(priority: .utility) { LyricsDocument(source) }.value
                    guard !Task.isCancelled, let self, self.metadataKey == key, self.lyricsSource == source else { return }
                    self.lyrics = document
                    self.lyricsLoading = false
                }
            }
        }
        return updateArtwork(ArtworkRequest(state))
    }

    private func updateArtwork(_ request: ArtworkRequest) -> Bool {
        guard requestedArtwork != request else { return false }
        requestedArtwork = request
        artworkTask?.cancel()
        artworkTask = nil
        if loadedArtwork == request {
            artworkGraceTask?.cancel()
            artworkGraceTask = nil
            return true
        }

        // Keep the outgoing image on the player while the next track sends
        // its artwork. One deadline covers the entire gap, including empty
        // updates and successive changes to the requested URL.
        if artwork != nil, artworkGraceTask == nil {
            artworkGraceTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.artworkGraceTask = nil
                self.loadedArtwork = nil
                self.artwork = nil
            }
        }
        guard !request.source.isEmpty else { return true }
        artworkTask = Task { [weak self] in
            let image = try? await ArtworkLoader.load(request.source)
            guard !Task.isCancelled, let self, self.requestedArtwork == request else { return }
            self.artworkTask = nil
            guard let image, let state = self.snapshot, state.controlsAvailable,
                  ArtworkRequest(state) == request else { return }
            self.artworkGraceTask?.cancel()
            self.artworkGraceTask = nil
            self.loadedArtwork = request
            let decoded = UIImage(cgImage: image)
            self.artwork = decoded
            self.publishSystemMedia(force: true)
        }
        return true
    }

    private func systemArtwork(for state: Snapshot) -> UIImage? {
        // Control Center must not associate the temporarily displayed
        // outgoing picture with the new track or a different artwork URL.
        guard state.controlsAvailable, loadedArtwork == ArtworkRequest(state),
              loadedArtwork == requestedArtwork else { return nil }
        return artwork
    }

    func refreshDisplayPresentation() { publishSystemMedia() }

    private func publishSystemMedia(force: Bool = false) {
        guard let state = snapshot, audioSessionActive, wantsReceiving, !interrupted else {
            systemMedia.clear()
            return
        }
        systemMedia.update(state, busy: !hasRemoteControlSession,
                           artwork: systemArtwork(for: state), force: force,
                           canSeek: hasRemoteControlSession && timeline.source?.canSeek == true)
    }

    private func handleSystemSeek(_ request: MediaSeekRequest) {
        guard let snapshot, MediaSeekTrack(snapshot) == request.track else { return }
        seek(to: request.positionMs, fromSystem: true)
    }

    func togglePlayback() { control(snapshot?.phase == .playing ? .pause : .play) }

    func control(_ command: PlaybackCommand, fromSystem: Bool = false) {
        submitControl(fromSystem: fromSystem) { try $0.control(command: command) }
    }

    func seek(to value: UInt64) { seek(to: value, fromSystem: false) }

    private func seek(to value: UInt64, fromSystem: Bool) {
        guard canSeek, let state = snapshot, let duration = state.durationMs else { return }
        let position = min(value, duration)
        guard let token = timeline.begin(target: position, now: ProcessInfo.processInfo.systemUptime) else { return }
        seekTimeout?.cancel()
        seekTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(PlaybackTimeline.timeout)) } catch { return }
            guard let self, self.timeline.expire(token, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.controlMessage = String(localized: "手机尚未确认跳转")
        }
        submitControl(seekToken: token, fromSystem: fromSystem) {
            try $0.seek(positionMs: position, expectedTrackId: state.trackId, expectedTitle: state.title)
        }
    }

    private func submitControl(seekToken: UInt64? = nil, fromSystem: Bool,
                               _ action: @escaping @Sendable (Receiver) throws -> CommandOutcome) {
        guard canControl, let receiver else { return }
        controlBusy = true
        controlMessage = ""
        let id = UUID()
        currentControl = id
        if fromSystem {
            systemCommandTask = UIApplication.shared.beginBackgroundTask(withName: "Finish FusionPlay media command") { [weak self] in
                Task { @MainActor [weak self] in self?.endSystemCommandTask() }
            }
        }
        backend.async { [weak self] in
            let result = Result { try action(receiver) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentControl == id else { return }
                self.currentControl = nil
                self.controlBusy = false
                let dispatched = (try? result.get()).map { $0.dispatched || $0.confirmed } ?? false
                if let seekToken { self.timeline.complete(seekToken, dispatched: dispatched) }
                if !dispatched { self.controlMessage = String(localized: "发送控制指令失败") }
                self.receive(receiver.snapshot(), generation: self.generation)
                self.endSystemCommandTask()
            }
        }
    }

    private func endSystemCommandTask() {
        guard systemCommandTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(systemCommandTask)
        systemCommandTask = .invalid
    }

    func setSyncAdjustment(_ millis: Int) {
        guard let receiver, !busy, !syncAdjustmentBusy,
              Self.syncAdjustmentRange.contains(millis),
              millis != syncAdjustment || !syncAdjustmentError.isEmpty else { return }
        syncAdjustmentBusy = true
        syncAdjustmentError = ""
        backend.async { [weak self] in
            let result = Result { try receiver.setSyncAdjustment(millis: Int32(millis)) }
            let stored: Int?
            if case .failure = result {
                stored = (try? receiver.syncAdjustment()).map(Int.init)
            } else {
                stored = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.syncAdjustment = millis
                case .failure:
                    if let stored { self.syncAdjustment = stored }
                    self.syncAdjustmentError = String(localized: "无法保存同步微调。")
                }
                self.syncAdjustmentBusy = false
            }
        }
    }

    func setVolume(_ value: Double) {
        guard let receiver, !busy, value.isFinite else { return }
        volumeState.edit(value)
        let change = volumeState.submit()
        volumeTimeout?.cancel()
        backend.async { [weak self] in
            let result = Result { try receiver.setVolume(volume: change.value) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.volumeState.complete(change.token, succeeded: (try? result.get()) != nil) else { return }
                if self.runningName != nil {
                    self.receive(receiver.snapshot(), generation: self.generation)
                } else {
                    self.volumeState.observe(Double(receiver.settings().volume))
                }
                if case .failure = result {
                    self.controlMessage = String(localized: "设置音量失败")
                }
                self.volumeTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self?.volumeState.expire(change.token)
                }
            }
        }
    }
}

private func selfStop(_ receiver: Receiver) {
    DispatchQueue.global(qos: .userInitiated).async {
        receiver.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
