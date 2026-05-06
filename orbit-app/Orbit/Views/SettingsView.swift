import SwiftUI

// MARK: - Settings Category

enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance = "外观"
    case terminal = "终端"
    case keybindings = "快捷键"
    case keywords = "关键词高亮"
    case ai = "AI 助手"
    case connection = "连接"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance:  return "paintpalette"
        case .terminal:    return "apple.terminal"
        case .keybindings: return "keyboard"
        case .keywords:    return "text.word.spacing"
        case .ai:          return "sparkles"
        case .connection:  return "network"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedCategory: SettingsCategory = .appearance

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 170)
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { category in
                Button(action: { selectedCategory = category }) {
                    Label(category.rawValue, systemImage: category.icon)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            selectedCategory == category
                                ? Color.primary.opacity(0.08)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
    }

    @ViewBuilder
    private var contentArea: some View {
        switch selectedCategory {
        case .appearance:  AppearancePane()
        case .terminal:    TerminalPane()
        case .keybindings: KeybindingsPane()
        case .keywords:    KeywordsPane()
        case .ai:          AIPane()
        case .connection:  ConnectionPane()
        }
    }
}

// MARK: - Appearance Pane

private struct AppearancePane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("外观", "选择终端主题配色")

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 10)
                ], spacing: 10) {
                    ForEach(displayThemes) { theme in
                        ThemeCard(theme: theme, isSelected: appState.theme.rawValue == theme.id) {
                            if let t = AppTheme(rawValue: theme.id) {
                                appState.setTheme(t)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button(action: openThemesFolder) {
                        Label("打开主题文件夹", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private var displayThemes: [OrbitTheme] {
        let loaded = ThemeManager.shared.themes
        return loaded.isEmpty ? OrbitTheme.allBuiltIn : loaded
    }

    private func openThemesFolder() {
        let path = ThemeManager.shared.userThemesPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - Terminal Pane

private struct TerminalPane: View {
    @AppStorage("fontSize") private var fontSize: Double = 14
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"
    @AppStorage("cursorStyle") private var cursorStyle: String = "bar"
    @AppStorage("useMetalRenderer") private var useMetalRenderer: Bool = false
    @AppStorage("backgroundBlur") private var backgroundBlur: Bool = false
    @AppStorage("fontLigatures") private var fontLigatures: Bool = false
    @AppStorage("selectToCopy") private var selectToCopy: Bool = true
    @AppStorage("scrollbackLines") private var scrollbackLines: Int = 10000

    private static let cachedMonoFonts: [String] = loadMonoFonts()
    private var monoFonts: [String] { Self.cachedMonoFonts }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader("终端", "字体、渲染与交互行为")

                SettingsGroup("字体") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledRow("字体家族") {
                            Picker("", selection: $fontFamily) {
                                ForEach(monoFonts, id: \.self) { name in Text(name).tag(name) }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 200)
                        }

                        LabeledRow("字体大小") {
                            Slider(value: $fontSize, in: 10...24, step: 1).frame(width: 180)
                            Text("\(Int(fontSize))px")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        SettingsToggle("字体连字", isOn: $fontLigatures)

                        Text("ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789")
                            .font(.custom(fontFamily, size: fontSize))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }

                SettingsGroup("光标与显示") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledRow("光标样式") {
                            Picker("", selection: $cursorStyle) {
                                Text("竖线").tag("bar")
                                Text("方块").tag("block")
                                Text("下划线").tag("underline")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                        LabeledRow("滚动缓冲") {
                            Slider(value: Binding(get: { Double(scrollbackLines) },
                                                  set: { scrollbackLines = Int($0) }),
                                   in: 1000...50000, step: 1000)
                                .frame(width: 180)
                            Text("\(scrollbackLines) 行")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsGroup("交互") {
                    SettingsToggle("选中即复制", isOn: $selectToCopy)
                    SettingsToggle("背景模糊", isOn: $backgroundBlur)
                    SettingsToggle("Metal GPU 渲染", isOn: $useMetalRenderer)
                }

                SettingsGroup("快速终端") {
                    LabeledRow("快捷键") {
                        Text("^` (Ctrl + `)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }

    private static func loadMonoFonts() -> [String] {
        var names = Set<String>()
        for family in NSFontManager.shared.availableFontFamilies {
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family) as? [[Any]]
            for member in (members ?? []) {
                guard member.count >= 1, let name = member[0] as? String else { continue }
                let font = NSFont(name: name, size: 14)
                if font?.isFixedPitch == true { names.insert(family); break }
            }
        }
        let sorted = names.sorted()
        return sorted.contains("Menlo") ? sorted : ["Menlo"] + sorted
    }
}

// MARK: - Keybindings Pane

private struct KeybindingsPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("快捷键", "自定义键盘操作")

                let actions = KeyBindings.shared.allActions()
                ForEach(actions, id: \.action) { item in
                    HStack {
                        Text(actionLabel(for: item.action)).font(.system(size: 13))
                        Spacer()
                        Text(item.binding.displayString)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(.vertical, 2)
                }

                Divider()
                Button("恢复默认快捷键") { KeyBindings.shared.resetToDefaults() }
                    .font(.system(size: 12))
            }
            .padding(24)
        }
    }

    private func actionLabel(for action: String) -> String {
        switch action {
        case "spotlight": return "Spotlight 搜索"
        case "settings": return "打开设置"
        case "newTerminal": return "新建终端"
        case "toggleSftp": return "SFTP 侧栏"
        case "findInTerminal": return "查找"
        case "clearScreen": return "清屏"
        case "reconnect": return "重新连接"
        case "splitHorizontal": return "水平分屏"
        case "splitVertical": return "垂直分屏"
        case "closePane": return "关闭窗格"
        case "navPrevPane": return "上一个窗格"
        case "navNextPane": return "下一个窗格"
        case "navLeftPane": return "左侧窗格"
        case "navRightPane": return "右侧窗格"
        case "growPane": return "扩大窗格"
        case "shrinkPane": return "缩小窗格"
        default: return action
        }
    }
}

// MARK: - Keywords Pane

private struct KeywordsPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("关键词高亮", "在终端输出中高亮匹配的关键词")

                SettingsGroup("已启用的关键词") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(appState.keywordHighlights.enumerated()), id: \.element.id) { _, kw in
                            HStack {
                                Circle()
                                    .fill(Color(hex: kw.colorHex) ?? .yellow)
                                    .frame(width: 10, height: 10)
                                Text(kw.pattern)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 120, alignment: .leading)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { kw.enabled },
                                    set: { appState.updateKeyword(id: kw.id, pattern: kw.pattern, colorHex: kw.colorHex, enabled: $0) }
                                ))
                                .toggleStyle(.switch)
                            }
                            .frame(height: 24)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("自定义关键词请在 UserDefaults \"keywordHighlights\" 中配置正则模式与颜色")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Button("恢复默认关键词") {
                        appState.keywordHighlights = KeywordHighlight.defaults
                        appState.saveKeywords()
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(24)
        }
    }
}

// MARK: - AI Pane

private struct AIPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("AI 助手", "接入 OpenAI 兼容接口辅助排障")

                SettingsGroup("基本设置") {
                    LabeledRow("启用 AI 面板") {
                        Toggle("", isOn: Binding(
                            get: { appState.aiConfig.enabled },
                            set: { appState.aiConfig.enabled = $0; appState.saveAIConfig() }
                        ))
                        .toggleStyle(.switch)
                    }
                }

                SettingsGroup("连接配置") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledRow("API 地址") {
                            TextField("https://api.openai.com/v1", text: Binding(
                                get: { appState.aiConfig.endpoint },
                                set: { appState.aiConfig.endpoint = $0; appState.saveAIConfig() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 260)
                        }
                        LabeledRow("API Key") {
                            SecureField("sk-...", text: Binding(
                                get: { appState.aiConfig.apiKey },
                                set: { appState.aiConfig.apiKey = $0; appState.saveAIConfig() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 260)
                        }
                        LabeledRow("模型") {
                            TextField("gpt-4o", text: Binding(
                                get: { appState.aiConfig.model },
                                set: { appState.aiConfig.model = $0; appState.saveAIConfig() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 160)
                        }
                    }
                    Text("支持 OpenAI、DeepSeek、Qwen、Kimi、ollama 等兼容接口")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Connection Pane

private struct ConnectionPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("连接", "SSH 连接与重连配置")

                SettingsGroup("超时与重连") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledRow("默认超时") {
                            Text("10s").font(.system(size: 12))
                        }
                        LabeledRow("重连策略") {
                            Text("自动重连").font(.system(size: 12))
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Shared Components

private struct SettingsHeader: View {
    let title: String
    let subtitle: String
    init(_ title: String, _ subtitle: String) {
        self.title = title; self.subtitle = subtitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.content = content
    }
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            content()
        }
    }
}

private struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool
    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label; self._isOn = isOn
    }
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch)
        }
        .frame(height: 24)
    }
}

// MARK: - Theme Card

private struct ThemeCard: View {
    let theme: OrbitTheme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(
                            colors: [
                                Color(red: theme.colors.background.red, green: theme.colors.background.green, blue: theme.colors.background.blue),
                                Color(red: theme.colors.windowBg.red, green: theme.colors.windowBg.green, blue: theme.colors.windowBg.blue),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(height: 52)
                        .overlay(
                            HStack(spacing: 3) {
                                ForEach(0..<8, id: \.self) { i in
                                    Circle()
                                        .fill(Color(
                                            red: Double(theme.colors.ansi[i].red) / 65535.0,
                                            green: Double(theme.colors.ansi[i].green) / 65535.0,
                                            blue: Double(theme.colors.ansi[i].blue) / 65535.0
                                        ))
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .padding(.top, 26)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                        lineWidth: isSelected ? 2 : 1)
                        )
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(.white).padding(-2))
                    }
                }
                Text(theme.name)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
