import SwiftUI

struct BatchExecutionView: View {
    @EnvironmentObject var inventoryState: InventoryState
    let appState: AppState
    @State private var selectedServerIds: Set<String> = []
    @State private var commandText: String = ""
    @State private var results: [BatchResult] = []
    @State private var isExecuting = false
    @State private var timeoutSeconds: Double = 15
    @State private var maxConcurrency: Double = 5
    @State private var cancelToken = CancelToken()

    class CancelToken {
        var cancelled = false
    }

    struct BatchResult: Identifiable {
        let id = UUID()
        let serverId: String
        let serverName: String
        var status: ResultStatus
        var output: String

        enum ResultStatus {
            case success
            case failed(String)
            case cancelled
            case running
        }

        var statusText: String {
            switch status {
            case .success: return "成功"
            case .failed(let msg): return msg
            case .cancelled: return "已取消"
            case .running: return "执行中..."
            }
        }

        var statusColor: Color {
            switch status {
            case .success: return .green
            case .failed: return .red
            case .cancelled: return .orange
            case .running: return .blue
            }
        }
    }

    private var selectableServers: [Server] {
        inventoryState.servers.filter { !$0.id.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            serverSelection
            Divider()
            commandInput
            Divider()
            executeOptions
            Divider()
            outputSection
            Spacer()
        }
        .frame(width: 340)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var header: some View {
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
    }

    private var serverSelection: some View {
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
                .frame(height: 140)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var commandInput: some View {
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
            TextEditor(text: $commandText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var executeOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LabeledSmallRow("超时") {
                    Slider(value: $timeoutSeconds, in: 3...60, step: 1).frame(width: 80)
                    Text("\(Int(timeoutSeconds))s")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LabeledSmallRow("并发") {
                    Slider(value: $maxConcurrency, in: 1...10, step: 1).frame(width: 80)
                    Text("\(Int(maxConcurrency))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if isExecuting {
                    Button(action: cancelExecution) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("取消执行")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: executeBatch) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("批量执行")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(canExecute ? Color.orange.opacity(0.25) : Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canExecute)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var outputSection: some View {
        Group {
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    let successCount = results.filter { if case .success = $0.status { true } else { false } }.count
                    HStack {
                        Text("执行输出")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(successCount)/\(results.count) 成功")
                            .font(.system(size: 10))
                            .foregroundStyle(successCount == results.count ? .green : .secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(results) { result in
                                resultRow(result)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: 160)
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func resultRow(_ result: BatchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(result.statusColor)
                    .frame(width: 6, height: 6)
                Text(result.serverName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Text(result.statusText)
                    .font(.system(size: 9))
                    .foregroundStyle(result.statusColor)
            }
            if !result.output.isEmpty {
                Text(result.output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var canExecute: Bool {
        !selectedServerIds.isEmpty &&
        !commandText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isExecuting
    }

    private func executeBatch() {
        let cmd = commandText.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !selectedServerIds.isEmpty else { return }

        isExecuting = true
        cancelToken.cancelled = false
        let serverIds = Array(selectedServerIds)

        results = serverIds.map { sid in
            let name = inventoryState.servers.first(where: { $0.id == sid })?.name ?? sid
            return BatchResult(serverId: sid, serverName: name, status: .running, output: "")
        }

        let timeout = UInt32(timeoutSeconds * 1000)
        let concurrency = Int(maxConcurrency)
        let bridge = appState.bridge
        let token = cancelToken

        DispatchQueue.global().async {
            let semaphore = DispatchSemaphore(value: concurrency)
            let group = DispatchGroup()

            for (idx, serverId) in serverIds.enumerated() {
                guard !token.cancelled else { break }
                group.enter()
                semaphore.wait()

                DispatchQueue.global().async {
                    defer { semaphore.signal(); group.leave() }

                    if token.cancelled {
                        DispatchQueue.main.async {
                            if idx < results.count { results[idx].status = .cancelled }
                        }
                        return
                    }

                    do {
                        let output = try bridge.execCommand(serverId: serverId, command: cmd, timeoutMs: timeout)
                        DispatchQueue.main.async {
                            if idx < results.count {
                                results[idx].status = .success
                                results[idx].output = output
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            if idx < results.count {
                                results[idx].status = .failed(error.localizedDescription)
                            }
                        }
                    }
                }
            }

            group.wait()
            DispatchQueue.main.async { isExecuting = false }
        }
    }

    private func cancelExecution() {
        cancelToken.cancelled = true
        for i in results.indices {
            if case .running = results[i].status {
                results[i].status = .cancelled
            }
        }
        isExecuting = false
    }
}

private struct LabeledSmallRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.content = content
    }
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            content()
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
