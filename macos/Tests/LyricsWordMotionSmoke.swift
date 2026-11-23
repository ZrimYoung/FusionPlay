import AppKit
import SwiftUI

@MainActor private final class MotionFixture: ObservableObject {
    @Published var width: CGFloat = 620
    @Published var reduced = false
    let text = "Keep the quiet words together while the winding river moves across the mountains and the sea again"
}

private struct WordMotionFixtureView: View {
    @ObservedObject var model: MotionFixture
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LyricsReflowText(text: model.text, font: .systemFont(ofSize: 34, weight: .bold),
                             lineSpacing: 3, reduceMotion: model.reduced, width: model.width)
            Text("The following lyric keeps its place below this line")
                .font(.system(size: 20)).foregroundStyle(.white.opacity(0.55))
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@main struct LyricsWordMotionSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("PASS: staged word blur, height order, same-line movement, reverse resize and reduced motion"); exit(0) }
            catch { FileHandle.standardError.write(Data("Word motion check failed: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    @MainActor private static func run() async throws {
        typealias Sample = LyricsReflowTextCheckEvents.PhaseSample
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "Legacy motion assertion failed") {
            guard condition() else {
                FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1)
            }
        }
        let model = MotionFixture()
        let font = NSFont.systemFont(ofSize: 34, weight: .bold)
        let wide = LyricsWordLayout.measure(text: model.text, font: font, lineSpacing: 3, width: 620)
        let narrow = LyricsWordLayout.measure(text: model.text, font: font, lineSpacing: 3, width: 330)
        precondition(wide.isRasterComplete && narrow.isRasterComplete && narrow.height > wide.height)
        LyricsReflowTextCheckEvents.forceLegacyRenderer = true
        defer { LyricsReflowTextCheckEvents.forceLegacyRenderer = false }
        var phases: [Sample] = [], transitions: [(String, Int)] = []
        LyricsReflowTextCheckEvents.phase = { phases.append($0) }
        LyricsReflowTextCheckEvents.transition = { transitions.append(($0, $1)) }
        defer {
            LyricsReflowTextCheckEvents.phase = nil; LyricsReflowTextCheckEvents.transition = nil
            LyricsReflowTextCheckEvents.sample = nil
        }
        let host = NSHostingView(rootView: WordMotionFixtureView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.alphaValue = 0; window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        await pause(0.4)
        func current() -> Sample {
            guard let sample = LyricsReflowTextCheckEvents.sample?() else { fatalError("Missing word-motion sampler") }
            return sample
        }
        func save(_ sample: Sample, name: String) throws {
            // Use the actual sprite canvas at the sampled analytic time. This
            // needs no visible window or permission to record the desktop.
            let renderer = ImageRenderer(content: sample.preview.background(Color.black))
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: sample.width, height: sample.height)
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { fatalError("Missing word canvas preview") }
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }

        phases.removeAll(); transitions.removeAll()
        let initial = current()
        precondition(abs(initial.height - wide.height) < 0.01)
        model.width = 330
        await pause(0.09)
        let expanding = current()
        precondition(expanding.direction == "expand" && expanding.height > wide.height && expanding.height < narrow.height)
        precondition(expanding.movingWordCount > 0 && expanding.poses.values.contains { $0.moving && $0.blur > 0.1 })
        try save(expanding, name: "expand-space-and-vanish")
        await pause(0.17)
        let appearing = current()
        precondition(abs(appearing.height - narrow.height) < 0.5,
                     "New-place words appeared before expanded height was ready")
        precondition(appearing.poses.values.contains { $0.moving && $0.opacity > 0 && $0.opacity < 1 })
        try save(appearing, name: "expand-new-position-appears")
        await pause(0.4)
        precondition(abs(current().height - narrow.height) < 0.01)
        let expansion = phases.filter { $0.direction == "expand" }
        let expandMove = expansion.firstIndex { $0.phase == "move" }
        let expandAppear = expansion.firstIndex { $0.phase == "appear" }
        precondition(expandMove != nil && expandAppear != nil && expandMove! < expandAppear!)

        phases.removeAll()
        model.width = 620
        await pause(0.08)
        let vanishing = current()
        precondition(vanishing.direction == "contract" && abs(vanishing.height - narrow.height) < 0.5,
                     "Contraction changed height before moving words vanished")
        try save(vanishing, name: "contract-vanish-before-collapse")
        await pause(0.14)
        let collapsing = current()
        precondition(collapsing.visibleMovingCount == 0 && collapsing.height < narrow.height && collapsing.height > wide.height)
        precondition(collapsing.poses.values.filter(\.moving).allSatisfy { $0.opacity <= 0.02 })
        try save(collapsing, name: "contract-space-collapses")
        await pause(0.2)
        let contractAppear = current()
        precondition(abs(contractAppear.height - wide.height) < 0.5)
        try save(contractAppear, name: "contract-new-position-appears")
        await pause(0.3)
        let contraction = phases.filter { $0.direction == "contract" }
        let vanish = contraction.firstIndex { $0.phase == "vanish" }
        let move = contraction.firstIndex { $0.phase == "move" }
        let appear = contraction.firstIndex { $0.phase == "appear" }
        precondition(vanish != nil && move != nil && appear != nil && vanish! < move! && move! < appear!)

        // At least one word which stays on its visual line must slide rather
        // than jump when a new row begins with an earlier word.
        let moderate = LyricsWordLayout.measure(text: model.text, font: font, lineSpacing: 3, width: 560)
        let narrowByID = Dictionary(uniqueKeysWithValues: moderate.fragments.map { ($0.id, $0) })
        let sliding = wide.fragments.filter {
            guard let next = narrowByID[$0.id] else { return false }
            return next.lineIndex == $0.lineIndex && abs(next.frame.minX - $0.frame.minX) > 5
        }
        precondition(!sliding.isEmpty, "Fixture did not exercise same-line sliding")
        model.width = 560; await pause(0.08)
        let midway = current()
        precondition(sliding.contains { word in
            guard let pose = midway.poses[word.id], let end = narrowByID[word.id] else { return false }
            let x = pose.frame.minX
            return x > min(word.frame.minX, end.frame.minX) + 0.1 && x < max(word.frame.minX, end.frame.minX) - 0.1
        }, "Same-line words did not interpolate their position")

        let beforeReverse = current()
        model.width = 620; await pause(0.01)
        let afterReverse = current()
        for (id, pose) in beforeReverse.poses where pose.opacity > 0.2 {
            guard let next = afterReverse.poses[id], next.opacity > 0.2 else { continue }
            precondition(abs(next.frame.minX - pose.frame.minX) < 32 && abs(next.frame.minY - pose.frame.minY) < 32,
                         "Reverse resize flashed a visible word to an old destination")
        }
        for width in [410.0, 560.0, 330.0, 620.0] { model.width = width; await pause(0.04) }
        await pause(0.8)
        precondition(transitions.allSatisfy { $0.1 <= 1 }, "Multiple simultaneous reflow plans accumulated")
        var newest: UInt64 = 0
        for phase in phases {
            if phase.phase == "begin" { newest = max(newest, phase.revision) }
            if phase.phase == "appear" || phase.phase == "end" {
                precondition(phase.revision >= newest, "A canceled phase appeared after a newer plan")
            }
        }

        model.width = 330; await pause(0.06); model.reduced = true; await pause(0.05)
        let reduced = current()
        precondition(abs(reduced.height - narrow.height) < 0.01)
        precondition(reduced.poses.values.allSatisfy { $0.opacity == 1 && $0.blur == 0 })
        model.width = 620; await pause(0.06)
        precondition(abs(current().height - wide.height) < 0.01)
        try save(current(), name: "reduced-motion-settled")
        let records = phases.map { sample in
            ["direction": sample.direction, "phase": sample.phase, "revision": sample.revision,
             "height": sample.height, "targetHeight": sample.targetHeight,
             "movingWords": sample.movingWordCount, "visibleMovingWords": sample.visibleMovingCount] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "phases": records,
            "visibleTestWindows": false, "receiverStarted": false, "realPreferencesChanged": false],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("word-motion-check.json"), options: .atomic)
    }
}
