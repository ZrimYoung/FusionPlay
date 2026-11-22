import AVFAudio
import Network
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

    enum ArtworkStatus: Equatable {
        case disconnected, missing, loading, retrying, loaded, failed

        var title: LocalizedStringKey {
            switch self {
            case .disconnected: "尚未连接"
            case .missing: "手机未提供封面"
            case .loading: "正在加载封面"
            case .retrying: "封面加载失败，正在重试"
            case .loaded: "封面已加载"
            case .failed: "封面加载失败"
            }
        }
    }

    struct LAN: Equatable {
        let name: String
        let address: String
    }

    private struct Listener: Equatable {
        let name: String
        let lan: LAN
    }

    @Published private(set) var lan: LAN?
    @Published private(set) var audioRouteName = ""
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var artworkStatus: ArtworkStatus = .disconnected
    @Published private(set) var lyrics = LyricsDocument("")
    @Published private(set) var lyricsLoading = false
    @Published private(set) var lyricsAvailable = false
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
    private var runningListener: Listener?
    private let networkMonitor = NWPathMonitor()
    private var networkRefresh: Task<Void, Never>?
    private var foregroundNetworkRefresh: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    private var routeIDs: [String] = []
    private var routeCheck: Task<Void, Never>?
    private var outputRecoveryUntil: ContinuousClock.Instant?
    private var needsOutputRestart = false
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
    private var lyricsHandoff: Task<Void, Never>?
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
        updateOutputRoute(checkPlayback: false)
        networkMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleNetworkRefresh() }
        }
        networkMonitor.start(queue: backend)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateOutputRoute() }
        }
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
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        networkMonitor.cancel()
        networkRefresh?.cancel()
        foregroundNetworkRefresh?.cancel()
        routeCheck?.cancel()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        audioSessionRelease?.cancel()
        artworkTask?.cancel()
        artworkGraceTask?.cancel()
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
        if !error.isEmpty { return ReceiverAppLanguage.text("需要处理") }
        if busy { return ReceiverAppLanguage.text("正在更新接收器…") }
        if interrupted { return ReceiverAppLanguage.text("系统音频已中断") }
        if wantsReceiving && lan == nil { return ReceiverAppLanguage.text("等待局域网") }
        switch snapshot?.phase {
        case .starting: return ReceiverAppLanguage.text("正在启动接收…")
        case .ready: return ReceiverAppLanguage.text("等待投送")
        case .connected: return ReceiverAppLanguage.text("已连接")
        case .playing: return ReceiverAppLanguage.text("正在播放")
        case .paused: return ReceiverAppLanguage.text("已暂停")
        case .failed: return ReceiverAppLanguage.text("接收失败")
        default: return ReceiverAppLanguage.text("接收已停止")
        }
    }

    private var displayMetadata: DisplayMetadata? {
        guard let snapshot else { return nil }
        return DisplayMetadata(snapshot, correctLyricTitles: UserDefaults.standard.bool(forKey: "uiCorrectLyricTitles"))
    }

    var displayTitle: String {
        if let title = displayMetadata?.title, !title.isEmpty { return title }
        return snapshot?.controlsAvailable == true ? ReceiverAppLanguage.text("手机正在投送") : ReceiverAppLanguage.text("等待你的音乐")
    }

    var displaySubtitle: String {
        guard let displayMetadata else { return "" }
        return [displayMetadata.artist, displayMetadata.album].filter { !$0.isEmpty }.joined(separator: " - ")
    }

    func start() {
        interrupted = false
        wantsReceiving = true
        error = ""
        refreshLAN()
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
            error = ReceiverAppLanguage.text("设备名称为空、过长或包含控制字符。")
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
        foregroundNetworkRefresh?.cancel()
        foregroundNetworkRefresh = nil
        if active {
            refreshLAN()
            updateOutputRoute()
            // DHCP can change the bound address without a different interface.
            foregroundNetworkRefresh = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self else { return }
                    self.refreshLAN()
                }
            }
        }
        reconcile()
        if snapshot != nil { publishSystemMedia() }
    }

    private func scheduleNetworkRefresh() {
        networkRefresh?.cancel()
        networkRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.refreshLAN()
        }
    }

    private func refreshLAN(reconcileChanges: Bool = true) {
        // Match the Rust listener selection, including a local network
        // without internet access.
        guard let interfaces = try? networkInterfaces() else { return }
        let available = interfaces.map { LAN(name: $0.name, address: $0.address) }
        // An added interface must not replace a still-working cast.
        let current = available.first { $0 == runningListener?.lan } ?? available.first
        guard current != lan else { return }
        lan = current
        if reconcileChanges { reconcile() }
    }

    private func updateOutputRoute(checkPlayback: Bool = true) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let names = outputs.map(\.portName).joined(separator: " · ")
        if audioRouteName != names { audioRouteName = names }
        let identifiers = outputs.map(\.uid)
        let hadRoute = !routeIDs.isEmpty
        guard routeIDs != identifiers else { return }
        routeIDs = identifiers
        routeCheck?.cancel()
        guard checkPlayback, hadRoute, audioSessionActive, !busy,
              let state = snapshot, state.controlsAvailable else { return }

        // Let RemoteIO follow the route as long as playback recovers normally.
        outputRecoveryUntil = ContinuousClock().now + .seconds(7)
        guard state.phase == .playing else { return }
        routeCheck = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, let current = self.snapshot, current.controlsAvailable,
                  current.phase == .connected, TrackKey(current) == TrackKey(state),
                  current.queueMs >= 100 else { return }
            self.retryChangedOutput()
        }
    }

    private func retryChangedOutput() {
        guard wantsReceiving, !interrupted, let deadline = outputRecoveryUntil,
              ContinuousClock().now < deadline else { return }
        outputRecoveryUntil = nil
        needsOutputRestart = true
        reconcile()
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
                        self.syncAdjustmentError = ReceiverAppLanguage.text("无法读取同步微调。")
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
        let target: Listener?
        if wantsReceiving, !interrupted, let lan {
            if foreground {
                target = Listener(name: name, lan: lan)
            } else if canContinueBackgroundPlayback, runningListener?.lan == lan, !needsOutputRestart {
                target = runningListener
            } else {
                target = nil
            }
        } else {
            target = nil
        }
        updateBackgroundGrace(keepingReceiver: !foreground && target != nil)
        if !foreground, target == nil, runningListener != nil || busy {
            beginBackgroundCleanup()
        }
        guard !busy else { return }
        guard let receiver else { endBackgroundCleanup(); return }
        guard target != runningListener || (target != nil && needsOutputRestart) else {
            endBackgroundCleanup()
            return
        }
        needsOutputRestart = false
        outputRecoveryUntil = nil
        routeCheck?.cancel()
        routeCheck = nil
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
        let listener = ReceiverEvents(model: self, generation: nextGeneration)
        backend.async { [weak self] in
            if let previous { receiver.unsubscribe(token: previous) }
            receiver.stop()
            let session = AVAudioSession.sharedInstance()
            if releaseAudioSession {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            let result = Result<UInt64?, Error> {
                guard let target else { return nil }
                // Read the committed volume after queued edits have finished.
                // The slider can still show a transient value from the phone.
                let settings = Settings(name: target.name, interfaceName: target.lan.name,
                                        outputDevice: "", volume: min(receiver.settings().volume, 100))
                // Configure the output for CPAL before opening the listener.
                // Activation waits for a phone to establish a playback route.
                try session.setCategory(.playback, mode: .default)
                try receiver.start(settings: settings)
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
                    self.runningListener = target
                    if token != nil { self.receive(receiver.snapshot(), generation: nextGeneration) }
                case .failure(let error):
                    self.runningListener = nil
                    self.refreshLAN(reconcileChanges: false)
                    if self.lan == target?.lan {
                        self.wantsReceiving = false
                        self.error = String(describing: error)
                    }
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
                    updateOutputRoute(checkPlayback: false)
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
        guard generation == self.generation, runningListener != nil, !interrupted else { return }
        let volumeChanged = snapshot?.volume != state.volume
        if snapshot != state { snapshot = state }
        guard prepareAudioSession(for: state) else { return }
        if volumeChanged, state.controlsAvailable, let receiver {
            backend.async { [weak self] in
                do { try receiver.rememberCurrentVolume() }
                catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, generation == self.generation else { return }
                        self.controlMessage = ReceiverAppLanguage.text("设置音量失败")
                    }
                }
            }
        }
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
            let previousLAN = lan
            refreshLAN(reconcileChanges: false)
            if previousLAN != lan {
                reconcile()
                return
            }
            if wantsReceiving, let deadline = outputRecoveryUntil, ContinuousClock().now < deadline {
                retryChangedOutput()
                return
            }
            error = state.message.isEmpty ? ReceiverAppLanguage.text("接收失败") : state.message
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
        artworkStatus = .disconnected
        lyricsTask?.cancel()
        lyricsTask = nil
        cancelLyricsHandoff()
        seekTimeout?.cancel()
        volumeTimeout?.cancel()
        metadataKey = nil
        lyricsSource = ""
        lyrics = LyricsDocument("")
        refreshLyricsPresentation()
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
        let changedTrack = metadataKey != key
        if changedTrack {
            metadataKey = key
            controlMessage = ""
        }
        updateLyrics(state.lyricsText, track: key, changedTrack: changedTrack)
        return updateArtwork(ArtworkRequest(state))
    }

    private func updateLyrics(_ source: String, track: TrackKey, changedTrack: Bool) {
        defer { refreshLyricsPresentation() }
        if changedTrack {
            lyricsTask?.cancel()
            lyricsTask = nil
            cancelLyricsHandoff()
            lyricsSource = ""
            lyrics = LyricsDocument("")
            if lyricsAvailable {
                // HyperOS can announce the track before sending its LRC.
                // Retain the pane without displaying the previous track's words.
                lyricsHandoff = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard !Task.isCancelled, let self, self.metadataKey == track else { return }
                    self.lyricsHandoff = nil
                    self.refreshLyricsPresentation()
                }
            }
        }

        guard source != lyricsSource else { return }
        lyricsSource = source
        lyricsTask?.cancel()
        lyricsTask = nil
        guard !source.isEmpty else {
            lyrics = LyricsDocument("")
            return
        }
        lyricsTask = Task { [weak self] in
            let document = await Task.detached(priority: .utility) { LyricsDocument(source) }.value
            guard !Task.isCancelled, let self, self.metadataKey == track, self.lyricsSource == source else { return }
            self.lyrics = document
            self.lyricsTask = nil
            if !document.lines.isEmpty { self.cancelLyricsHandoff() }
            self.refreshLyricsPresentation()
        }
    }

    private func cancelLyricsHandoff() {
        lyricsHandoff?.cancel()
        lyricsHandoff = nil
    }

    private func refreshLyricsPresentation() {
        let loading = lyricsTask != nil || lyricsHandoff != nil
        if lyricsLoading != loading { lyricsLoading = loading }
        let available = LyricsAutoVisibility.resolve(hasLyrics: !lyrics.lines.isEmpty, loading: loading,
                                                     previouslyVisible: lyricsAvailable)
        if lyricsAvailable != available { lyricsAvailable = available }
    }

    private func updateArtwork(_ request: ArtworkRequest) -> Bool {
        guard requestedArtwork != request else { return false }
        requestedArtwork = request
        artworkTask?.cancel()
        artworkTask = nil
        if loadedArtwork == request {
            artworkGraceTask?.cancel()
            artworkGraceTask = nil
            artworkStatus = .loaded
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
        if request.source.allSatisfy(\.isWhitespace) {
            artworkStatus = .missing
        } else {
            loadArtwork(request)
        }
        return true
    }

    var canReloadArtwork: Bool {
        guard artworkStatus == .loaded || artworkStatus == .failed,
              let state = snapshot, state.controlsAvailable,
              let requestedArtwork else { return false }
        return requestedArtwork == ArtworkRequest(state)
    }

    func reloadArtwork() {
        guard canReloadArtwork, let requestedArtwork else { return }
        loadArtwork(requestedArtwork)
    }

    private func loadArtwork(_ request: ArtworkRequest) {
        artworkStatus = .loading
        artworkTask = Task { [weak self] in
            for attempt in 1...3 {
                do {
                    let image = try await ArtworkLoader.load(request.source)
                    guard !Task.isCancelled, let self, self.requestedArtwork == request,
                          let state = self.snapshot, state.controlsAvailable,
                          ArtworkRequest(state) == request else { return }
                    self.artworkTask = nil
                    self.artworkGraceTask?.cancel()
                    self.artworkGraceTask = nil
                    self.loadedArtwork = request
                    self.artwork = UIImage(cgImage: image)
                    self.artworkStatus = .loaded
                    self.publishSystemMedia(force: true)
                    return
                } catch {
                    guard !Task.isCancelled, self?.requestedArtwork == request else { return }
                    guard attempt < 3, Self.shouldRetryArtwork(error) else {
                        self?.artworkTask = nil
                        self?.artworkStatus = .failed
                        return
                    }
                    self?.artworkStatus = .retrying
                    do { try await Task.sleep(for: .seconds(2 * attempt)) }
                    catch { return }
                }
            }
        }
    }

    private static func shouldRetryArtwork(_ error: Error) -> Bool {
        if let artworkError = error as? ArtworkError { return artworkError.retryable }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
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
            self.controlMessage = ReceiverAppLanguage.text("手机尚未确认跳转")
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
                if !dispatched { self.controlMessage = ReceiverAppLanguage.text("发送控制指令失败") }
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
                    self.syncAdjustmentError = ReceiverAppLanguage.text("无法保存同步微调。")
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
                if self.runningListener != nil {
                    self.receive(receiver.snapshot(), generation: self.generation)
                } else {
                    self.volumeState.observe(Double(receiver.settings().volume))
                }
                if case .failure = result {
                    self.controlMessage = ReceiverAppLanguage.text("设置音量失败")
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
