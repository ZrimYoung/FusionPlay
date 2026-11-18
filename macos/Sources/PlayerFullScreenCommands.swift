import AppKit
import SwiftUI

private struct PlayerFullScreenKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var playerSupportsFullScreen: Bool? {
        get { self[PlayerFullScreenKey.self] }
        set { self[PlayerFullScreenKey.self] = newValue }
    }
}

struct PlayerFullScreenCommands: Commands {
    @FocusedValue(\.playerSupportsFullScreen) private var supportsFullScreen
    @AppStorage("appLanguage") private var language = "zh-Hans"

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(L("切换全屏")) { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [.control, .command])
                .disabled(supportsFullScreen != true)
        }
    }
}
