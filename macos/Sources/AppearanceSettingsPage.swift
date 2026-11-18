import AppKit
import SwiftUI

/// Compact native preferences shared by the settings window's navigation layouts.
struct AppearanceSettingsPage: View {
    var onTitleCorrectionChanged: () -> Void = {}
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("playerControlsAlwaysVisible") private var controlsAlwaysVisible = false
    @AppStorage("playerWindowPinned") private var pinned = false
    @AppStorage("playerShowsPinButton") private var showPinButton = false
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @AppStorage("playerShowsProgress") private var showProgress = true
    @AppStorage("uiCorrectLyricTitles") private var correctLyricTitles = false
    @AppStorage("playerLyricsDisplayMode") private var lyricsDisplayMode = "automatic"
    @AppStorage("playerProgressColorMode") private var progressColorMode = "white"
    @AppStorage("playerProgressCustomHex") private var customHex = PlayerAppearance.defaultCustomHex
    @AppStorage(MenuPanelBackgroundStyle.storageKey) private var menuBackgroundStyle = MenuPanelBackgroundStyle.defaultValue.rawValue
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTypography) private var typography

    var body: some View {
        Form {
            playbackSection
            LyricsStaggerSettingsSection()
            miniPlayerSection
            menuPanelSection
            FontSettingsSection()
            appAccessSection
            Section(L("语言")) {
                Picker(L("界面语言"), selection: $language) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, Locale(identifier: language))
    }

    private var playbackSection: some View {
        Section(L("播放显示")) {
            Toggle(L("播放控制"), isOn: $showPlaybackControls)
            Toggle(L("进度与时间"), isOn: $showProgress)
            Picker(L("歌词"), selection: $lyricsDisplayMode) {
                ForEach(LyricsDisplayMode.allCases, id: \.rawValue) { mode in
                    Text(L(mode.title)).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .help(L("自动：有歌词时显示，无歌词时隐藏。歌词由手机提供。"))
            Toggle(L("修正歌词标题"), isOn: $correctLyricTitles)
                .onChange(of: correctLyricTitles) { _, _ in onTitleCorrectionChanged() }
                .help(L("手机用歌词更新歌名时，尝试恢复真实歌名；无法确认时保留原始信息。"))
            Picker(L("进度条颜色"), selection: $progressColorMode) {
                ForEach(ProgressColorMode.allCases, id: \.rawValue) { mode in
                    Text(L(mode.title)).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            if progressColorMode == "custom" {
                ColorPicker(L("自定义颜色"), selection: customColor, supportsOpacity: false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: progressColorMode)
    }

    private var miniPlayerSection: some View {
        Section(L("迷你播放器")) {
            Picker(L("控件显示"), selection: $controlsAlwaysVisible) {
                Text(L("悬浮显示")).tag(false)
                Text(L("始终显示")).tag(true)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            Toggle(L("窗口置顶"), isOn: $pinned)
            // Pinning and the optional pin control are independent preferences.
            Toggle(L("置顶按钮"), isOn: $showPinButton)
        }
    }

    private var menuPanelSection: some View {
        Section {
            Picker(L("背景样式"), selection: Binding(
                get: { MenuPanelBackgroundStyle.resolve(menuBackgroundStyle).rawValue },
                set: { menuBackgroundStyle = $0 }
            )) {
                ForEach(MenuPanelBackgroundStyle.choices, id: \.rawValue) { style in
                    Text(L(style.title)).tag(style.rawValue)
                }
            }.pickerStyle(.menu).controlSize(.small)
        } header: {
            Text(L("菜单面板"))
        } footer: {
            if !MenuPanelBackgroundStyle.supportsLiquidGlass {
                Text(L("液态玻璃需要 macOS 26 或更高版本。"))
            }
        }
    }
    private var appAccessSection: some View {
        Section {
            Toggle(L("Dock 图标"), isOn: $showDockIcon)
                .onChange(of: showDockIcon) { _, visible in applyDockVisibility(visible) }
            Toggle(L("菜单栏图标"), isOn: $showMenuBarIcon)
        } header: {
            Text(L("应用入口"))
        } footer: {
            if !showDockIcon && !showMenuBarIcon {
                Text(L("两个入口都隐藏时，再次打开应用可进入设置。"))
            }
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: PlayerAppearance.nsColor(hex: customHex)) },
            set: { customHex = PlayerAppearance.hex($0) }
        )
    }
}
