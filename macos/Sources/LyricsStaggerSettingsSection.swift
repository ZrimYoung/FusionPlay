import SwiftUI

/// Preferences shared with native lyric typography and motion policies.
struct LyricsStaggerSettingsSection: View {
    @AppStorage(LyricsTypography.storageKey) private var storedScalePercent = LyricsTypography.defaultScalePercent
    @AppStorage(LyricsStaggerTiming.moveStorageKey) private var storedMoveMilliseconds = LyricsStaggerTiming.defaultMoveMilliseconds
    @AppStorage(LyricsStaggerTiming.enabledStorageKey) private var staggerEnabled = LyricsStaggerTiming.defaultEnabled
    @AppStorage(LyricsStaggerTiming.millisecondsStorageKey) private var storedMilliseconds = LyricsStaggerTiming.defaultMilliseconds
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTypography) private var typography

    private var scalePercent: Int { LyricsTypography.clampScalePercent(storedScalePercent) }
    private var moveMilliseconds: Int { LyricsStaggerTiming.clampMoveMilliseconds(storedMoveMilliseconds) }
    private var milliseconds: Int { LyricsStaggerTiming.clampMilliseconds(storedMilliseconds) }
    private var scaleValue: Binding<Double> {
        quantizedValue(get: { scalePercent },
            set: { storedScalePercent = LyricsTypography.clampScalePercent($0) },
            range: LyricsTypography.scaleRange, step: LyricsTypography.scaleStep)
    }
    private var moveValue: Binding<Double> {
        quantizedValue(get: { moveMilliseconds },
            set: { storedMoveMilliseconds = LyricsStaggerTiming.clampMoveMilliseconds($0) },
            range: LyricsStaggerTiming.moveMillisecondsRange, step: LyricsStaggerTiming.moveStepMilliseconds)
    }
    private var spanValue: Binding<Double> {
        quantizedValue(get: { milliseconds },
            set: { storedMilliseconds = LyricsStaggerTiming.clampMilliseconds($0) },
            range: LyricsStaggerTiming.millisecondsRange, step: LyricsStaggerTiming.stepMilliseconds)
    }

    var body: some View {
        Section(L("歌词动效")) {
            adjustment(title: L("歌词字号"), valueText: "\(scalePercent)%", value: scaleValue,
                       range: LyricsTypography.scaleRange, step: LyricsTypography.scaleStep,
                       identifier: "settings.lyrics.font.scale") { delta in
                storedScalePercent = LyricsTypography.clampScalePercent(scalePercent + delta)
            }
            adjustment(title: L("单行移动时长"), valueText: "\(moveMilliseconds) ms", value: moveValue,
                       range: LyricsStaggerTiming.moveMillisecondsRange, step: LyricsStaggerTiming.moveStepMilliseconds,
                       identifier: "settings.lyrics.move.duration") { delta in
                storedMoveMilliseconds = LyricsStaggerTiming.clampMoveMilliseconds(moveMilliseconds + delta)
            }
            Toggle(L("交错滚动"), isOn: $staggerEnabled)
                .accessibilityIdentifier("settings.lyrics.stagger.enabled")
            if staggerEnabled {
                adjustment(title: L("交错时间跨度"), valueText: "\(milliseconds) ms", value: spanValue,
                           range: LyricsStaggerTiming.millisecondsRange, step: LyricsStaggerTiming.stepMilliseconds,
                           identifier: "settings.lyrics.stagger.span") { delta in
                    storedMilliseconds = LyricsStaggerTiming.clampMilliseconds(milliseconds + delta)
                }
                .help(L("可见歌词从上到下的最大动效时差"))
                .accessibilityHint(L("可见歌词从上到下的最大动效时差"))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: staggerEnabled)
    }

    private func adjustment(title: String, valueText: String, value: Binding<Double>,
                            range: ClosedRange<Int>, step: Int, identifier: String,
                            adjust: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 8) {
            LabeledContent {
                Text(valueText).font(typography.font(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            } label: {
                Text(title).font(typography.font(size: 13))
            }
            // Quantize the binding without stepped-slider tick marks.
            Slider(value: value, in: Double(range.lowerBound)...Double(range.upperBound))
                .labelsHidden().controlSize(.small)
                .accessibilityLabel(title).accessibilityValue(valueText)
                .accessibilityIdentifier(identifier)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjust(step)
                    case .decrement: adjust(-step)
                    @unknown default: break
                    }
                }
        }
    }
    private func quantizedValue(get: @escaping () -> Int, set: @escaping (Int) -> Void,
                                range: ClosedRange<Int>, step: Int) -> Binding<Double> {
        Binding(get: { Double(get()) }, set: { value in
            guard value.isFinite else { return }
            let bounded = min(Double(range.upperBound), max(Double(range.lowerBound), value))
            set(Int((bounded / Double(step)).rounded() * Double(step)))
        })
    }
}
