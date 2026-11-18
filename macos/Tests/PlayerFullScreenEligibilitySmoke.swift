import AppKit
import Darwin
import SwiftUI

/// A real Window-scene regression for SwiftUI overriding native fullscreen
/// eligibility. It never enters fullscreen or changes the user's Space.
@main struct PlayerFullScreenEligibilitySmoke: App {
    @NSApplicationDelegateAdaptor(EligibilitySmokeDelegate.self) private var delegate
    @StateObject private var driver = EligibilitySmokeDriver()

    var body: some Scene {
        Window("FusionPlay Fullscreen Eligibility Check", id: "eligibility-check") {
            ZStack {
                Color.clear
                Text("Synthetic fullscreen eligibility check")
                PlayerWindowBehavior(square: false, miniRequest: 0, miniLyrics: true,
                                     dimButtons: false, pinned: true, duration: 0)
                    .frame(width: 0, height: 0)
            }
            // Fixed content causes the scene's automatic eligibility inference
            // to opt out, even when AppKit is manually marked fullscreenPrimary.
            .frame(width: 420, height: 420)
            .modifier(EligibilityOverride(enabled: driver.enabled))
            .background(EligibilityWindowProbe(driver: driver).frame(width: 0, height: 0))
        }
        .defaultSize(width: 760, height: 420)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

private struct EligibilityOverride: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.modifier(PlayerFullScreenEligibility()) }
        else { content }
    }
}

private final class EligibilitySmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            FileHandle.standardError.write(Data("FAIL: fullscreen eligibility check timed out\n".utf8))
            exit(1)
        }
    }
}

@MainActor private final class EligibilitySmokeDriver: ObservableObject {
    @Published var enabled = false
    private var started = false
    private var samples: [[String: Any]] = []

    func start(_ window: NSWindow) {
        guard !started else { return }
        started = true
        window.alphaValue = 0
        window.orderBack(nil)
        Task { @MainActor in
            guard MenuAvailability.supported else {
                print("SKIP: explicit SwiftUI fullscreen eligibility requires macOS 15 and its SDK")
                window.close(); exit(0)
            }
            let identity = ObjectIdentifier(window)
            // Let the scene finish applying its own inference after the
            // production coordinator's initial asynchronous native repair.
            try? await Task.sleep(nanoseconds: 700_000_000)
            record("automatic", window: window)
            guard window.collectionBehavior.contains(.fullScreenNone),
                  !window.collectionBehavior.contains(.fullScreenPrimary),
                  window.accessibilityFullScreenButton() == nil else {
                fail("Automatic scene did not reproduce the fullscreenNone override", window: window)
            }
            enabled = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            for step in 0..<12 {
                requireEnabled("enabled-\(step)", window: window)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            window.setContentSize(NSSize(width: 840, height: 520))
            for step in 0..<12 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                requireEnabled("after-resize-\(step)", window: window)
            }
            guard ObjectIdentifier(window) == identity,
                  NSApp.activationPolicy() == .accessory,
                  window.level == .floating,
                  !window.styleMask.contains(.fullScreen) else {
                fail("Eligibility override changed the window's identity or non-fullscreen policy", window: window)
            }
            persist(passed: true)
            window.orderOut(nil); window.close()
            print("PASS: native SwiftUI automatic opt-out reproduced; explicit eligibility stayed enabled through layout and resize (no fullscreen Space, receiver or real preferences)")
            exit(0)
        }
    }

    private func requireEnabled(_ stage: String, window: NSWindow) {
        record(stage, window: window)
        guard window.collectionBehavior.contains(.fullScreenPrimary),
              !window.collectionBehavior.contains(.fullScreenNone),
              window.accessibilityFullScreenButton() != nil,
              !window.styleMask.contains(.fullScreen) else {
            fail("Explicit eligibility was overwritten at " + stage, window: window)
        }
    }

    private func record(_ stage: String, window: NSWindow) {
        samples.append(["stage": stage, "uptime": ProcessInfo.processInfo.systemUptime,
            "collectionBehavior": window.collectionBehavior.rawValue,
            "hasFullScreenButton": window.accessibilityFullScreenButton() != nil,
            "nativeFullScreen": window.styleMask.contains(.fullScreen),
            "frame": NSStringFromRect(window.frame), "level": window.level.rawValue,
            "activationPolicy": NSApp.activationPolicy().rawValue])
    }

    private func persist(passed: Bool, reason: String? = nil) {
        guard let path = ProcessInfo.processInfo.environment["FUSIONPLAY_FULLSCREEN_CHECK_RESULT"] else { return }
        var data: [String: Any] = ["passed": passed, "samples": samples,
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "receiverStarted": false, "enteredFullScreen": false, "realPreferencesChanged": false]
        if let reason { data["reason"] = reason }
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func fail(_ reason: String, window: NSWindow) -> Never {
        record("failure", window: window)
        persist(passed: false, reason: reason)
        FileHandle.standardError.write(Data(("FAIL: " + reason + "\n").utf8))
        window.orderOut(nil); window.close(); exit(1)
    }
}

private enum MenuAvailability {
    static var supported: Bool {
#if compiler(>=6.0)
        if #available(macOS 15.0, *) { return true }
#endif
        return false
    }
}

private struct EligibilityWindowProbe: NSViewRepresentable {
    let driver: EligibilitySmokeDriver
    func makeNSView(context: Context) -> ProbeView { ProbeView(driver: driver) }
    func updateNSView(_ view: ProbeView, context: Context) {}
    final class ProbeView: NSView {
        private let driver: EligibilitySmokeDriver
        init(driver: EligibilitySmokeDriver) { self.driver = driver; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            driver.start(window)
        }
    }
}
