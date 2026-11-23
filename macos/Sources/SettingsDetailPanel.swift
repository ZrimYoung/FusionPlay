import AppKit
import SwiftUI

/// A focused native sheet with its own header and scrollable form content.
/// It intentionally does not inherit the settings window's sidebar or toolbar.
struct SettingsDetailPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTypography) private var typography

    private var panelHeight: CGFloat {
        let visibleHeight = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 640
        return min(520, max(320, visibleHeight - 96))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(title).font(typography.font(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button(L("关闭"), role: .cancel) { dismiss() }
                    .font(typography.font(size: 13))
                    .keyboardShortcut("w", modifiers: .command)
                    .accessibilityIdentifier("settings.details.close")
            }.padding(.horizontal, 20).padding(.vertical, 16)
                .background(.bar)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: panelHeight)
        .onExitCommand { dismiss() }
        .background {
#if FUSIONPLAY_UI_CHECKS
            SettingsDetailPanelWindowCheckBridge().frame(width: 0, height: 0)
#endif
        }
    }
}

#if FUSIONPLAY_UI_CHECKS
@MainActor enum SettingsDetailPanelCheckEvents {
    static var windowAttached: ((NSWindow) -> Void)?
}
private struct SettingsDetailPanelWindowCheckBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}
    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SettingsDetailPanelCheckEvents.windowAttached?(window) }
        }
    }
}
#endif
