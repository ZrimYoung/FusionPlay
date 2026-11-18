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
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var lyrics = LyricsDocument("")
    @Published private(set) var lyricsLoading = false
    @Published private(set) var initialized = false
    @Published private(set) var busy = false
    @Published private(set) var wantsReceiving = false
    @Published private(set) var error = ""
    @Published private(set) var controlMessage = ""
    @Published private(set) var name = UserDefaults.standard.string(forKey: "receiverName")
        ?? (UIDevice.current.userInterfaceIdiom == .pad ? "FusionPlay-iPad" : "FusionPlay-iPhone")

    @Published private var timeline = PlaybackTimeline()
    @Published private var volumeState = VolumeInteraction()
    @Published private var controlBusy = false
    private var currentControl: UUID?
    private var receiver: Receiver?
    private var subscription: UInt64?
    private let backend = DispatchQueue(label: "tech.zrim.fusionplay.ios.receiver", qos: .userInitiated)
    private var foreground = false
    @Published private var interrupted = false
    private var runningName: String?
    private var generation: UInt64 = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var seekTimeout: Task<Void, Never>?
    private var volumeTimeout: Task<Void, Never>?
    private var metadataKey: TrackKey?
    private var artworkSource = ""
    private var lyricsSource = ""
    private var artworkTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private let metadata = DisplayMetadataCache()
    private lazy var systemMedia = SystemMediaController { [weak self] command in self?.control(command) }

    private struct TrackKey: Equatable {
        let id: String
        let fallbackTitle: String
        init(_ state: Snapshot) {
            id = state.trackId
            fallbackTitle = id.isEmpty ? state.title : ""
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
        let token = subscription
        if let receiver {
            backend.async {
                if let token { receiver.unsubscribe(token: token) }
                receiver.stop()
            }
        }
    }

    var volume: Double { volumeState.value }
    var displayedPositionMs: UInt64? { timeline.displayPosition(now: ProcessInfo.processInfo.systemUptime) }
    var canControl: Bool { snapshot?.controlsAvailable == true && foreground && !busy && !controlBusy }
    var canSeek: Bool { canControl && timeline.source?.canSeek == true }

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
        if UserDefaults.standard.bool(forKey: "uiCorrectLyricTitles") {
            return metadata.resolve(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, lyricsText: snapshot.lyricsText)
        }
        return DisplayMetadata(title: snapshot.title, artist: snapshot.artist, album: snapshot.album)
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
        if !active, wantsReceiving || runningName != nil || busy {
            beginBackgroundCleanup()
        }
        reconcile()
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, mayResume: Bool) {
        interrupted = type == .began
        if type == .ended && !mayResume { wantsReceiving = false }
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
                return try Receiver(dataDirectory: data.path)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let receiver):
                    self.receiver = receiver
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
        guard !busy else { return }
        guard let receiver else { endBackgroundCleanup(); return }
        let target = wantsReceiving && foreground && !interrupted ? name : nil
        guard target != runningName else { endBackgroundCleanup(); return }
        busy = true
        generation &+= 1
        let nextGeneration = generation
        let previous = subscription
        subscription = nil
        snapshot = nil
        clearMedia()
        let startSettings = target.map {
            Settings(name: $0, interfaceName: "", outputDevice: "", volume: UInt32(volume.rounded()))
        }
        let listener = ReceiverEvents(model: self, generation: nextGeneration)
        backend.async { [weak self] in
            if let previous { receiver.unsubscribe(token: previous) }
            receiver.stop()
            let result = Result<UInt64?, Error> {
                guard let startSettings else {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    return nil
                }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                do {
                    try receiver.start(settings: startSettings)
                    return receiver.subscribe(listener: listener)
                } catch {
                    receiver.stop()
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                    throw error
                }
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

    fileprivate func receive(_ state: Snapshot, generation: UInt64) {
        guard generation == self.generation, runningName != nil, foreground, !interrupted else { return }
        if snapshot != state { snapshot = state }
        volumeState.observe(Double(state.volume))
        timeline.observe(PlaybackObservation(trackID: state.trackId, title: state.title, duration: state.durationMs,
            position: state.positionMs, connected: state.controlsAvailable, playing: state.phase == .playing),
            now: ProcessInfo.processInfo.systemUptime)
        updateMetadata(state)
        systemMedia.update(state, busy: controlBusy, artwork: artworkSource == state.artworkUrl ? artwork : nil)
        if state.phase == .failed {
            error = state.message.isEmpty ? String(localized: "接收失败") : state.message
            wantsReceiving = false
            reconcile()
        }
    }

    private func clearMedia() {
        artworkTask?.cancel()
        lyricsTask?.cancel()
        seekTimeout?.cancel()
        volumeTimeout?.cancel()
        metadataKey = nil
        artworkSource = ""
        lyricsSource = ""
        lyrics = LyricsDocument("")
        lyricsLoading = false
        artwork = nil
        timeline = PlaybackTimeline()
        currentControl = nil
        controlBusy = false
        controlMessage = ""
        metadata.reset()
        systemMedia.clear()
    }

    private func updateMetadata(_ state: Snapshot) {
        guard state.controlsAvailable else {
            if metadataKey != nil { clearMedia() }
            return
        }
        let key = TrackKey(state)
        if metadataKey != key {
            metadataKey = key
            metadata.reset()
            controlMessage = ""
            artworkTask?.cancel()
            lyricsTask?.cancel()
            artworkSource = ""
            lyricsSource = ""
            artwork = nil
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
        if state.artworkUrl != artworkSource {
            artworkSource = state.artworkUrl
            artworkTask?.cancel()
            artwork = nil
            let source = artworkSource
            guard !source.isEmpty else { return }
            artworkTask = Task { [weak self] in
                guard let image = try? await ArtworkLoader.load(source),
                      !Task.isCancelled, let self, self.metadataKey == key, self.artworkSource == source else { return }
                let decoded = UIImage(cgImage: image)
                withAnimation(.easeInOut(duration: 0.25)) { self.artwork = decoded }
                if let state = self.snapshot {
                    self.systemMedia.update(state, busy: self.controlBusy, artwork: decoded, force: true)
                }
            }
        }
    }

    func refreshDisplayPresentation() {
        guard foreground, !busy, let snapshot else { return }
        systemMedia.update(snapshot, busy: controlBusy, artwork: artworkSource == snapshot.artworkUrl ? artwork : nil)
    }

    func togglePlayback() { control(snapshot?.phase == .playing ? .pause : .play) }

    func control(_ command: PlaybackCommand) {
        submitControl { try $0.control(command: command) }
    }

    func seek(to value: UInt64) {
        guard canSeek, let state = snapshot, let duration = state.durationMs else { return }
        let position = min(value, duration)
        guard let token = timeline.begin(target: position, now: ProcessInfo.processInfo.systemUptime) else { return }
        seekTimeout?.cancel()
        seekTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(PlaybackTimeline.timeout)) } catch { return }
            guard let self, self.timeline.expire(token, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.controlMessage = String(localized: "手机尚未确认跳转")
        }
        submitControl(seekToken: token) {
            try $0.seek(positionMs: position, expectedTrackId: state.trackId, expectedTitle: state.title)
        }
    }

    private func submitControl(seekToken: UInt64? = nil, _ action: @escaping @Sendable (Receiver) throws -> CommandOutcome) {
        guard canControl, let receiver else { return }
        controlBusy = true
        controlMessage = ""
        let id = UUID()
        currentControl = id
        if let snapshot {
            systemMedia.update(snapshot, busy: true, artwork: artwork)
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
