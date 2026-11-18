import SwiftUI

/// A self-contained section for the grouped appearance preferences form.
struct FontSettingsSection: View {
    @AppStorage("uiFontFamily") private var family = ""
    @AppStorage("uiFontWeight") private var weight = AppTypography.defaultWeight
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @Environment(\.appTypography) private var typography
    @State private var showingDetails = false
    @State private var showingFamilies = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var selection: AppTypography { AppTypography(family: family, weight: weight) }
    private var effectiveWeight: Int { FontCatalog.nearestWeight(in: selection.availableWeights, to: weight) }
    private var summary: String { familyLabel + " · " + String(effectiveWeight) }
    private var familyLabel: String {
        if family.isEmpty { return text("跟随系统字体", "System font") }
        if selection.isMissing { return family + " · " + text("未安装", "Not installed") }
        guard let choice = FontCatalog.installedFamilies.first(where: {
            $0.name.caseInsensitiveCompare(family) == .orderedSame
        }) else { return family }
        return label(for: choice)
    }
    private var weightBinding: Binding<Int> {
        Binding(get: { effectiveWeight }, set: { weight = $0 })
    }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var systemMatches: Bool {
        query.isEmpty || [text("跟随系统字体", "System font"), "跟随系统字体", "System font"]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
    private var matchingFamilies: [FontFamilyChoice] {
        FontCatalog.installedFamilies.filter { choice in
            query.isEmpty || choice.name.localizedCaseInsensitiveContains(query)
                || choice.label.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Section(text("字体", "Fonts")) {
            Button { showingDetails = true } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(text("界面字体", "Interface font"))
                            .font(typography.font(size: 13))
                        Text(summary)
                            .font(typography.font(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(summary)
                .accessibilityLabel(text("界面字体", "Interface font"))
                .accessibilityValue(summary)
                .accessibilityIdentifier("settings.font.details")
        }
        .sheet(isPresented: $showingDetails, onDismiss: { showingFamilies = false; search = "" }) {
            SettingsDetailPanel(title: text("界面字体", "Interface font")) {
                fontDetails
            }.appTypography()
        }
    }

    private var fontDetails: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        search = ""
                        showingFamilies = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(familyLabel)
                                .font(typography.font(size: 13))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }.frame(width: 210, alignment: .leading)
                    }.buttonStyle(.bordered).controlSize(.small).help(familyLabel)
                        .accessibilityLabel(text("选择界面字体", "Choose interface font"))
                        .popover(isPresented: $showingFamilies, arrowEdge: .bottom) { familyPopover }
                } label: {
                    Text(text("字族", "Font family")).font(typography.font(size: 13))
                }
                Picker(text("字重", "Weight"), selection: weightBinding) {
                    ForEach(selection.availableWeights, id: \.self) { value in
                        Text(weightLabel(value)).tag(value)
                    }
                }.pickerStyle(.menu).controlSize(.small).font(typography.font(size: 13))
            } footer: {
                if selection.isMissing {
                    Text(text("此字体未安装，当前使用系统字体；已保留原来的选择。",
                              "This font is not installed. The system font is used while your original choice is preserved."))
                        .font(typography.font(size: 12)).foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FusionPlay · 让音乐，连接此刻")
                        .font(selection.font(size: 17, weight: .semibold))
                    Text("Music brings us together · 0123456789")
                        .font(selection.font(size: 13))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(text("字体预览", "Font preview"))
            } header: {
                Text(text("字体预览", "Font preview"))
            } footer: {
                Text(text("标题和歌词保留原有字号与字重层级。", "Headings and lyrics keep their existing text sizes and emphasis."))
                    .font(typography.font(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                Button(text("恢复默认字体", "Restore default font")) {
                    family = ""
                    weight = AppTypography.defaultWeight
                }.font(typography.font(size: 13))
                    .disabled(family.isEmpty && weight == AppTypography.defaultWeight)
            }
        }.formStyle(.grouped)
    }

    private var familyPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField(text("搜索字体", "Search fonts"), text: $search)
                    .font(typography.font(size: 13))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        guard !query.isEmpty else { return }
                        if systemMatches { chooseFamily("") }
                        else if let first = matchingFamilies.first { chooseFamily(first.name) }
                    }
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(text("清除搜索", "Clear search"))
                    .accessibilityLabel(text("清除搜索", "Clear search"))
                }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List {
                    if systemMatches {
                        familyRow(name: "", title: text("跟随系统字体", "System font"))
                    }
                    ForEach(matchingFamilies) { choice in
                        familyRow(name: choice.name, title: label(for: choice))
                    }
                    if !systemMatches && matchingFamilies.isEmpty {
                        Text(text("未找到匹配的字体", "No matching fonts"))
                            .font(typography.font(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .listStyle(.plain)
                .frame(height: 280)
                .onAppear {
                    proxy.scrollTo(family, anchor: .center)
                    searchFocused = true
                }
            }
            Divider()
            Text(text("仅显示此 Mac 上已安装的字体。", "Only fonts installed on this Mac are listed."))
                .font(typography.font(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 340)
        .onExitCommand { showingFamilies = false }
    }

    private func familyRow(name: String, title: String) -> some View {
        let selected = name.caseInsensitiveCompare(family) == .orderedSame
        return Button { chooseFamily(name) } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(typography.font(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(name)
        .help(name.isEmpty ? title : name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chooseFamily(_ name: String) {
        // User selection is the only point that normalizes a saved weight.
        let nearest = FontCatalog.nearestWeight(in: FontCatalog.availableWeights(for: name), to: weight)
        family = name
        weight = nearest
        showingFamilies = false
    }

    private func label(for choice: FontFamilyChoice) -> String {
        language == "en" ? choice.name : choice.label
    }

    private func weightLabel(_ value: Int) -> String {
        let name: String
        switch value {
        case 100: name = text("极细", "Ultra light")
        case 200: name = text("特细", "Thin")
        case 300: name = text("细体", "Light")
        case 400: name = text("常规", "Regular")
        case 500: name = text("中等", "Medium")
        case 600: name = text("半粗", "Semibold")
        case 700: name = text("粗体", "Bold")
        case 800: name = text("特粗", "Heavy")
        case 900: name = text("黑体", "Black")
        default: return String(value)
        }
        return name + " (" + String(value) + ")"
    }

    private func text(_ chinese: String, _ english: String) -> String {
        language == "en" ? english : chinese
    }
}
