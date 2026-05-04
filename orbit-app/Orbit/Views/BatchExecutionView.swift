import SwiftUI

struct BatchExecutionView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedServerIds: Set<String> = []
    @State private var commandText: String = ""
    @State private var outputTexts: [String: String] = [:]
    @State private var isExecuting = false

    private var selectableServers: [Server] {
        appState.servers.filter { !$0.id.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text("批量执行")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已选 \(selectedServerIds.count) / \(selectableServers.count) 台")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Server selection
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("目标服务器").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button(selectedServerIds.isEmpty ? "全选" : "取消全选") {
                        if selectedServerIds.isEmpty {
                            selectedServerIds = Set(selectableServers.map { $0.id })
                        } else {
                            selectedServerIds.removeAll()
                        }
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                if selectableServers.isEmpty {
                    Text("暂无可用服务器")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(selectableServers) { server in
                                ServerSelectRow(
                                    server: server,
                                    isSelected: selectedServerIds.contains(server.id),
                                    onToggle: {
                                        if selectedServerIds.contains(server.id) {
                                            selectedServerIds.remove(server.id)
                                        } else {
                                            selectedServerIds.insert(server.id)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .frame(height: 160)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Command input
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("执行命令").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if !commandText.isEmpty {
                        Button("清空") { commandText = "" }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    TextEditor(text: $commandText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        .scrollContentBackground(.hidden)
                }

                Button(action: executeBatch) {
                    HStack {
                        if isExecuting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                            Text("执行中...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("批量执行")
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background((selectedServerIds.isEmpty || commandText.trimmingCharacters(in: .whitespaces).isEmpty || isExecuting)
                        ? Color.primary.opacity(0.08) : Color.orange.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(selectedServerIds.isEmpty || commandText.trimmingCharacters(in: .whitespaces).isEmpty || isExecuting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Output
            if !outputTexts.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("执行输出").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(outputTexts.keys.sorted()), id: \.self) { serverId in
                                let serverName = appState.servers.first(where: { $0.id == serverId })?.name ?? serverId
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(serverName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.blue)
                                    Text(outputTexts[serverId] ?? "")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(Color.primary.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: 150)
                }
                .padding(.bottom, 6)
            }

            Spacer()
        }
        .frame(width: 300)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func executeBatch() {
        let cmd = commandText.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !selectedServerIds.isEmpty else { return }

        isExecuting = true
        outputTexts.removeAll()

        let serverIds = Array(selectedServerIds)
        let group = DispatchGroup()

        for serverId in serverIds {
            group.enter()
            DispatchQueue.global().async {
                let result = executeCommandOnServer(serverId: serverId, command: cmd)
                DispatchQueue.main.async {
                    outputTexts[serverId] = result
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            isExecuting = false
        }
    }

    private func executeCommandOnServer(serverId: String, command: String) -> String {
        do {
            let sessionId = try OrbitBridge.shared.connectSSH(serverId: serverId)
            try OrbitBridge.shared.writeSSH(sessionId: sessionId, data: Data((command + "\r").utf8))
            // Note: We get immediate ACK, but real output is async.
            // In a full implementation, we'd wait for output with a timeout.
            Thread.sleep(forTimeInterval: 3.0)
            return "命令已发送到 \(serverId)"
        } catch {
            return "错误: \(error.localizedDescription)"
        }
    }
}

private struct ServerSelectRow: View {
    let server: Server
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .blue : .secondary)

                Circle()
                    .fill(Color(red: 0.4, green: 0.8, blue: 0.5))
                    .frame(width: 6, height: 6)

                Text(server.name)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                if !server.group_name.isEmpty {
                    Text(server.group_name)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }

                Spacer()
                Text(server.host)
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
