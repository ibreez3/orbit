import SwiftUI

struct DockerView: View {
    let appState: AppState
    let tab: TabItem
    @EnvironmentObject var inventoryState: InventoryState

    @State private var containers: [DockerContainer] = []
    @State private var statsById: [String: DockerContainerStats] = [:]
    @State private var selectedContainerId: String?
    @State private var logs: String = ""
    @State private var loading = false
    @State private var loadingLogs = false
    @State private var runningAction: String?
    @State private var error: String?
    @State private var query = ""
    @State private var logQuery = ""

    private var filteredContainers: [DockerContainer] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return containers }
        return containers.filter {
            $0.name.lowercased().contains(q)
                || $0.image.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || $0.status.lowercased().contains(q)
        }
    }

    private var selectedContainer: DockerContainer? {
        guard let selectedContainerId else { return filteredContainers.first }
        return containers.first(where: { $0.id == selectedContainerId })
    }

    private var logLines: [String] {
        logs.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private var filteredLogLines: [String] {
        let q = logQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return logLines }
        return logLines.filter { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private var displayedLogs: String {
        guard !logs.isEmpty else { return "" }
        let q = logQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return logs }
        return filteredLogLines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let error, containers.isEmpty {
                errorState(error)
            } else {
                HSplitView {
                    containerPane
                        .frame(minWidth: 520)
                    detailPane
                        .frame(minWidth: 360)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            restoreSnapshot()
            refresh()
        }
        .onDisappear(perform: saveSnapshot)
        .onChange(of: query) { _ in saveSnapshot() }
        .onChange(of: logQuery) { _ in saveSnapshot() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Docker: \(tab.serverName)")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(containers.count) containers · \(containers.filter { $0.isRunning }.count) running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Search containers", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(loading ? 360 : 0))
                    .animation(loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: loading)
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var containerPane: some View {
        VStack(spacing: 0) {
            tableHeader

            if loading && containers.isEmpty {
                loadingState
            } else if filteredContainers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredContainers) { container in
                            containerRow(container)
                        }
                    }
                }
            }

            if let error, !containers.isEmpty {
                compactWarning(error)
                    .padding(12)
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Container").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text("Image").frame(width: 150, alignment: .leading)
            Text("CPU").frame(width: 70, alignment: .trailing)
            Text("Memory").frame(width: 130, alignment: .trailing)
            Text("Status").frame(width: 150, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035))
    }

    private func containerRow(_ container: DockerContainer) -> some View {
        let isSelected = container.id == (selectedContainer?.id)
        let stats = statsById[container.id] ?? statsById[container.shortId]

        return Button(action: {
            selectedContainerId = container.id
            logs = ""
            saveSnapshot()
        }) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.55))
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.name.isEmpty ? container.shortId : container.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(container.shortId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

                Text(container.image)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 150, alignment: .leading)

                Text(stats?.cpu_percent ?? "-")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)

                Text(stats?.memory_usage ?? "-")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .trailing)

                Text(container.status.isEmpty ? container.state : container.status)
                    .font(.system(size: 11))
                    .foregroundStyle(container.isRunning ? .green : .secondary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let container = selectedContainer {
                detailHeader(container)
                Divider()
                metadata(container)
                Divider()
                logsPanel(container)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a container")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.primary.opacity(0.018))
    }

    private func detailHeader(_ container: DockerContainer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(container.name.isEmpty ? container.shortId : container.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                actionButtons(container)
            }

            Text(container.image)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
    }

    private func actionButtons(_ container: DockerContainer) -> some View {
        HStack(spacing: 6) {
            iconAction("terminal", help: "Open shell", container: container, action: "exec-shell")
            iconAction("text.alignleft", help: "Follow logs", container: container, action: "follow-logs")
            if container.isRunning {
                iconAction("stop.fill", help: "Stop", container: container, action: "stop")
                iconAction("arrow.clockwise", help: "Restart", container: container, action: "restart")
            } else {
                iconAction("play.fill", help: "Start", container: container, action: "start")
            }
            iconAction("trash", help: "Remove", container: container, action: "remove")
        }
    }

    private func iconAction(_ symbol: String, help: String, container: DockerContainer, action: String) -> some View {
        Button(action: { runAction(action, on: container) }) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(runningAction != nil)
        .help(help)
    }

    private func metadata(_ container: DockerContainer) -> some View {
        let stats = statsById[container.id] ?? statsById[container.shortId]

        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            detailRow("Status", container.status.isEmpty ? container.state : container.status)
            detailRow("Ports", container.ports.isEmpty ? "-" : container.ports)
            detailRow("Created", container.created.isEmpty ? container.running_for : container.created)
            detailRow("Size", container.size.isEmpty ? "-" : container.size)
            detailRow("Network IO", stats?.network_io ?? "-")
            detailRow("Block IO", stats?.block_io ?? "-")
            detailRow("PIDs", stats?.pids ?? "-")
            detailRow("Command", container.command.isEmpty ? "-" : container.command)
        }
        .font(.system(size: 11))
        .padding(14)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func logsPanel(_ container: DockerContainer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Logs")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !logs.isEmpty {
                    Text(logQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(logLines.count) lines" : "\(filteredLogLines.count) / \(logLines.count) lines")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button(action: { loadLogs(container) }) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(loadingLogs)
                .help("Load latest logs")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Filter log keyword", text: $logQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !logQuery.isEmpty {
                    Button(action: { logQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            ScrollView {
                Text(logs.isEmpty ? "No logs loaded" : (displayedLogs.isEmpty ? "No matching log lines" : displayedLogs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(logs.isEmpty || displayedLogs.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(14)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading Docker containers")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No containers found" : "No matching containers")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Docker unavailable")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Retry", action: refresh)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactWarning(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .lineLimit(2)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.orange)
    }

    private func refresh() {
        loading = true
        error = nil

        Task {
            do {
                let loadedContainers = try await appState.bridge.listDockerContainersAsync(serverId: tab.serverId)
                var loadedStats: [DockerContainerStats] = []
                do {
                    loadedStats = try await appState.bridge.getDockerStatsAsync(serverId: tab.serverId)
                } catch {
                    loadedStats = []
                }

                await MainActor.run {
                    containers = loadedContainers
                    statsById = loadedStats.reduce(into: [:]) { result, stat in
                        result[stat.id] = stat
                        result[String(stat.id.prefix(12))] = stat
                    }
                    if selectedContainerId == nil || !containers.contains(where: { $0.id == selectedContainerId }) {
                        selectedContainerId = containers.first?.id
                    }
                    loading = false
                    saveSnapshot()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    loading = false
                    saveSnapshot()
                }
            }
        }
    }

    private func loadLogs(_ container: DockerContainer) {
        loadingLogs = true
        Task {
            do {
                let result = try await appState.bridge.getDockerLogsAsync(serverId: tab.serverId, containerId: container.id, tail: 200)
                await MainActor.run {
                    logs = result
                    loadingLogs = false
                    saveSnapshot()
                }
            } catch {
                await MainActor.run {
                    logs = "Failed to load logs: \(error.localizedDescription)"
                    loadingLogs = false
                    saveSnapshot()
                }
            }
        }
    }

    private func runAction(_ action: String, on container: DockerContainer) {
        if action == "exec-shell" {
            openExecShell(container)
            return
        }
        if action == "follow-logs" {
            openFollowLogs(container)
            return
        }

        runningAction = action
        Task {
            do {
                _ = try await appState.bridge.dockerActionAsync(serverId: tab.serverId, containerId: container.id, action: action)
                await MainActor.run {
                    runningAction = nil
                    refresh()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    runningAction = nil
                    saveSnapshot()
                }
            }
        }
    }

    private func restoreSnapshot() {
        guard let snapshot = appState.dockerPanelSnapshot(for: tab.id) else { return }
        containers = snapshot.containers
        statsById = snapshot.statsById
        selectedContainerId = snapshot.selectedContainerId
        logs = snapshot.logs
        query = snapshot.query
        logQuery = snapshot.logQuery
        error = snapshot.error
    }

    private func saveSnapshot() {
        appState.saveDockerPanelSnapshot(
            DockerPanelSnapshot(
                containers: containers,
                statsById: statsById,
                selectedContainerId: selectedContainerId,
                logs: logs,
                query: query,
                logQuery: logQuery,
                error: error,
                lastUpdated: Date()
            ),
            for: tab.id
        )
    }

    private func openExecShell(_ container: DockerContainer) {
        guard let server = inventoryState.servers.first(where: { $0.id == tab.serverId }) else {
            error = "无法找到服务器配置"
            return
        }
        let name = container.name.isEmpty ? container.shortId : container.name
        let command = "docker exec -it \(shellQuote(container.id)) sh -lc \(shellQuote("if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"))"
        appState.addTerminalTab(server: server, title: "Exec: \(name)", initialCommand: command)
    }

    private func openFollowLogs(_ container: DockerContainer) {
        guard let server = inventoryState.servers.first(where: { $0.id == tab.serverId }) else {
            error = "无法找到服务器配置"
            return
        }
        let name = container.name.isEmpty ? container.shortId : container.name
        let command = "docker logs -f --tail 200 \(shellQuote(container.id))"
        appState.addTerminalTab(server: server, title: "Logs: \(name)", initialCommand: command)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
