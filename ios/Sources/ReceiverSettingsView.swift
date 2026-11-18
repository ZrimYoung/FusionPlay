import SwiftUI
import UIKit

@MainActor
struct ReceiverSettingsView: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage("autoStartReceiver") private var autoStartReceiver = true
    @AppStorage("playerShowsProgress") private var showProgress = true
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @AppStorage("showLyrics") private var showLyrics = false
    @AppStorage("uiCorrectLyricTitles") private var correctLyricTitles = false
    @AppStorage("playerToolbarAlwaysVisible") private var toolbarAlwaysVisible = false
    @AppStorage("staggerLyricMotion") private var staggerLyricMotion = true
    @AppStorage("lyricStaggerMilliseconds") private var lyricStaggerMilliseconds = LyricReflowTiming.defaultStaggerMilliseconds
    @AppStorage("wrapPlayerMetadata") private var wrapPlayerMetadata = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var editingName: Bool
    @State private var draftName = ""
    @State private var page: Page? = .receiver
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    private enum Page: String, CaseIterable, Identifiable {
        case receiver, appearance, audio, about

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .receiver: "接收"
            case .appearance: "外观"
            case .audio: "音频"
            case .about: "关于"
            }
        }

        var symbol: String {
            switch self {
            case .receiver: "antenna.radiowaves.left.and.right"
            case .appearance: "paintbrush"
            case .audio: "speaker.wave.2"
            case .about: "info.circle"
            }
        }
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validName: Bool {
        !trimmedName.isEmpty && trimmedName != model.name && trimmedName.utf8.count <= 63
            && !trimmedName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    var body: some View {
        if #available(iOS 18, *), isPad {
            navigation.presentationSizing(.page)
        } else {
            navigation
        }
    }

    private var navigation: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(Page.allCases, selection: $page) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.symbol)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 170, ideal: 205, max: 245)
            .toolbar {
                if horizontalSizeClass != .regular {
                    ToolbarItem(placement: .confirmationAction) { doneButton }
                }
            }
        } detail: {
            let current = page ?? .receiver
            content(for: current)
                .formStyle(.grouped)
                .navigationTitle(current.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { doneButton }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { draftName = model.name }
        .onChange(of: model.name) { _, name in
            if !editingName { draftName = name }
        }
    }

    private var doneButton: some View {
        Button("完成") { dismiss() }
    }

    @ViewBuilder private func content(for current: Page) -> some View {
        switch current {
        case .receiver: receiverForm
        case .appearance: appearanceForm
        case .audio: Form { ReceiverSyncSettings(model: model) }
        case .about: aboutForm
        }
    }

    private var receiverForm: some View {
        Form {
            Section {
                LabeledContent("接收状态", value: model.statusText)
                Toggle("打开 App 时自动接收", isOn: $autoStartReceiver)
                if model.wantsReceiving {
                    Button("停止接收", role: .destructive) { model.stop() }
                        .disabled(model.busy)
                } else {
                    Button("开始接收") { model.start() }
                        .disabled(model.busy)
                }
                if !model.error.isEmpty {
                    Text(model.error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("设备名称") {
                TextField("妙播列表显示的名称", text: $draftName)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editingName)
                    .onSubmit(saveName)
                Button("保存名称", action: saveName)
                    .disabled(!model.initialized || !validName || model.busy)
            }
        }
    }

    private var appearanceForm: some View {
        Form {
            Section("播放显示") {
                Toggle("显示进度与时间", isOn: $showProgress)
                Toggle("显示播放控制", isOn: $showPlaybackControls)
                Toggle("允许歌名和艺人信息换行", isOn: $wrapPlayerMetadata)
                Toggle("始终显示顶部按钮", isOn: $toolbarAlwaysVisible)
            }
            Section("歌词") {
                Toggle("显示歌词", isOn: $showLyrics)
                Toggle("修正歌词标题", isOn: $correctLyricTitles)
                    .onChange(of: correctLyricTitles) { _, _ in model.refreshDisplayPresentation() }
                Toggle("歌词交错动效", isOn: $staggerLyricMotion)
                if staggerLyricMotion { lyricStaggerControl }
            }
        }
    }

    private var aboutForm: some View {
        Form {
            Section {
                LabeledContent("版本", value: version)
                LabeledContent("开源许可", value: "AGPL-3.0-only")
            } header: {
                Text(verbatim: "FusionPlay")
            }
            if let url = URL(string: "https://github.com/ZrimYoung/FusionPlay") {
                Section {
                    Link(destination: url) {
                        Label("项目主页", systemImage: "arrow.up.right")
                    }
                }
            }
        }
    }

    private var version: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return version }
        return "\(version) (\(build))"
    }

    private var lyricStaggerControl: some View {
        let range = LyricReflowTiming.staggerRange
        let millis = LyricReflowTiming.clampedStaggerMilliseconds(lyricStaggerMilliseconds)
        let value = Text(verbatim: "\(millis) ms").monospacedDigit()

        return VStack(alignment: .leading, spacing: 7) {
            LabeledContent("交错时间跨度") { value }
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(LyricReflowTiming.clampedStaggerMilliseconds(lyricStaggerMilliseconds)) },
                    set: { lyricStaggerMilliseconds = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(LyricReflowTiming.staggerStep)
            )
            .accessibilityLabel("交错时间跨度")
            .accessibilityValue(value)
            .accessibilityHint("可见歌词从上到下的最大动效时差")
        }
    }

    private func saveName() {
        guard model.initialized, validName, !model.busy else { return }
        editingName = false
        model.saveName(trimmedName)
    }
}
