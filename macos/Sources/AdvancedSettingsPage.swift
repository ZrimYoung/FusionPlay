import AppKit
import SwiftUI

struct AdvancedSettingsPage: View {
    @ObservedObject var model: ReceiverModel
    @State private var showingDiagnostics = false
    @Environment(\.appTypography) private var typography

    var body: some View {
        Form {
            Section(L("同步微调")) {
                SyncAdjustmentControl(model: model)
                Text(L("提前幅度受已接收音频限制。调整时会短暂重新同步；如出现断音，请减小幅度或恢复默认。"))
                    .font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.secondary)
                if !model.syncAdjustmentError.isEmpty {
                    Text(model.syncAdjustmentError)
                        .font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.red)
                }
            }
            Section {
                Button { showingDiagnostics = true } label: {
                    HStack(spacing: 12) {
                        Text(L("同步诊断")).font(typography.font(size: 13))
                        Spacer(minLength: 12)
                        Text(L(model.phaseLabel)).font(typography.font(size: 12)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L("同步诊断"))
                    .accessibilityValue(L(model.phaseLabel))
                    .accessibilityIdentifier("settings.diagnostics.details")
            }
            Section(L("数据与日志")) {
                Button(L("打开日志")) { model.openLogs() }
                Button(L("打开数据与卸载目录")) { NSWorkspace.shared.open(model.root) }
            }
        }.formStyle(.grouped)
            .sheet(isPresented: $showingDiagnostics) {
                SettingsDetailPanel(title: L("同步诊断")) {
                    DiagnosticsDetails(model: model)
                }.appTypography()
            }
    }
}

private struct DiagnosticsDetails: View {
    @ObservedObject var model: ReceiverModel
    @Environment(\.appTypography) private var typography

    var body: some View {
        Form {
            Section {
                LabeledContent(L("状态"), value: L(model.phaseLabel))
                LabeledContent(L("专辑封面"), value: L(model.artworkStatus))
                if model.snapshot?.controlsAvailable == true && model.artwork == nil {
                    Button(L("重新加载封面")) { model.reloadArtwork() }.disabled(model.artworkLoading)
                }
            }
            if let state = model.snapshot {
                Section {
                    LabeledContent(L("输出设备"), value: state.output.isEmpty ? L("尚未输出") : state.output)
                    LabeledContent(L("音频缓冲"), value: String(format: "%.1f ms", state.queueMs))
                    LabeledContent(L("设备输出延迟"), value: String(format: "%.1f ms", state.outputLatencyMs))
                    LabeledContent(L("调度误差"), value: String(format: "%.1f ms", state.scheduleErrorMs))
                    LabeledContent(L("欠载 / 重新同步"), value: "\(state.underruns) / \(state.resyncs)")
                } footer: {
                    Text(L("调度误差是软件内部指标，不代表与其他音箱的实测声音偏差。"))
                        .font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize))
                        .foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}
