import SwiftUI

@MainActor
struct ReceiverVolumeControl: View {
    @ObservedObject var model: ReceiverModel
    @Binding var showingVolume: Bool
    @State private var draftVolume: Double?

    private var value: Double { draftVolume ?? model.volume }
    private var unavailable: Bool { !model.initialized || model.busy }
    private var volumeSymbol: String {
        if value == 0 { return "speaker.slash.fill" }
        if value < 50 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    var body: some View {
        Button { showingVolume.toggle() } label: {
            Image(systemName: volumeSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(showingVolume ? 0.12 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("接收音量")
        .accessibilityValue(volumePercentage)
        .disabled(unavailable)
        .popover(isPresented: $showingVolume) {
            volumeSlider
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: showingVolume) { _, presented in
            if !presented { draftVolume = nil }
        }
    }

    private var volumePercentage: Text {
        Text(value / 100, format: .percent.precision(.fractionLength(0)))
    }

    private var volumeSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: { draftVolume = $0 }), in: 0...100) { isEditing in
                if isEditing {
                    draftVolume = value
                } else if let draftVolume {
                    commitVolume(draftVolume)
                }
            }
            .accessibilityLabel("接收音量")
            .accessibilityValue(volumePercentage)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commitVolume(min(100, value + 5))
                case .decrement: commitVolume(max(0, value - 5))
                @unknown default: break
                }
            }
            Image(systemName: "speaker.wave.3.fill")
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .frame(width: 208)
        .padding(16)
        .disabled(unavailable)
    }

    private func commitVolume(_ newValue: Double) {
        draftVolume = nil
        guard !unavailable else { return }
        model.setVolume(newValue)
    }
}
