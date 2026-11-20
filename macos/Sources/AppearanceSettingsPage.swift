import AppKit
import SwiftUI

private enum AppearanceSettingsCategory: String, CaseIterable {
    case player, lyrics, general
    var title: String {
        switch self { case .player: return "播放器"; case .lyrics: return "歌词"; case .general: return "通用" }
    }
}

/// Compact native preferences shared by the settings window's navigation layouts.
struct AppearanceSettingsPage: View {
    var onTitleCorrectionChanged: () -> Void = {}
    @State private var category = AppearanceSettingsCategory.player
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("playerControlsAlwaysVisible") private var controlsAlwaysVisible = false
    @AppStorage("playerWindowPinned") private var pinned = false
    @AppStorage("playerShowsPinButton") private var showPinButton = false
    @AppStorage("playerShowsTransport") private var legacyPlaybackControls = true
    @AppStorage("playerShowsProgress") private var legacyProgress = true
    @AppStorage("coverPlayerShowsTransport") private var coverPlaybackControls: Bool?
    @AppStorage("albumPlayerShowsTransport") private var albumPlaybackControls: Bool?
    @AppStorage("coverPlayerShowsProgress") private var coverProgress: Bool?
    @AppStorage("albumPlayerShowsProgress") private var albumProgress: Bool?
    @AppStorage("playerShowsLyricsButton") private var showLyricsButton = true
    @AppStorage("wrapPlayerMetadata") private var wrapPlayerMetadata = false
    @AppStorage(NarrowPlayerLayout.storageKey) private var narrowPlayerLayout = NarrowPlayerLayout.original.rawValue
    @AppStorage("coverLyricsExpandedByDragging") private var coverLyricsExpandedByDragging = false
    @AppStorage("lyricsPageShowsArtwork") private var lyricsPageShowsArtwork = true
    @AppStorage("lyricsPageShowsTrackInfo") private var lyricsPageShowsTrackInfo = true
    @AppStorage("uiCorrectLyricTitles") private var correctLyricTitles = false
    @AppStorage("playerLyricsDisplayMode") private var lyricsDisplayMode = "automatic"
    @AppStorage("playerProgressColorMode") private var progressColorMode = "white"
    @AppStorage("playerProgressCustomHex") private var customHex = PlayerAppearance.defaultCustomHex
    @AppStorage(MenuPanelBackgroundStyle.storageKey) private var menuBackgroundStyle = MenuPanelBackgroundStyle.defaultValue.rawValue
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTypography) private var typography

    private var narrowLayout: NarrowPlayerLayout { NarrowPlayerLayout.resolve(narrowPlayerLayout) }
    private var family: PlayerLayoutFamily { PlayerLayoutFamily(layout: narrowLayout) }
    private var selectedFamily: Binding<PlayerLayoutFamily> {
        Binding(get: { family }, set: { selected in
            guard selected != family else { return }
            coverLyricsExpandedByDragging = false
            narrowPlayerLayout = selected.layoutSelection.rawValue
        })
    }
    private var scopedPlaybackControls: Binding<Bool> {
        Binding(get: {
            (family == .cover ? coverPlaybackControls : albumPlaybackControls) ?? legacyPlaybackControls
        }, set: { value in
            if family == .cover { coverPlaybackControls = value }
            else { albumPlaybackControls = value }
        })
    }
    private var scopedProgress: Binding<Bool> {
        Binding(get: { (family == .cover ? coverProgress : albumProgress) ?? legacyProgress }, set: { value in
            if family == .cover { coverProgress = value }
            else { albumProgress = value }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("外观设置"), selection: $category) {
                ForEach(AppearanceSettingsCategory.allCases, id: \.self) { category in
                    Text(L(category.title)).tag(category)
                }
            }.pickerStyle(.segmented).controlSize(.small).labelsHidden()
                .frame(maxWidth: 300)
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                .accessibilityIdentifier("settings.appearance.category")
            Form {
                switch category {
                case .player:
                    layoutSection
                    scopedPlaybackSection
                    playerWindowSection
                    playbackSection
                case .lyrics:
                    lyricsSection
                    LyricsStaggerSettingsSection()
                case .general:
                    menuPanelSection
                    FontSettingsSection()
                    appAccessSection
                    languageSection
                }
            }.formStyle(.grouped).id(category)
        }
        .environment(\.locale, Locale(identifier: language))
    }

    private var layoutSection: some View {
        Section {
            Picker(L("窄窗布局"), selection: selectedFamily) {
                ForEach(PlayerLayoutFamily.allCases, id: \.self) { family in
                    Text(L(family.title)).tag(family)
                }
            }.pickerStyle(.segmented).controlSize(.small)
                .accessibilityIdentifier("settings.appearance.layout")
        } header: {
            Text(L("播放器布局"))
        } footer: {
            Text(L("封面模式：拖动底边展开歌词，缩到最小时收起并左右翻页；专辑模式：独立的封面播放页与歌词页。"))
        }
    }

    private var scopedPlaybackSection: some View {
        Section {
            Toggle(L("播放控制"), isOn: scopedPlaybackControls)
                .accessibilityIdentifier("settings.appearance.\(family.rawValue).transport")
            Toggle(L("进度与时间"), isOn: scopedProgress)
                .accessibilityIdentifier("settings.appearance.\(family.rawValue).progress")
            if family == .cover {
                Picker(L("控件显示"), selection: $controlsAlwaysVisible) {
                    Text(L("悬浮显示")).tag(false)
                    Text(L("始终显示")).tag(true)
                }.pickerStyle(.menu).controlSize(.small)
                    .accessibilityIdentifier("settings.appearance.cover.controls")
            } else {
                Toggle(L("歌词页显示小封面"), isOn: $lyricsPageShowsArtwork)
                    .accessibilityIdentifier("settings.appearance.album.lyrics-artwork")
                Toggle(L("歌词页显示歌曲信息"), isOn: $lyricsPageShowsTrackInfo)
                    .accessibilityIdentifier("settings.appearance.album.lyrics-info")
            }
        } header: {
            Text(L(family.title))
        } footer: {
            Text(L("两种模式的播放控制和进度显示分别保存。"))
        }
    }

    private var playerWindowSection: some View {
        Section(L("窗口")) {
            Toggle(L("窗口置顶"), isOn: $pinned)
            Toggle(L("置顶按钮"), isOn: $showPinButton)
        }
    }

    private var playbackSection: some View {
        Section(L("播放显示")) {
            Toggle(L("允许歌曲信息换行"), isOn: $wrapPlayerMetadata)
                .help(L("歌名最多三行，艺人与专辑最多两行；信息高度平滑过渡。"))
            Picker(L("进度条颜色"), selection: $progressColorMode) {
                ForEach(ProgressColorMode.allCases, id: \.rawValue) { mode in
                    Text(L(mode.title)).tag(mode.rawValue)
                }
            }.pickerStyle(.menu).controlSize(.small)
            if progressColorMode == "custom" {
                ColorPicker(L("自定义颜色"), selection: customColor, supportsOpacity: false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: progressColorMode)
    }

    private var lyricsSection: some View {
        Section(L("歌词")) {
            Picker(L("歌词"), selection: Binding(
                get: { (LyricsDisplayMode(rawValue: lyricsDisplayMode) ?? .automatic).rawValue },
                set: { lyricsDisplayMode = $0 }
            )) {
                ForEach(LyricsDisplayMode.allCases, id: \.rawValue) { mode in
                    Text(L(mode.title)).tag(mode.rawValue)
                }
            }.pickerStyle(.menu).controlSize(.small)
                .help(L(family == .cover ? "此设置控制封面模式的歌词展开。收起后仍可左右滑动切换到歌词页。" : "自动：有歌词时显示，无歌词时隐藏。歌词由手机提供。"))
            Toggle(L("歌词快捷按钮"), isOn: $showLyricsButton)
                .help(L("仅临时切换当前歌曲的歌词显示，不改变自动开启或始终关闭设置。"))
            Toggle(L("修正歌词标题"), isOn: $correctLyricTitles)
                .accessibilityIdentifier("settings.appearance.lyrics.title-correction")
                .onChange(of: correctLyricTitles) { _, _ in onTitleCorrectionChanged() }
                .help(L("手机用歌词更新歌名时，尝试恢复真实歌名；无法确认时保留原始信息。"))
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
                .accessibilityIdentifier("settings.appearance.general.menu-material")
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
    private var languageSection: some View {
        Section(L("语言")) {
            Picker(L("界面语言"), selection: $language) {
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }.pickerStyle(.menu).controlSize(.small)
        }
    }
    private var customColor: Binding<Color> {
        Binding(get: { Color(nsColor: PlayerAppearance.nsColor(hex: customHex)) },
                set: { customHex = PlayerAppearance.hex($0) })
    }
}
