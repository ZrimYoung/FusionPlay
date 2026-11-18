import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReceiverDiagnosticsView: View {
    @ObservedObject var model: ReceiverModel
    @State private var expanded = false
    @State private var shareTask: Task<Void, Never>?
    @State private var logToShare: DiagnosticLogShare?
    @State private var shareMessage: LocalizedStringKey?

    private var activeOutput: Snapshot? {
        guard let state = model.snapshot, state.controlsAvailable, !state.output.isEmpty else { return nil }
        switch state.phase {
        case .connected, .playing, .paused: return state
        default: return nil
        }
    }

    var body: some View {
        Section {
            DisclosureGroup("同步诊断", isExpanded: $expanded) {
                LabeledContent("接收状态", value: model.statusText)
                LabeledContent("专辑封面") { Text(model.artworkStatus.title) }
                if model.canReloadArtwork {
                    Button("重新加载封面", action: model.reloadArtwork)
                }
                if let state = activeOutput {
                    LabeledContent("输出设备", value: state.output)
                    metric("音频缓冲", milliseconds: state.queueMs)
                    metric("设备输出延迟", milliseconds: state.outputLatencyMs)
                    metric("调度误差", milliseconds: state.scheduleErrorMs)
                    LabeledContent("欠载 / 重新同步") {
                        Text("\(state.underruns) / \(state.resyncs)").monospacedDigit()
                    }
                } else {
                    LabeledContent("输出设备") { Text("尚未输出") }
                }
            }

            Button(action: prepareShare) {
                HStack {
                    Label("分享诊断日志", systemImage: "square.and.arrow.up")
                    if shareTask != nil {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(shareTask != nil || logToShare != nil)
            .background {
                DiagnosticLogPresenter(log: logToShare) { failed in
                    logToShare = nil
                    if failed { shareMessage = "无法分享诊断日志。" }
                }
            }
            if let shareMessage {
                Text(shareMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if expanded && activeOutput != nil {
                Text("调度误差是软件内部指标，不代表与其他音箱的实测声音偏差。")
            }
        }
        .onDisappear {
            shareTask?.cancel()
            shareTask = nil
            logToShare = nil
        }
    }

    private func metric(_ title: LocalizedStringKey, milliseconds: Double) -> some View {
        LabeledContent(title) {
            Text(milliseconds.formatted(.number.precision(.fractionLength(1))) + " ms")
                .monospacedDigit()
        }
    }

    private func prepareShare() {
        guard shareTask == nil, logToShare == nil else { return }
        shareMessage = nil
        shareTask = Task {
            do {
                let log = try await Task.detached(priority: .utility) { try ReceiverDiagnosticLog.snapshot() }.value
                guard !Task.isCancelled else { return }
                if let log {
                    logToShare = DiagnosticLogShare(data: log)
                } else {
                    shareMessage = "暂无诊断日志。"
                }
            } catch {
                guard !Task.isCancelled else { return }
                shareMessage = "无法分享诊断日志。"
            }
            shareTask = nil
        }
    }
}

enum ReceiverDiagnosticLog {
    static func snapshot() throws -> Data? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        return try snapshot(in: base.appendingPathComponent("logs", isDirectory: true))
    }

    static func snapshot(in directory: URL) throws -> Data? {
        for name in ["receiver.jsonl", "receiver.previous.jsonl"] {
            let url = directory.appendingPathComponent(name)
            do {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                // Open the file before getting its size so rotation cannot switch the file mid-read.
                let end = try file.seekToEnd()
                let start = end > 5_100_000 ? end - 5_100_000 : 0
                try file.seek(toOffset: start)
                guard let data = try file.read(upToCount: Int(end - start)),
                      let lastBreak = data.lastIndex(of: 0x0A) else { continue }
                var first = data.startIndex
                if start > 0 {
                    guard let lineBreak = data.firstIndex(of: 0x0A) else { continue }
                    first = data.index(after: lineBreak)
                }
                if first <= lastBreak {
                    return Data(data[first...lastBreak])
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                // The current log can be absent just after it has been rotated.
                continue
            }
        }
        return nil
    }
}

private struct DiagnosticLogShare {
    let id = UUID()
    let data: Data
}

private struct DiagnosticLogPresenter: UIViewControllerRepresentable {
    let log: DiagnosticLogShare?
    let onCompletion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let log, context.coordinator.lastPresented != log.id else { return }
        context.coordinator.lastPresented = log.id
        // Present after SwiftUI finishes updating the Form's view hierarchy.
        Task { @MainActor in
            guard controller.view.window != nil, controller.presentedViewController == nil else {
                onCompletion(true)
                return
            }
            let provider = NSItemProvider()
            provider.suggestedName = "FusionPlay-diagnostics.txt"
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                completion(log.data, nil)
                return nil
            }
            let activity = UIActivityViewController(activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: [provider]))
            activity.completionWithItemsHandler = { _, _, _, error in
                Task { @MainActor in onCompletion(error != nil) }
            }
            if controller.traitCollection.userInterfaceIdiom == .pad {
                activity.modalPresentationStyle = .popover
                activity.popoverPresentationController?.sourceView = controller.view
                activity.popoverPresentationController?.sourceRect = controller.view.bounds
            }
            controller.present(activity, animated: true)
        }
    }

    final class Coordinator {
        var lastPresented: UUID?
    }
}
