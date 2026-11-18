import SwiftUI
import UIKit

/// The same receiver stays active while the settings sheet is open or while
/// an iPad window switches between full width and Split View.
@MainActor
struct ReceiverRootView: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage("showLyrics") private var showLyrics = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showingSettings = false

    private var hasTrack: Bool {
        guard let state = model.snapshot, state.controlsAvailable else { return false }
        return state.phase == .playing || state.phase == .paused || !state.trackId.isEmpty
            || !state.title.isEmpty || (state.durationMs ?? 0) > 0
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let canUseColumns = width >= 740 && !dynamicTypeSize.isAccessibilitySize
            let gutter: CGFloat = canUseColumns ? 34 : 20
            ZStack {
                playerBackground
                VStack(spacing: 0) {
                    header.padding(.horizontal, gutter)
                    if hasTrack {
                        if canUseColumns && showLyrics {
                            HStack(alignment: .center, spacing: 28) {
                                ScrollView {
                                    player(coverLimit: min(370, width * 0.38))
                                        .frame(maxWidth: 460)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 22)
                                }
                                lyricsPane
                                    .frame(width: min(460, width * 0.42))
                                    .padding(.vertical, 22)
                            }
                            .padding(.horizontal, gutter)
                            .frame(maxWidth: 1_110)
                            .frame(maxWidth: .infinity)
                            .contentMargins(.bottom, 6, for: .scrollContent)
                        } else {
                            singleColumn(width: width, gutter: gutter)
                        }
                    } else {
                        ScrollView {
                            idleContent
                                .frame(maxWidth: 440)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: max(0, proxy.size.height - 112))
                                .padding(.horizontal, gutter)
                                .padding(.bottom, 22)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hasTrack)
        }
        .preferredColorScheme(.dark)
        .tint(PlayerPalette.accent)
        .sheet(isPresented: $showingSettings) { ReceiverSettingsView(model: model) }
    }

    private enum PlayerSection { case lyrics }

    private func singleColumn(width: CGFloat, gutter: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 24) {
                    player(coverLimit: min(410, max(0, width - 2 * gutter)))
                    if showLyrics {
                        lyricsPane.frame(height: 310).id(PlayerSection.lyrics)
                    }
                }
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, gutter)
                .padding(.vertical, 20)
            }
            .onChange(of: showLyrics) { _, shown in
                guard shown else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                    reader.scrollTo(PlayerSection.lyrics, anchor: .bottom)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                Text("FusionPlay")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.error.isEmpty ? (model.wantsReceiving ? PlayerPalette.accent : .secondary) : Color.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            if hasTrack {
                headerButton(showLyrics ? "quote.bubble.fill" : "quote.bubble", label: "显示歌词", selected: showLyrics) {
                    showLyrics.toggle()
                }
            }
            headerButton("gearshape", label: "接收设置") { showingSettings = true }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func headerButton(
        _ image: String,
        label: LocalizedStringKey,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(selected ? PlayerPalette.accent : Color.white.opacity(0.88))
                .frame(width: 44, height: 44)
                .background(.white.opacity(selected ? 0.12 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var playerBackground: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.17, blue: 0.20), PlayerPalette.background],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let artwork = hasTrack && !reduceTransparency ? model.artwork : nil {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 62)
                        .opacity(0.32)
                        .id(ObjectIdentifier(artwork))
                        .transition(.opacity)
                }
                LinearGradient(
                    colors: [PlayerPalette.background.opacity(0.22), PlayerPalette.background.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.30), value: model.artwork.map(ObjectIdentifier.init))
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var idleContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 43, weight: .light))
                .foregroundStyle(PlayerPalette.accent)
                .frame(width: 106, height: 106)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 28))
                .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.11)) }
                .accessibilityHidden(true)
            if model.snapshot?.phase == .ready && model.error.isEmpty {
                Text(model.name)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .textSelection(.enabled)
                Text("在小米妙播的设备列表中选择")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !model.wantsReceiving {
                Text("妙播接收")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .padding(.top, 4)
                Button { model.start() } label: {
                    Label("开始接收", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(PlayerPalette.background)
                .disabled(model.busy)
            }
            if model.busy {
                ProgressView().accessibilityLabel("正在更新接收状态")
            }
            if !model.error.isEmpty {
                Label(model.error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 10)
    }

    private func player(coverLimit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            artworkTile
                .frame(maxWidth: coverLimit)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.displayTitle)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 2)
                    .accessibilityAddTraits(.isHeader)
                if !model.displaySubtitle.isEmpty {
                    Text(model.displaySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ReceiverProgressView(model: model)
            transport
            ReceiverVolumeView(model: model)
            if !model.controlMessage.isEmpty {
                Text(model.controlMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var artworkTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 23)
                .fill(Color(red: 0.09, green: 0.16, blue: 0.19).gradient)
            if let artwork = model.artwork {
                Color.clear.overlay {
                    Image(uiImage: artwork).resizable().scaledToFill()
                }
                .id(ObjectIdentifier(artwork))
                .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(PlayerPalette.accent.opacity(0.66))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 23))
        .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.15)) }
        .shadow(color: .black.opacity(0.28), radius: 19, y: 10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.27), value: model.artwork.map(ObjectIdentifier.init))
        .accessibilityHidden(true)
    }

    private var transport: some View {
        let playing = model.snapshot?.phase == .playing
        return HStack(spacing: 22) {
            transportButton("backward.end.fill", label: "上一曲") { model.control(.previous) }
            transportButton(playing ? "pause.fill" : "play.fill", label: playing ? "暂停" : "播放", prominent: true) {
                model.togglePlayback()
            }
            transportButton("forward.end.fill", label: "下一曲") { model.control(.next) }
        }
        .frame(maxWidth: .infinity)
        .disabled(!model.canControl)
        .opacity(model.canControl ? 1 : 0.45)
    }

    private func transportButton(_ image: String, label: LocalizedStringKey, prominent: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: prominent ? 24 : 19, weight: .semibold))
                .foregroundStyle(prominent ? PlayerPalette.background : Color.white)
                .frame(width: prominent ? 60 : 46, height: prominent ? 60 : 46)
                .background(prominent ? PlayerPalette.accent : Color.white.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var lyricsPane: some View {
        ReceiverLyricsView(model: model)
            .id(TrackIdentity(snapshot: model.snapshot))
    }
}

private enum PlayerPalette {
    static let accent = Color(red: 0.57, green: 0.95, blue: 0.89)
    static let background = Color(red: 0.035, green: 0.075, blue: 0.09)
}

/// Guard gestures with the raw transport identity. A track change during a
/// drag must not move the new song to an old song's percentage.
private struct TrackIdentity: Equatable, Hashable {
    var key: String
    var duration: UInt64?
    var connected: Bool
    init(snapshot: Snapshot?) {
        if let snapshot {
            key = snapshot.trackId.isEmpty ? snapshot.title : snapshot.trackId
            duration = snapshot.durationMs
            connected = snapshot.controlsAvailable
        } else {
            key = ""
            duration = nil
            connected = false
        }
    }
}

@MainActor
private struct ReceiverProgressView: View {
    @ObservedObject var model: ReceiverModel
    @State private var drag: Drag?

    private struct Drag {
        let identity: TrackIdentity
        var fraction: Double
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let identity = TrackIdentity(snapshot: model.snapshot)
            let current = model.displayedPositionMs
            let duration = identity.duration ?? 0
            let liveFraction = duration > 0 && current != nil ? min(1, Double(current ?? 0) / Double(duration)) : 0
            let activeDrag = drag.flatMap { $0.identity == identity ? $0 : nil }
            let fraction = activeDrag?.fraction ?? liveFraction
            VStack(spacing: 1) {
                if duration > 0 && model.canSeek {
                    Slider(value: Binding(get: { fraction }, set: { value in
                        if var next = drag, next.identity == identity {
                            next.fraction = value
                            drag = next
                        }
                    }), in: 0...1, onEditingChanged: { editing in
                        if editing { drag = Drag(identity: identity, fraction: fraction) }
                        else { finishSeek() }
                    })
                    .accessibilityLabel("播放进度")
                    .accessibilityValue(Self.time(activeDrag.map { target($0.fraction, duration: duration) } ?? current))
                    .accessibilityAdjustableAction { direction in
                        guard model.canSeek, let position = model.displayedPositionMs else { return }
                        let positionClamped = min(position, duration)
                        switch direction {
                        case .increment: model.seek(to: positionClamped + min(10_000, duration - positionClamped))
                        case .decrement: model.seek(to: positionClamped - min(10_000, positionClamped))
                        @unknown default: break
                        }
                    }
                    .onDisappear { drag = nil }
                } else {
                    ProgressView(value: fraction)
                        .padding(.vertical, 11)
                        .accessibilityLabel("播放进度")
                }
                HStack {
                    Text(Self.time(activeDrag.map { target($0.fraction, duration: duration) } ?? current))
                    Spacer(minLength: 8)
                    Text(Self.time(identity.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.67))
                .accessibilityHidden(true)
            }
        }
    }

    private func finishSeek() {
        let currentDrag = drag
        drag = nil
        let latest = TrackIdentity(snapshot: model.snapshot)
        guard model.canSeek, let currentDrag, currentDrag.identity == latest, let duration = latest.duration else { return }
        model.seek(to: target(currentDrag.fraction, duration: duration))
    }

    private func target(_ fraction: Double, duration: UInt64) -> UInt64 {
        let raw = (Double(duration) * min(1, max(0, fraction))).rounded(.down)
        return min(duration, UInt64(exactly: raw) ?? duration)
    }

    private static func time(_ milliseconds: UInt64?) -> String {
        guard let milliseconds, milliseconds > 0 else { return milliseconds == nil ? "—" : "0:00" }
        let seconds = milliseconds / 1_000
        if seconds >= 3_600 {
            return String(format: "%llu:%02llu:%02llu", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%llu:%02llu", seconds / 60, seconds % 60)
    }
}

@MainActor
private struct ReceiverVolumeView: View {
    @ObservedObject var model: ReceiverModel
    @State private var draftVolume: Double?
    private var value: Double { draftVolume ?? model.volume }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: value > 0 ? "speaker.wave.2" : "speaker.slash")
                .frame(width: 22)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: { draftVolume = $0 }), in: 0...100, step: 1,
                   onEditingChanged: { editing in
                if editing { draftVolume = value }
                else if let draftVolume {
                    model.setVolume(draftVolume)
                    self.draftVolume = nil
                }
            })
            .accessibilityLabel("接收音量")
            .accessibilityValue(Text(value / 100, format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                draftVolume = nil
                switch direction {
                case .increment: model.setVolume(min(100, model.volume + 5))
                case .decrement: model.setVolume(max(0, model.volume - 5))
                @unknown default: break
                }
            }
            Text(value / 100, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .disabled(!model.initialized || model.busy)
    }
}

@MainActor
private struct ReceiverLyricsView: View {
    @ObservedObject var model: ReceiverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @GestureState private var dragging = false
    @State private var followRevision = 0
    @State private var following = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("歌词", systemImage: "quote.bubble")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if model.lyrics.isTimed && !following && !voiceOver {
                    Button("跟随播放") { following = true }
                        .font(.footnote.weight(.semibold))
                }
            }
            if model.lyrics.lines.isEmpty {
                VStack(spacing: 8) {
                    if model.lyricsLoading {
                        ProgressView()
                        Text("正在载入歌词…")
                    } else {
                        Text("发送设备未提供歌词")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    lyricScroll(activeID: activeLyricID)
                }
            }
        }
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.09)) }
        .task(id: followRevision) {
            guard !following, !dragging, !voiceOver else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            following = true
        }
    }

    private var activeLyricID: Int? {
        guard let position = model.displayedPositionMs,
              let index = model.lyrics.activeLineIndex(at: position) else { return nil }
        return model.lyrics.lines[index].id
    }

    private func lyricScroll(activeID: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(model.lyrics.lines) { line in
                        lyricRow(line, active: line.id == activeID).id(line.id)
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollIndicators(.visible)
            .simultaneousGesture(DragGesture(minimumDistance: 12).updating($dragging) { _, value, _ in value = true })
            .onChange(of: dragging) { _, active in
                if active { following = false }
                followRevision &+= 1
            }
            .onChange(of: activeID, initial: true) { _, current in scroll(proxy, to: current) }
            .onChange(of: following) { _, active in if active { scroll(proxy, to: activeID) } }
        }
    }

    @ViewBuilder private func lyricRow(_ line: LyricsLine, active: Bool) -> some View {
        let label = VStack(alignment: .leading, spacing: 4) {
            Text(line.text.isEmpty ? "•••" : line.text)
                .font(.title3.weight(.semibold))
            if let translation = line.translation {
                Text(translation)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(active ? PlayerPalette.accent : .white.opacity(0.68))
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
        if let timestamp = line.timeMs, !line.text.isEmpty, model.canSeek {
            Button { model.seek(to: timestamp) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("跳到这一句")
        } else {
            label
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: Int?) {
        guard following, !dragging, !voiceOver, let id else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.34)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

@MainActor
private struct ReceiverSettingsView: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage("showLyrics") private var showLyrics = false
    @AppStorage("uiCorrectLyricTitles") private var correctLyricTitles = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingName: Bool
    @State private var draftName = ""

    private var validName: Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != model.name && trimmed.utf8.count <= 63
            && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("接收状态", value: model.statusText)
                    if model.wantsReceiving {
                        Button("停止接收", role: .destructive) { model.stop() }
                            .disabled(model.busy)
                    } else {
                        Button("开始接收") { model.start() }
                            .disabled(model.busy)
                    }
                    if !model.error.isEmpty {
                        Text(model.error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                Section("设备名称") {
                    TextField("妙播列表显示的名称", text: $draftName)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($editingName)
                        .onSubmit(saveName)
                    Button("保存名称", action: saveName)
                        .disabled(!model.initialized || !validName || model.busy)
                }
                Section("播放显示") {
                    Toggle("显示歌词", isOn: $showLyrics)
                    Toggle("修正歌词标题", isOn: $correctLyricTitles)
                        .onChange(of: correctLyricTitles) { _, _ in model.refreshDisplayPresentation() }
                }
            }
            .navigationTitle("接收设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { draftName = model.name }
            .onChange(of: model.name) { _, name in if !editingName { draftName = name } }
        }
    }

    private func saveName() {
        guard model.initialized, validName, !model.busy else { return }
        editingName = false
        model.saveName(draftName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
