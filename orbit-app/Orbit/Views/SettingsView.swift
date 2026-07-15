import SwiftUI

// MARK: - Settings Category

enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance = "外观"
    case terminal = "终端"
    case keybindings = "快捷键"
    case keywords = "关键词高亮"
    case ai = "AI 助手"
    case connection = "连接"
    case monitor = "监控"
    case database = "数据库"
    case exportImport = "导入导出"
    case portForwarding = "端口转发"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance:    return "paintpalette"
        case .terminal:      return "apple.terminal"
        case .keybindings:   return "keyboard"
        case .keywords:      return "text.word.spacing"
        case .ai:            return "sparkles"
        case .connection:    return "network"
        case .monitor:       return "gauge.with.dots.needle.33percent"
        case .database:      return "cylinder"
        case .exportImport:  return "arrow.triangle.pull"
        case .portForwarding: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    let appState: AppState
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
                .accessibilityLabel(category.rawValue)
                .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
            }
            Spacer()
        }
        .padding(8)
    }

    @ViewBuilder
    private var contentArea: some View {
        switch selectedCategory {
        case .appearance:    AppearancePane(appState: appState)
        case .terminal:      TerminalPane()
        case .keybindings:   KeybindingsPane()
        case .keywords:      KeywordsPane(appState: appState)
        case .ai:            AIPane(appState: appState)
        case .connection:    ConnectionPane()
        case .monitor:       MonitorPane()
        case .database:      DatabasePane()
        case .exportImport:  ExportImportPane(appState: appState)
        case .portForwarding: PortForwardingPane(appState: appState)
        }
    }
}

// MARK: - Appearance Pane

private struct AppearancePane: View {
    let appState: AppState
    @EnvironmentObject var themeState: ThemeState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("外观", "选择终端主题配色")

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 10)
                ], spacing: 10) {
                    ForEach(displayThemes) { theme in
                        ThemeCard(theme: theme, isSelected: themeState.theme.rawValue == theme.id) {
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
    @AppStorage("fontFamily") private var fontFamily: String = TerminalRenderSettings.defaultFontName
    @AppStorage("cursorStyle") private var cursorStyle: String = "bar"
    @AppStorage("useMetalRenderer") private var useMetalRenderer: Bool = false
    @AppStorage("backgroundBlur") private var backgroundBlur: Bool = false
    @AppStorage("fontLigatures") private var fontLigatures: Bool = false
    @AppStorage("selectToCopy") private var selectToCopy: Bool = true
    @AppStorage("scrollbackLines") private var scrollbackLines: Int = 10000

    private static let cachedMonoFonts: [String] = TerminalRenderSettings.availableTerminalFonts()
    private var monoFonts: [String] { Self.cachedMonoFonts }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader("终端", "字体、渲染与交互行为")

                SettingsGroup("字体") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledRow("渲染字体") {
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

                        Text(" sunyang  ~/dev  23:19  ABC abc 012")
                            .font(.custom(fontFamily, size: fontSize))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        Text("如果提示符里的图标显示为问号，请选择 MesloLGS NF、JetBrainsMono Nerd Font Mono 或其他 Nerd Font。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
}

// MARK: - Keybindings Pane

private struct KeybindingsPane: View {
    @State private var recordingAction: String? = nil
    @State private var recordingKey: String = ""
    @State private var recordingModifiers: KeyBinding.Modifiers = .init()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("快捷键", "点击快捷键开始录制新组合键")

                if recordingAction != nil {
                    recordingOverlay
                }

                let actions = KeyBindings.shared.allActions()
                ForEach(actions, id: \.action) { item in
                    Button(action: { startRecording(item.action) }) {
                        HStack {
                            Text(actionLabel(for: item.action)).font(.system(size: 13))
                            Spacer()
                            Text(item.binding.displayString)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(recordingAction == item.action ? Color.accentColor : Color.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(
                                    recordingAction == item.action
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.primary.opacity(0.06)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                Button("恢复默认快捷键") { KeyBindings.shared.resetToDefaults() }
                    .font(.system(size: 12))
            }
            .padding(24)
        }
        .background(KeyCaptureView { event in
            guard let action = recordingAction else { return }
            let mods = KeyBinding.Modifiers(flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            guard !mods.isEmpty || event.keyCode == 0x35 else { return }
            let key: String
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                key = chars.lowercased()
            } else if let special = specialKeyName(event.keyCode) {
                key = special
            } else {
                return
            }
            KeyBindings.shared.setBinding(action: action, key: key, modifiers: mods)
            recordingAction = nil
        })
    }

    private var recordingOverlay: some View {
        return HStack {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            Text("正在录制快捷键... 请按下组合键")
                .font(.system(size: 12))
            Spacer()
            Button("取消") { recordingAction = nil }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func startRecording(_ action: String) {
        recordingAction = action
    }

    private func specialKeyName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 126: return "\u{1b}" // Up
        case 125: return "\u{1c}" // Down
        case 123: return "\u{1d}" // Left
        case 124: return "\u{1e}" // Right
        case 0x33: return "\u{7f}" // Delete
        case 0x24: return "\r"    // Return
        case 0x30: return "\t"    // Tab
        case 0x35: return "\u{1b}" // Escape
        case 0x31: return " "     // Space
        default: return nil
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

private struct KeyCaptureView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

private class KeyCaptureNSView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }
}

// MARK: - Keywords Pane

private struct KeywordsPane: View {
    let appState: AppState
    @EnvironmentObject var themeState: ThemeState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("关键词高亮", "在终端输出中高亮匹配的关键词")

                SettingsGroup("已启用的关键词") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(themeState.keywordHighlights.enumerated()), id: \.element.id) { _, kw in
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
                        themeState.keywordHighlights = KeywordHighlight.defaults
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
    let appState: AppState
    @EnvironmentObject var aiState: AIState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("AI 助手", "接入 OpenAI 兼容接口辅助排障")

                SettingsGroup("基本设置") {
                    LabeledRow("启用 AI 面板") {
                        Toggle("", isOn: Binding(
                            get: { aiState.aiConfig.enabled },
                            set: { aiState.aiConfig.enabled = $0; appState.saveAIConfig() }
                        ))
                        .toggleStyle(.switch)
                    }
                }

                SettingsGroup("连接配置") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledRow("API 地址") {
                            TextField("https://api.openai.com/v1", text: Binding(
                                get: { aiState.aiConfig.endpoint },
                                set: { aiState.aiConfig.endpoint = $0; appState.saveAIConfig() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 260)
                        }
                        LabeledRow("API Key") {
                            SecureField("sk-...", text: Binding(
                                get: { aiState.aiConfig.apiKey },
                                set: { aiState.aiConfig.apiKey = $0; appState.saveAIConfig() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 260)
                        }
                        LabeledRow("模型") {
                            TextField("gpt-4o", text: Binding(
                                get: { aiState.aiConfig.model },
                                set: { aiState.aiConfig.model = $0; appState.saveAIConfig() }
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
    @AppStorage("sshTimeout") private var sshTimeout: Double = 10
    @AppStorage("sshReconnectEnabled") private var sshReconnectEnabled: Bool = true
    @AppStorage("sshReconnectInterval") private var sshReconnectInterval: Double = 3
    @AppStorage("sshKeepaliveInterval") private var sshKeepaliveInterval: Double = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("连接", "SSH 连接与重连配置")

                SettingsGroup("超时与重连") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledRow("连接超时") {
                            Slider(value: $sshTimeout, in: 3...60, step: 1).frame(width: 160)
                            Text("\(Int(sshTimeout))s")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        SettingsToggle("自动重连", isOn: $sshReconnectEnabled)
                        if sshReconnectEnabled {
                            LabeledRow("重连间隔") {
                                Slider(value: $sshReconnectInterval, in: 1...30, step: 1).frame(width: 160)
                                Text("\(Int(sshReconnectInterval))s")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                SettingsGroup("心跳保活") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledRow("心跳间隔") {
                            Slider(value: $sshKeepaliveInterval, in: 0...300, step: 10).frame(width: 160)
                            Text(sshKeepaliveInterval == 0 ? "关闭" : "\(Int(sshKeepaliveInterval))s")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("0 表示关闭心跳，设置为每 N 秒发送一次 keepalive 包")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Monitor Pane

private struct MonitorPane: View {
    @AppStorage("monitorRefreshInterval") private var monitorRefreshInterval: Double = 3
    @AppStorage("monitorDiskThreshold") private var monitorDiskThreshold: Double = 80
    @AppStorage("monitorHistoryPoints") private var monitorHistoryPoints: Double = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("监控", "资源监控采集配置")

                SettingsGroup("采集频率") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledRow("刷新间隔") {
                            Slider(value: $monitorRefreshInterval, in: 1...10, step: 1).frame(width: 160)
                            Text("\(Int(monitorRefreshInterval))s")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("设置 CPU / 内存 / 磁盘 / 网络数据的采集间隔")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }

                SettingsGroup("告警阈值") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledRow("磁盘告警") {
                            Slider(value: $monitorDiskThreshold, in: 50...99, step: 1).frame(width: 160)
                            Text("\(Int(monitorDiskThreshold))%")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(monitorDiskThreshold >= 90 ? .red : .secondary)
                        }
                    }
                    Text("磁盘使用率超过该值时高亮提示")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }

                SettingsGroup("趋势图") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledRow("保留数据点") {
                            Slider(value: $monitorHistoryPoints, in: 10...300, step: 10).frame(width: 160)
                            Text("\(Int(monitorHistoryPoints))")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("趋势图中保留的历史数据点数量")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Database Pane

private struct DatabasePane: View {
    @AppStorage("dbDefaultLimit") private var dbDefaultLimit: Double = 200
    @AppStorage("dbQueryTimeout") private var dbQueryTimeout: Double = 30
    @AppStorage("dbReadOnlyMode") private var dbReadOnlyMode: Bool = false
    @AppStorage("dbAutoLimit") private var dbAutoLimit: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("数据库", "SQLite 查询默认值")

                SettingsGroup("查询设置") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsToggle("自动添加 LIMIT", isOn: $dbAutoLimit)
                        if dbAutoLimit {
                            LabeledRow("默认 LIMIT") {
                                Slider(value: $dbDefaultLimit, in: 10...1000, step: 10).frame(width: 160)
                                Text("\(Int(dbDefaultLimit))")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledRow("查询超时") {
                            Slider(value: $dbQueryTimeout, in: 5...120, step: 5).frame(width: 160)
                            Text("\(Int(dbQueryTimeout))s")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsGroup("安全") {
                    SettingsToggle("只读模式", isOn: $dbReadOnlyMode)
                    Text("只读模式下禁止执行 INSERT / UPDATE / DELETE 等写操作")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Export / Import Pane

private struct ExportImportPane: View {
    let appState: AppState
    @State private var exportResult: String = ""
    @State private var importResult: String = ""
    @State private var strategy: ImportStrategy = .skipExisting

    enum ImportStrategy: String, CaseIterable {
        case skipExisting = "跳过重复"
        case overwrite = "覆盖所有"

        var value: Int32 {
            switch self {
            case .skipExisting: return 0
            case .overwrite: return 1
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("导入导出", "备份/迁移服务器配置与凭据")

                SettingsGroup("导出配置") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("将当前所有服务器与凭据分组导出为 JSON 文件。密码和私钥以解密后的明文导出，请注意安全保管。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        HStack {
                            Button(action: performExport) {
                                Label("导出配置", systemImage: "square.and.arrow.up")
                            }

                            if !exportResult.isEmpty {
                                Text(exportResult)
                                    .font(.system(size: 11))
                                    .foregroundStyle(exportResult.contains("成功") ? .green : .red)
                            }
                        }
                    }
                }

                SettingsGroup("导入配置") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("从 JSON 文件导入服务器与凭据分组配置。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            LabeledRow("合并策略") {
                                Picker("", selection: $strategy) {
                                    ForEach(ImportStrategy.allCases, id: \.rawValue) { s in
                                        Text(s.rawValue).tag(s)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 180)
                            }
                            Text(strategy == .skipExisting
                                ? "同名主机将被跳过，不覆盖已有配置"
                                : "同名主机将被新配置覆盖"
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        }

                        HStack {
                            Button(action: performImport) {
                                Label("导入配置", systemImage: "square.and.arrow.down")
                            }

                            if !importResult.isEmpty {
                                Text(importResult)
                                    .font(.system(size: 11))
                                    .foregroundStyle(importResult.contains("成功") ? .green : .red)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func performExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "orbit-config-\(isoDateString()).json"
        panel.beginSheetModal(for: NSApp.keyWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let json = try appState.bridge.exportConfig()
                let prettyData = try JSONSerialization.jsonObject(with: Data(json.utf8))
                let pretty = try JSONSerialization.data(withJSONObject: prettyData, options: [.prettyPrinted, .sortedKeys])
                try pretty.write(to: url)
                exportResult = "导出成功"
            } catch {
                exportResult = "导出失败: \(error.localizedDescription)"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportResult = "" }
        }
    }

    private func performImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: NSApp.keyWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let json = String(decoding: data, as: UTF8.self)
                let count = try appState.bridge.importConfig(jsonContent: json, strategy: strategy.value)
                importResult = "导入成功: \(count) 项"
                appState.loadServers()
                appState.loadCredentialGroups()
            } catch {
                importResult = "导入失败: \(error.localizedDescription)"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { importResult = "" }
        }
    }

    private func isoDateString() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return f.string(from: Date())
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

// MARK: - Port Forwarding Pane

private struct PortForwardingPane: View {
    let appState: AppState
    @EnvironmentObject var inventoryState: InventoryState
    @State private var showAddSheet = false
    @State private var newServerId: String = ""
    @State private var newLocalPort: String = "8080"
    @State private var newRemoteHost: String = "127.0.0.1"
    @State private var newRemotePort: String = "80"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader("端口转发", "管理本地端口到远端服务的 SSH 隧道 (ssh -L)")

                SettingsGroup("转发规则") {
                    if inventoryState.portForwardRules.isEmpty {
                        Text("暂无线口转发规则")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(inventoryState.portForwardRules) { rule in
                                portForwardRow(rule)
                            }
                        }
                    }

                    Button(action: { showAddSheet = true }) {
                        Label("新增规则", systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showAddSheet) {
            addRuleSheet
        }
    }

    private func portForwardRow(_ rule: PortForwardRule) -> some View {
        let serverName = inventoryState.servers.first(where: { $0.id == rule.serverId })?.name ?? rule.serverId
        return HStack(spacing: 8) {
            Circle()
                .fill(rule.enabled ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.description)
                    .font(.system(size: 11, design: .monospaced))
                Text(serverName)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if rule.enabled {
                Button("关闭") { appState.stopPortForward(rule) }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            } else {
                Button("开启") { appState.startPortForward(rule) }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
            }

            Button(action: { appState.removePortForwardRule(rule) }) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(6)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var addRuleSheet: some View {
        VStack(spacing: 12) {
            Text("新增端口转发规则")
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("服务器").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("", selection: $newServerId) {
                    Text("请选择").tag("")
                    ForEach(inventoryState.servers, id: \.id) { s in
                        Text(s.name).tag(s.id)
                    }
                }
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地端口").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("8080", text: $newLocalPort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 100)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("远端地址").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $newRemoteHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 140)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("远端端口").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("80", text: $newRemotePort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 80)
                }
            }

            HStack {
                Spacer()
                Button("取消") { showAddSheet = false }
                    .font(.system(size: 12))
                Button("添加") {
                    guard !newServerId.isEmpty,
                          let localPort = UInt16(newLocalPort),
                          !newRemoteHost.isEmpty,
                          let remotePort = UInt16(newRemotePort) else { return }
                    appState.addPortForwardRule(
                        serverId: newServerId,
                        localPort: localPort,
                        remoteHost: newRemoteHost,
                        remotePort: remotePort
                    )
                    showAddSheet = false
                    newServerId = ""
                }
                .font(.system(size: 12, weight: .semibold))
                .disabled(newServerId.isEmpty)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .frame(width: 420, height: 260)
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
