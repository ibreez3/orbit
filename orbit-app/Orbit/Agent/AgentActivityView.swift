import AgentKit
import Combine
import SwiftUI

struct AgentPane: View {
    let appState: AppState
    @EnvironmentObject private var inventoryState: InventoryState
    @AppStorage("agentGatewayEnabled") private var gatewayEnabled = true

    @State private var sessions: [AgentActiveSession] = []
    @State private var auditEvents: [AgentAuditEvent] = []
    @State private var gatewayRunning = false
    @State private var errorMessage: String?
    @State private var revision = 0

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup("网关状态") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(gatewayRunning ? Color.green : Color.gray.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text(gatewayRunning ? "运行中" : "已停止")
                                .font(.system(size: 12, weight: .medium))
                                .accessibilityIdentifier("agentGatewayStatusLabel")
                            Spacer()
                            Text(lastActivityLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("agentGatewayLastActivity")
                        }
                        Text(AgentPaths.socketPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("agentGatewaySocketPath")
                    }
                }

                SettingsGroup("AI Agent 接入") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("允许 MCP / CLI Agent 接入 Orbit", isOn: $gatewayEnabled)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("agentGatewayEnabledToggle")
                        Text("接入需要在本机由用户批准；凭据只保留在 Orbit 中。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("agentGatewayError")
                        }
                    }
                }

                SettingsGroup("服务器暴露") {
                    if inventoryState.servers.isEmpty {
                        Text("暂无服务器")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(inventoryState.servers) { server in
                                HStack(spacing: 10) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(server.name)
                                            .font(.system(size: 12))
                                        Text("\(server.host):\(server.port)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: exposureBinding(for: server))
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                }
                            }
                        }
                    }
                }

                SettingsGroup("活跃 AI 会话") {
                    if sessions.isEmpty {
                        Text("暂无活跃会话")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(sessions, id: \.sessionId) { session in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.agentName)
                                            .font(.system(size: 12, weight: .medium))
                                        Text("jobs \(session.openJobCount) · shells \(session.openShellCount)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("撤销") {
                                        AgentGateway.shared.revokeSession(session.sessionId)
                                        refresh()
                                    }
                                    .font(.system(size: 11))
                                }
                            }
                        }
                    }
                }

                SettingsGroup("AI 活动") {
                    if auditEvents.isEmpty {
                        Text("暂无 AI 活动")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(auditEvents.reversed(), id: \.id) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(event.type)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 150, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        if let tool = event.tool {
                                            Text(tool)
                                                .font(.system(size: 11))
                                        }
                                        if let command = event.command {
                                            Text(command)
                                                .font(.system(size: 10, design: .monospaced))
                                                .lineLimit(2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let result = event.result {
                                            Text(result)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsGroup("MCP / CLI 接入") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MCP bridge：Orbit.app/Contents/MacOS/orbit-mcp")
                        Text("CLI：Orbit.app/Contents/MacOS/orbit-cli")
                        Text("Claude Code：claude mcp add orbit -- <上面的 orbit-mcp 路径>")
                        Text("Codex：在 ~/.codex/config.toml 中配置 [mcp_servers.orbit] command")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .onAppear {
            if gatewayEnabled {
                startGateway()
            }
            refresh()
        }
        .onReceive(refreshTimer) { _ in
            refresh()
        }
        .onChange(of: gatewayEnabled) { enabled in
            if enabled {
                startGateway()
            } else {
                AgentGateway.shared.stop()
                sessions = []
            }
            refresh()
        }
    }

    private var lastActivityLabel: String {
        guard let date = auditEvents.last?.timestamp else {
            return "最后活动：暂无"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "最后活动：" + formatter.localizedString(for: date, relativeTo: Date())
    }

    private func exposureBinding(for server: Server) -> Binding<Bool> {
        Binding(
            get: { AgentExposureStore.shared.isEnabled(serverId: server.id) },
            set: { enabled in
                AgentExposureStore.shared.setEnabled(enabled, serverId: server.id)
                AgentGateway.shared.applyServerExposureChange(
                    serverId: server.id,
                    enabled: enabled
                )
                revision += 1
            }
        )
    }

    private func startGateway() {
        do {
            try AgentGateway.shared.start()
            errorMessage = nil
        } catch {
            errorMessage = "无法启动 AI Agent 网关：\(error.localizedDescription)"
        }
    }

    private func refresh() {
        gatewayRunning = AgentGateway.shared.isRunning
        sessions = AgentGateway.shared.activeSessions
        auditEvents = AgentAuditStore.shared.recent(limit: 20)
        _ = revision
    }
}
