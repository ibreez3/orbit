import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("fontSize") private var fontSize: Double = 14
    @AppStorage("lineHeight") private var lineHeight: Double = 1.55
    @AppStorage("cursorStyle") private var cursorStyle: String = "bar"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                appearanceSection
                terminalSection
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

            HStack(spacing: 12) {
                themeCard(.light, name: "Light", colors: [Color.white, Color(red: 0.96, green: 0.96, blue: 0.97)])
                themeCard(.dark, name: "Dark", colors: [Color(red: 0.11, green: 0.11, blue: 0.12), Color.black])
                themeCard(.catppuccinMocha, name: "Catppuccin Mocha", colors: [Color(red: 0.12, green: 0.12, blue: 0.18), Color(red: 0.07, green: 0.07, blue: 0.11)])
            }
        }
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("终端")

            HStack {
                Text("字体大小")
                Spacer()
                Text("\(Int(fontSize))px")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $fontSize, in: 12...20, step: 1)

            HStack {
                Text("行高")
                Spacer()
                Text(String(format: "%.2f", lineHeight))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $lineHeight, in: 1.2...1.8, step: 0.05)

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

    private func themeCard(_ theme: AppTheme, name: String, colors: [Color]) -> some View {
        let isSelected = appState.theme == theme
        return Button(action: { appState.setTheme(theme) }) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                        .frame(height: 60)
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
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
