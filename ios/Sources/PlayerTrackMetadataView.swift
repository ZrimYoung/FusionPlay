import SwiftUI

struct PlayerTrackMetadataView: View {
    let title: String
    let subtitle: String
    let trackKey: String

    @AppStorage("wrapPlayerMetadata") private var wrapMetadata = false
    @Environment(\.receiverTypography) private var typography
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var wrapThreshold = 8.0

    private var lineCount: Int {
        guard wrapMetadata else { return 1 }
        return dynamicTypeSize.isAccessibilitySize ? 3 : 2
    }

    private var transitionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.28)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(typography.font(.largeTitle, size: 34, weight: .bold))
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityAddTraits(.isHeader)
                .contentTransition(.opacity)
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(typography.font(.body, size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .accessibilityLabel(Text(verbatim: subtitle))
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
        }
        .lineLimit(lineCount)
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(transitionAnimation, value: wrapMetadata)
        .animation(transitionAnimation, value: trackKey)
        .animation(transitionAnimation, value: subtitle.isEmpty)
        .modifier(PlayerTextHeightMotion(wrapThreshold: wrapThreshold, stagesEnabled: false, animateContentChanges: true))
    }
}
