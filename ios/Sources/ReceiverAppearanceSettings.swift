import SwiftUI
import UIKit

struct ReceiverProgressColorSettings: View {
    @AppStorage(ReceiverProgressAppearance.modeKey) private var mode: ReceiverProgressColorMode = .white
    @AppStorage(ReceiverProgressAppearance.customColorKey) private var customHex = ReceiverProgressAppearance.defaultCustomHex

    var body: some View {
        Picker("进度条颜色", selection: $mode) {
            ForEach(ReceiverProgressColorMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        if mode == .custom {
            ColorPicker("自定义颜色", selection: customColor, supportsOpacity: false)
        }
    }

    private var customColor: Binding<Color> {
        Binding(get: { ReceiverProgressAppearance.color(from: customHex) },
                set: { if let hex = ReceiverProgressAppearance.hex(from: $0) { customHex = hex } })
    }
}

struct ReceiverBackdropBlurSettings: View {
    @AppStorage(ReceiverBackdropAppearance.blurKey) private var blurPercent = ReceiverBackdropAppearance.defaultBlurPercent

    var body: some View {
        let range = ReceiverBackdropAppearance.blurRange
        let percent = ReceiverBackdropAppearance.clampedBlurPercent(blurPercent)
        let value = Text(Double(percent) / 100, format: .percent.precision(.fractionLength(0)))
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("背景模糊程度") { value.monospacedDigit() }
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(ReceiverBackdropAppearance.clampedBlurPercent(blurPercent)) },
                    set: { blurPercent = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .accessibilityLabel("背景模糊程度")
            .accessibilityValue(value)
        }
    }
}

struct ReceiverLyricsShadowSettings: View {
    @AppStorage(LyricsShadowAppearance.enabledKey) private var enabled = false
    @AppStorage(LyricsShadowAppearance.opacityKey) private var opacity = LyricsShadowAppearance.defaultOpacity
    @AppStorage(LyricsShadowAppearance.spreadKey) private var spread = LyricsShadowAppearance.defaultSpread

    var body: some View {
        Toggle("歌词投影", isOn: $enabled)
        if enabled {
            let percent = LyricsShadowAppearance.clamp(opacity, to: LyricsShadowAppearance.opacityRange)
            let points = LyricsShadowAppearance.clamp(spread, to: LyricsShadowAppearance.spreadRange)
            control("投影浓度", value: $opacity, range: LyricsShadowAppearance.opacityRange,
                    readout: Text(Double(percent) / 100, format: .percent.precision(.fractionLength(0))))
            control("投影弥散", value: $spread, range: LyricsShadowAppearance.spreadRange,
                    readout: Text(verbatim: "\(points) pt"))
        }
    }

    private func control(_ label: LocalizedStringKey, value: Binding<Int>,
                         range: ClosedRange<Int>, readout: Text) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent(label) { readout.monospacedDigit() }
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(LyricsShadowAppearance.clamp(value.wrappedValue, to: range)) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .accessibilityLabel(Text(label))
            .accessibilityValue(readout)
        }
    }
}

struct ReceiverFontSettingsSection: View {
    @AppStorage(ReceiverTypography.familyKey) private var family = ""
    @State private var showingFonts = false

    var body: some View {
        Section("字体") {
            Button { showingFonts = true } label: {
                LabeledContent("播放器字体") {
                    if family.isEmpty { Text("系统字体") }
                    else { Text(verbatim: family) }
                }
            }
        }
        .sheet(isPresented: $showingFonts) { ReceiverFontSettings() }
    }
}

private struct ReceiverFontSettings: View {
    @AppStorage(ReceiverTypography.familyKey) private var family = ""
    @AppStorage(ReceiverTypography.faceKey) private var face = ""
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFamily = false

    var body: some View {
        NavigationStack {
            let typography = ReceiverTypography(face: face)
            Form {
                Section {
                    Button { choosingFamily = true } label: {
                        LabeledContent("字族") {
                            if family.isEmpty { Text("系统字体") }
                            else { Text(verbatim: family) }
                        }
                    }
                    if !family.isEmpty {
                        let available = ReceiverFontFace.faces(for: family)
                        if !available.isEmpty {
                            Picker("字体样式", selection: $face) {
                                if !available.contains(where: { $0.id == face }) {
                                    Text("系统字体").tag(face)
                                }
                                ForEach(available) { option in Text(verbatim: option.title).tag(option.id) }
                            }
                        }
                    }
                    if !family.isEmpty && typography.face == nil {
                        Text("字体不可用，正在使用系统字体。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("字体预览") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: "音乐响起").font(typography.font(.title2, size: 22, weight: .bold))
                        Text(verbatim: "Music begins · 0123456789").font(typography.font(.body, size: 17, weight: .regular))
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
                Section {
                    Button("恢复默认字体") { chooseFamily("") }
                        .disabled(family.isEmpty && face.isEmpty)
                }
            }
            .navigationTitle("播放器字体")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $choosingFamily) {
                ReceiverFontFamilyPicker(selection: family, onSelect: chooseFamily)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func chooseFamily(_ name: String) {
        if name != family {
            family = name
            face = ReceiverFontFace.preferred(for: name)?.id ?? ""
        } else if name.isEmpty {
            face = ""
        }
        choosingFamily = false
    }
}

private struct ReceiverFontFamilyPicker: View {
    let selection: String
    let onSelect: (String) -> Void

    @Environment(\.locale) private var locale
    @State private var search = ""
    @State private var families: [String] = []

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var systemFontMatches: Bool {
        query.isEmpty || String(localized: "系统字体", locale: locale).localizedStandardContains(query)
    }

    var body: some View {
        let matching = query.isEmpty ? families : families.filter { $0.localizedStandardContains(query) }
        List {
            if systemFontMatches {
                familyRow("")
            }
            ForEach(matching, id: \.self) { name in
                familyRow(name)
            }
            if !systemFontMatches && matching.isEmpty {
                Text("未找到匹配的字体").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("字族")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索字体")
        .onAppear { families = UIFont.familyNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    private func familyRow(_ name: String) -> some View {
        Button { onSelect(name) } label: {
            HStack {
                ReceiverFontFamilyLabel(name: name).foregroundStyle(.primary)
                Spacer()
                if selection == name {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selection == name ? .isSelected : [])
    }
}

private struct ReceiverFontFamilyLabel: View {
    let name: String

    var body: some View {
        if name.isEmpty {
            Text("系统字体")
        } else {
            // Resolve the face when SwiftUI renders this row, without previewing the whole catalog up front.
            let preview = ReceiverFontFace.preferred(for: name)
            Text(verbatim: name)
                .font(preview.map { .custom($0.id, size: 17, relativeTo: .body) } ?? .body)
        }
    }
}

private struct ReceiverFontFace: Identifiable {
    let id: String
    let title: String

    static func preferred(for family: String) -> Self? {
        let available = faces(for: family)
        return available.first { $0.title.caseInsensitiveCompare("Regular") == .orderedSame }
            ?? available.first
    }

    static func faces(for family: String) -> [Self] {
        guard !family.isEmpty else { return [] }
        return UIFont.fontNames(forFamilyName: family).compactMap { name in
            guard let font = UIFont(name: name, size: 17) else { return nil }
            let style = font.fontDescriptor.object(forKey: .face) as? String
            return Self(id: name, title: style ?? name)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
