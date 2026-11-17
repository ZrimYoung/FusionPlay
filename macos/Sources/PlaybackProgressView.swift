import SwiftUI

// Shared by the menu and both player layouts. Only drag preview/pending UI is local.
struct PlaybackProgressView: View {
    @ObservedObject var model: ReceiverModel
    var showsTime = true
    var menu = false
    var visible = true
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @AppStorage("playerProgressColorMode") private var colorMode = "white"
    @AppStorage("playerProgressCustomHex") private var customHex = PlayerAppearance.defaultCustomHex
    @State private var dragFraction: Double?
    @State private var dragSource: PlaybackObservation?
    @State private var rejectedDrag = false
    @State private var interactionID = UUID()
    private var observation: PlaybackObservation? {
        guard let state = model.snapshot else { return nil }
        return PlaybackObservation(trackID: state.trackId, title: state.title, duration: state.durationMs,
                                   position: state.positionMs, connected: state.controlsAvailable, playing: state.phase == .playing)
    }
    private var sameTrack: Bool {
        guard let dragSource, let observation else { return false }
        return dragSource.sameTrack(as: observation)
    }
    private var displayPosition: UInt64? {
        if let dragFraction, sameTrack { return target(dragFraction, duration: dragSource?.duration) }
        return model.displayedPositionMs
    }
    private var fraction: Double {
        guard let duration = observation?.duration, duration > 0, let displayPosition else { return 0 }
        return min(1, Double(displayPosition) / Double(duration))
    }
    private var fill: Color {
        if menu && colorMode == "white" { return .primary.opacity(0.5) }
        return PlayerAppearance.color(mode: colorMode, hex: customHex)
    }
    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(menu ? Color.primary.opacity(0.1) : Color.white.opacity(0.18))
                    Capsule().fill(fill).frame(width: max(0, geometry.size.width * fraction))
                        .transaction { $0.animation = nil } // Keep the fill's left edge fixed on backward seeks.
                }.frame(height: 3).frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard visible, model.canSeek, !rejectedDrag, geometry.size.width > 0 else { return }
                            if dragSource == nil { dragSource = observation; model.setScrubbing(interactionID, true) }
                            guard sameTrack else { rejectedDrag = true; return }
                            dragFraction = min(1, max(0, Double(value.location.x / geometry.size.width)))
                        }
                        .onEnded { value in
                            if visible, !rejectedDrag, sameTrack, model.canSeek, geometry.size.width > 0 {
                                let fraction = min(1, max(0, Double(value.location.x / geometry.size.width)))
                                model.seek(to: target(fraction, duration: dragSource?.duration))
                            }
                            finishDrag()
                        })
            }.frame(height: 18)
                .opacity(model.seekPending && dragFraction == nil ? 0.65 : 1)
                .animation(.easeInOut(duration: 0.15), value: model.seekPending)
            if showsTime {
                HStack {
                    Text(PlayerAppearance.time(displayPosition))
                    Spacer()
                    Text(PlayerAppearance.time(observation?.duration))
                }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
        }.frame(height: showsTime ? 36 : 18, alignment: .top)
            .allowsHitTesting(visible).accessibilityHidden(!visible)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("播放进度"))
            .accessibilityValue(PlayerAppearance.time(displayPosition) + " / " + PlayerAppearance.time(observation?.duration))
            .accessibilityAdjustableAction { direction in
                guard visible, model.canSeek, let duration = observation?.duration else { return }
                let current = min(model.displayedPositionMs ?? 0, duration)
                switch direction {
                case .increment: model.seek(to: current + min(10_000, duration - current))
                case .decrement: model.seek(to: current > 10_000 ? current - 10_000 : 0)
                @unknown default: break
                }
            }
            .help(PlayerAppearance.time(displayPosition) + " / " + PlayerAppearance.time(observation?.duration) + " · " + L("点击或拖动跳转，松手后发送到手机"))
            .onChange(of: observation?.trackID) { _, _ in invalidateDrag() }
            .onChange(of: observation?.title) { _, _ in
                if observation?.trackID.isEmpty != false { invalidateDrag() }
            }
            .onChange(of: observation?.duration) { _, _ in invalidateDrag() }
            .onChange(of: observation?.connected) { _, _ in invalidateDrag() }
            .onChange(of: visible) { _, shown in if !shown { invalidateDrag() } }
            .onDisappear { finishDrag() }
    }
    private func target(_ fraction: Double, duration: UInt64?) -> UInt64 {
        let duration = duration ?? 0
        if fraction >= 1 { return duration }
        return UInt64(min(Double(UInt64.max - 2048), (max(0, fraction) * Double(duration)).rounded(.down)))
    }
    private func invalidateDrag() {
        if dragSource != nil { rejectedDrag = true; dragFraction = nil; model.setScrubbing(interactionID, false) }
    }
    private func finishDrag() {
        dragFraction = nil; dragSource = nil; rejectedDrag = false
        model.setScrubbing(interactionID, false)
    }
}
