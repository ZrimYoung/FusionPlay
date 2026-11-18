import AppKit
import SwiftUI

struct SyncAdjustmentControl: View {
    @ObservedObject var model: ReceiverModel
    @Environment(\.appTypography) private var typography
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @State private var input = "0"
    @State private var invalidInput = false
    @FocusState private var editingValue: Bool
    private var unavailable: Bool { !model.initialized || model.syncAdjustmentBusy }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L("播放时间偏移"))
                Spacer()
                TextField("", text: $input, prompt: Text("0"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: 76)
                    .focused($editingValue).onSubmit { commitInput() }
                    .accessibilityLabel(L("播放时间偏移"))
                    .disabled(unavailable)
                Text("ms").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { adjust(by: -10) } label: {
                    Image(systemName: "minus").font(.system(size: 13)).frame(width: 24, height: 24)
                }.disabled(unavailable || model.syncAdjustment <= -200)
                    .help(L("提前 10 ms")).accessibilityLabel(L("提前 10 ms"))
                Slider(value: $model.syncAdjustment, in: -200...200) { editing in
                    if !editing {
                        model.syncAdjustment = model.syncAdjustment.rounded()
                        refreshInput()
                        model.saveSyncAdjustment()
                    }
                }.labelsHidden().frame(maxWidth: .infinity)
                    .accessibilityLabel(L("播放时间偏移")).disabled(unavailable)
                Button { adjust(by: 10) } label: {
                    Image(systemName: "plus").font(.system(size: 13)).frame(width: 24, height: 24)
                }.disabled(unavailable || model.syncAdjustment >= 200)
                    .help(L("延后 10 ms")).accessibilityLabel(L("延后 10 ms"))
            }.buttonStyle(.borderless)
            HStack {
                Text(L("提前")).font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize))
                Spacer()
                Button(L("恢复默认")) { apply(0) }
                    .disabled(unavailable || model.syncAdjustment == 0)
                Spacer()
                Text(L("延后")).font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize))
            }
            Text(L("负值提前，正值延后。输入后回车确认；加减按钮每次调整 10 ms。"))
                .font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if invalidInput {
                Text(L("请输入 −200 到 200 之间的整数。"))
                    .font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity)
            .onAppear { refreshInput() }
            .onChange(of: model.syncAdjustment) { _, _ in if !editingValue { refreshInput() } }
            .onChange(of: editingValue) { _, focused in if !focused { commitInput() } }
    }
    private func refreshInput() {
        input = String(Int(model.syncAdjustment.rounded())); invalidInput = false
    }
    private func commitInput() {
        guard !unavailable else { return }
        guard let value = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              (-200...200).contains(value) else { invalidInput = true; return }
        apply(value)
    }
    private func adjust(by step: Int) {
        apply(min(200, max(-200, Int(model.syncAdjustment.rounded()) + step)))
    }
    private func apply(_ value: Int) {
        guard !unavailable else { return }
        let changed = model.syncAdjustment != Double(value)
        model.syncAdjustment = Double(value)
        refreshInput(); editingValue = false
        if changed { model.saveSyncAdjustment() }
    }
}
