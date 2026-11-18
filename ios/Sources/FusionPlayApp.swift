import SwiftUI

@main
struct FusionPlayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ReceiverModel()

    var body: some Scene {
        WindowGroup {
            ReceiverRootView(model: model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Permission prompts briefly make the scene inactive.
            if phase == .active { model.setForeground(true) }
            if phase == .background { model.setForeground(false) }
        }
    }
}
