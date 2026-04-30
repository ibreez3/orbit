import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("fontSize") private var fontSize: Double = 14
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"
    @AppStorage("cursorStyle") private var cursorStyle: String = "bar"
    @AppStorage("useMetalRenderer") private var useMetalRenderer: Bool = false
    @AppStorage("backgroundBlur") private var backgroundBlur: Bool = false
    @AppStorage("fontLigatures") private var fontLigatures: Bool = false
    @AppStorage("selectToCopy") private var selectToCopy: Bool = true
    @AppStorage("scrollbackLines") private var scrollbackLines: Int = 10000

    private let monoFonts = Self.loadMonoFonts()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                appearanceSection
                terminalSection
                keybindingsSection
                connectionSection
            }
            .padding(24)
            .frame(maxWidth: 600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("外观")

            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)
                ], spacing: 12) {
                    ForEach(displayThemes) { theme in
                        themeCard(theme)
                    }
                }
            }
            .frame(maxHeight: 280)

            Button(action: openThemesFolder) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("打开主题文件夹")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var displayThemes: [OrbitTheme] {
        let loaded = ThemeManager.shared.themes
        return loaded.isEmpty ? OrbitTheme.allBuiltIn : loaded
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("终端")

            HStack {
                Text("字体")
                Spacer()
                Picker("", selection: $fontFamily) {
                    ForEach(monoFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 200)
            }

            HStack {
                Text("字体大小")
                Spacer()
                Text("\(Int(fontSize))px")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $fontSize, in: 10...24, step: 1)

            Divider()

            HStack {
                Text("字体连字")
                Spacer()
                Toggle("", isOn: $fontLigatures)
                    .toggleStyle(.switch)
            }

            HStack {
                Text("Metal GPU 渲染")
                Spacer()
                Toggle("", isOn: $useMetalRenderer)
                    .toggleStyle(.switch)
            }

            HStack {
                Text("背景模糊")
                Spacer()
                Toggle("", isOn: $backgroundBlur)
                    .toggleStyle(.switch)
            }

            HStack {
                Text("选中即复制")
                Spacer()
                Toggle("", isOn: $selectToCopy)
                    .toggleStyle(.switch)
            }

            HStack {
                Text("光标样式")
                Spacer()
                Picker("", selection: $cursorStyle) {
                    Text("竖线").tag("bar")
                    Text("方块").tag("block")
                    Text("下划线").tag("underline")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            HStack {
                Text("滚动缓冲")
                Spacer()
                Text("\(scrollbackLines) 行")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: {
                Double(scrollbackLines)
            }, set: { scrollbackLines = Int($0) }), in: 1000...50000, step: 1000)

            Divider()

            HStack {
                Text("快速终端")
                Spacer()
                Text("^` (Ctrl + `)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Font preview
            Text("ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789")
                .font(.custom(fontFamily, size: fontSize))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }

    private var keybindingsSection: some View {
        let actions = KeyBindings.shared.allActions()
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("快捷键")
            ForEach(actions, id: \.action) { item in
                HStack {
                    Text(actionLabel(for: item.action))
                        .font(.system(size: 13))
                    Spacer()
                    Text(item.binding.displayString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Button("恢复默认快捷键") {
                KeyBindings.shared.resetToDefaults()
            }
            .font(.system(size: 12))
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("连接")
            HStack {
                Text("默认超时")
                Spacer()
                Text("10s")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("重连策略")
                Spacer()
                Text("自动重连")
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
    }

    private func actionLabel(for action: String) -> String {
        switch action {
        case "spotlight":      return "Spotlight 搜索"
        case "settings":       return "打开设置"
        case "newTerminal":    return "新建终端"
        case "toggleSftp":     return "SFTP 侧栏"
        case "findInTerminal": return "查找"
        case "clearScreen":    return "清屏"
        case "reconnect":      return "重新连接"
        case "splitHorizontal": return "水平分屏"
        case "splitVertical":  return "垂直分屏"
        case "closePane":      return "关闭窗格"
        case "navPrevPane":    return "上一个窗格"
        case "navNextPane":    return "下一个窗格"
        case "navLeftPane":    return "左侧窗格"
        case "navRightPane":   return "右侧窗格"
        case "growPane":       return "扩大窗格"
        case "shrinkPane":     return "缩小窗格"
        default:               return action
        }
    }

    private func themeCard(_ theme: OrbitTheme) -> some View {
        let isSelected = appState.theme.rawValue == theme.id
        let colors = theme.colors

        return Button(action: {
            if let t = AppTheme(rawValue: theme.id) {
                appState.setTheme(t)
            }
        }) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: colors.background.red, green: colors.background.green, blue: colors.background.blue),
                                    Color(red: colors.windowBg.red, green: colors.windowBg.green, blue: colors.windowBg.blue),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 60)
                        .overlay(
                            HStack(spacing: 3) {
                                ForEach(0..<8, id: \.self) { i in
                                    Circle()
                                        .fill(Color(
                                            red: Double(colors.ansi[i].red) / 65535.0,
                                            green: Double(colors.ansi[i].green) / 65535.0,
                                            blue: Double(colors.ansi[i].blue) / 65535.0
                                        ))
                                        .frame(width: 8, height: 8)
                                }
                            }
                            .padding(.top, 30)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                        )
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(.white).padding(-2))
                    }
                }
                Text(theme.name)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func openThemesFolder() {
        let path = ThemeManager.shared.userThemesPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private static func loadMonoFonts() -> [String] {
        var names = Set<String>()
        for family in NSFontManager.shared.availableFontFamilies {
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family) as? [[Any]]
            for member in (members ?? []) {
                guard member.count >= 1, let name = member[0] as? String else { continue }
                let font = NSFont(name: name, size: 14)
                if font?.isFixedPitch == true {
                    names.insert(family)
                    break
                }
            }
        }
        let sorted = names.sorted()
        return sorted.contains("Menlo") ? sorted : ["Menlo"] + sorted
    }
}
