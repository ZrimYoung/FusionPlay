import SwiftUI
import UIKit

struct ReceiverSyncSettings: View {
    @ObservedObject var model: ReceiverModel
    @FocusState private var editingOffset: Bool
    @State private var input = "0"
    @State private var draft = 0.0
    @State private var invalidInput = false

    private let range = ReceiverModel.syncAdjustmentRange
    private var invalidOffsetMessage: String { ReceiverAppLanguage.text("请输入 −200 到 200 之间的整数。") }
    private var unavailable: Bool { !model.initialized || model.busy || model.syncAdjustmentBusy }

    var body: some View {
        Section {
            LabeledContent("播放时间偏移") {
                HStack(spacing: 6) {
                    TextField("播放时间偏移", text: $input)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 78)
                        .submitLabel(.done)
                        .focused($editingOffset)
                        .accessibilityLabel("播放时间偏移（毫秒）")
                        .onSubmit(commitInput)
                        .onChange(of: input) { _, _ in invalidInput = false }
                    Text(verbatim: "ms")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .disabled(unavailable)
            }

            HStack(spacing: 8) {
                stepButton("提前 10 ms", symbol: "minus", delta: -10)
                Slider(value: $draft, in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
                    if !editing { apply(Int(draft.rounded())) }
                }
                .accessibilityLabel("播放时间偏移")
                .accessibilityValue("\(Int(draft.rounded())) ms")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjust(by: 10)
                    case .decrement: adjust(by: -10)
                    @unknown default: break
                    }
                }
                stepButton("延后 10 ms", symbol: "plus", delta: 10)
            }
            .buttonStyle(.borderless)
            .disabled(unavailable)

            Button("恢复默认") { apply(0) }
                .disabled(unavailable || (draft == 0 && input == "0" && model.syncAdjustmentError.isEmpty))

            if invalidInput {
                Text(invalidOffsetMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if !model.syncAdjustmentError.isEmpty {
                Text(model.syncAdjustmentError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("同步微调")
        } footer: {
            Text("负值提前，正值延后。输入后按完成。播放中调整会短暂重新同步。")
        }
        .onAppear(perform: restoreSavedValue)
        .onChange(of: draft) { _, value in
            if !editingOffset { input = String(Int(value.rounded())) }
        }
        .onChange(of: model.syncAdjustment) { _, _ in restoreSavedValue() }
        .onChange(of: model.syncAdjustmentBusy) { _, saving in
            if !saving { restoreSavedValue() }
        }
    }

    private func stepButton(_ label: LocalizedStringKey, symbol: String, delta: Int) -> some View {
        Button { adjust(by: delta) } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .disabled(delta < 0 ? draft <= Double(range.lowerBound) : draft >= Double(range.upperBound))
    }

    private func restoreSavedValue() {
        draft = Double(model.syncAdjustment)
        input = String(model.syncAdjustment)
        invalidInput = false
    }

    private func commitInput() {
        let halfwidth = input.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? input
        let normalized = halfwidth.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        guard let value = Int(normalized), range.contains(value) else {
            invalidInput = true
            UIAccessibility.post(notification: .announcement, argument: invalidOffsetMessage)
            return
        }
        apply(value)
    }

    private func adjust(by delta: Int) {
        apply(min(range.upperBound, max(range.lowerBound, Int(draft.rounded()) + delta)))
    }

    private func apply(_ value: Int) {
        guard !unavailable else {
            restoreSavedValue()
            return
        }
        editingOffset = false
        draft = Double(value)
        input = String(value)
        invalidInput = false
        model.setSyncAdjustment(value)
    }
}
