import SwiftUI

@main
struct FusionPlayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ReceiverAppLanguage.storageKey) private var appLanguage: ReceiverAppLanguage = .system
    @StateObject private var model = ReceiverModel()

    init() {
        LyricsDisplayMode.migrateLegacyPreference(legacyKey: "showLyrics")
        let defaults = UserDefaults.standard
        if defaults.string(forKey: LyricsDisplayMode.storageKey) == LyricsDisplayMode.always.rawValue {
            defaults.set(LyricsDisplayMode.automatic.rawValue, forKey: LyricsDisplayMode.storageKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            ReceiverRootView(model: model)
                .environment(\.locale, appLanguage.locale)
                .onChange(of: appLanguage) { _, _ in model.refreshDisplayPresentation() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Permission prompts briefly make the scene inactive.
            if phase == .active { model.setForeground(true) }
            if phase == .background { model.setForeground(false) }
        }
    }
}
