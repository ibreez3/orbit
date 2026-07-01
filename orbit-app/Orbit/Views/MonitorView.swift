import SwiftUI
import Charts

enum MonitorTab: String, CaseIterable {
    case overview = "概览"
    case processes = "进程"
}

struct MonitorView: View {
    let tab: TabItem
    @EnvironmentObject var appState: AppState
    @StateObject private var monitorState = MonitorState()
    @State private var selectedTab: MonitorTab = .overview
    @State private var processSearchQuery = ""
    @State private var sortField: ProcessSortField = .cpu
    @State private var sortAscending = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Picker("", selection: $selectedTab) {
                ForEach(MonitorTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            switch selectedTab {
            case .overview:
                overviewContent
            case .processes:
                processContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            monitorState.start(serverId: tab.serverId, bridge: appState.bridge)
        }
        .onDisappear {
            monitorState.stop()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)

            Text(tab.serverName)
                .font(.system(size: 13, weight: .medium))

            Text("资源监控")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            if monitorState.autoRefresh {
                Text("\(monitorState.interval)s")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Picker("", selection: $monitorState.autoRefresh) {
                Text("手动").tag(false)
                Text("自动").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 100)
            .onChange(of: monitorState.autoRefresh) { _ in
                monitorState.toggleAutoRefresh(serverId: tab.serverId, bridge: appState.bridge)
            }

            Button(action: { monitorState.refresh(serverId: tab.serverId, bridge: appState.bridge) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(monitorState.loading ? 360 : 0))
                    .animation(monitorState.loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: monitorState.loading)
            }
            .buttonStyle(.plain)
            .disabled(monitorState.loading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewContent: some View {
        if let error = monitorState.error {
            errorView(error)
        } else if let stats = monitorState.stats {
            ScrollView {
                VStack(spacing: 16) {
                    statsCards(stats)
                    infoCards(stats)
                    networkCard(stats)
                    if monitorState.history.count > 1 {
                        chartSection
                    }
                }
                .padding(20)
            }
        } else {
            loadingView
        }
    }

    // MARK: - Processes

    @ViewBuilder
    private var processContent: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索进程名称、用户、PID...", text: $processSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !processSearchQuery.isEmpty {
                    Button(action: { processSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text("\(filteredProcesses.count) 个进程")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))

            // Process table
            if monitorState.processes.isEmpty && !monitorState.loading {
                VStack(spacing: 8) {
                    if let processError = monitorState.processError {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.orange)
                        Text(processError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("暂无进程数据")
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        processHeaderRow
                        ForEach(filteredProcesses) { proc in
                            processRow(proc)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minWidth: 700)
                }
            }
        }
    }

    private var processHeaderRow: some View {
        HStack(spacing: 0) {
            processHeaderCol("PID", width: 60, field: .pid)
            processHeaderCol("用户", width: 80, field: .user)
            processHeaderCol("CPU%", width: 60, field: .cpu)
            processHeaderCol("MEM%", width: 60, field: .mem)
            processHeaderCol("RSS", width: 70, field: .rss)
            processHeaderCol("STAT", width: 50, field: .stat)
            processHeaderCol("命令", width: nil, field: .command)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func processHeaderCol(_ title: String, width: CGFloat?, field: ProcessSortField) -> some View {
        Button(action: {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = field == .pid || field == .user
            }
        }) {
            HStack(spacing: 2) {
                Text(title)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
    }

    private func processRow(_ proc: ServerProcess) -> some View {
        HStack(spacing: 0) {
            Text("\(proc.pid)")
                .frame(width: 60, alignment: .leading)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(proc.user)
                .frame(width: 80, alignment: .leading)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(String(format: "%.1f", proc.cpu))
                .frame(width: 60, alignment: .trailing)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(proc.cpu > 50 ? .red : proc.cpu > 20 ? .orange : .primary)
            Text(String(format: "%.1f", proc.mem))
                .frame(width: 60, alignment: .trailing)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(proc.mem > 50 ? .red : proc.mem > 20 ? .orange : .primary)
            Text(formatMemory(proc.rss * 1024))
                .frame(width: 70, alignment: .trailing)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(proc.stat)
                .frame(width: 50, alignment: .leading)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(proc.command)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Filtering & Sorting

    private var filteredProcesses: [ServerProcess] {
        var result = monitorState.processes
        let q = processSearchQuery.lowercased()
        if !q.isEmpty {
            result = result.filter {
                $0.command.lowercased().contains(q) ||
                $0.user.lowercased().contains(q) ||
                "\($0.pid)".contains(q)
            }
        }
        result.sort { a, b in
            let cmp: Bool
            switch sortField {
            case .pid: cmp = a.pid < b.pid
            case .user: cmp = a.user < b.user
            case .cpu: cmp = a.cpu > b.cpu
            case .mem: cmp = a.mem > b.mem
            case .rss: cmp = a.rss > b.rss
            case .stat: cmp = a.stat < b.stat
            case .command: cmp = a.command < b.command
            }
            return sortAscending ? !cmp : cmp
        }
        return result
    }

    // MARK: - Loading / Error

    private var loadingView: some View {
        VStack(spacing: 8) {
            if monitorState.loading {
                ProgressView()
                    .scaleEffect(0.8)
                Text("正在获取数据...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无数据")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                monitorState.refresh(serverId: tab.serverId, bridge: appState.bridge)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            .clipShape(Capsule())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stats cards

    private func statsCards(_ stats: ServerStats) -> some View {
        HStack(spacing: 12) {
            metricCard(icon: "cpu", title: "CPU", value: String(format: "%.1f", stats.cpu_usage),
                       unit: "%", color: .cyan, progress: stats.cpu_usage / 100)
            metricCard(icon: "memorychip", title: "内存", value: String(format: "%.1f", stats.mem_percent),
                       unit: "%", color: .purple, progress: stats.mem_percent / 100,
                       detail: "\(formatMB(stats.mem_used_mb)) / \(formatMB(stats.mem_total_mb))")
            metricCard(icon: "harddrive", title: "磁盘", value: String(format: "%.1f", stats.disk_percent),
                       unit: "%", color: .yellow, progress: stats.disk_percent / 100,
                       detail: "\(stats.disk_used) / \(stats.disk_total)")
        }
    }

    private func metricCard(icon: String, title: String, value: String, unit: String, color: Color, progress: Double, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(unit)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(color)
                .scaleEffect(y: 1.5, anchor: .center)
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Info cards

    private func infoCards(_ stats: ServerStats) -> some View {
        HStack(spacing: 12) {
            infoCard(icon: "clock", title: "运行时间", value: stats.uptime.isEmpty ? "N/A" : stats.uptime)
            infoCard(icon: "waveform.path", title: "负载均值", value: stats.load_avg.isEmpty ? "N/A" : stats.load_avg)
        }
    }

    private func networkCard(_ stats: ServerStats) -> some View {
        HStack(spacing: 12) {
            infoCard(icon: "arrow.down.circle", title: "网络下行", value: formatRate(stats.net_rx_kbps))
            infoCard(icon: "arrow.up.circle", title: "网络上行", value: formatRate(stats.net_tx_kbps))
            infoCard(icon: "network", title: "网络接口", value: networkInterface(stats))
        }
    }

    private func infoCard(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Chart

    private var chartSection: some View {
        let now = Date()
        let windowStart = now.addingTimeInterval(-600)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CPU / 内存趋势")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 12) {
                    Label("CPU", systemImage: "circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.cyan)
                    Label("内存", systemImage: "circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                }
            }

            Chart {
                ForEach(monitorState.history) { point in
                    LineMark(x: .value("时间", point.date, unit: .second), y: .value("CPU", point.cpu))
                        .foregroundStyle(.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    AreaMark(x: .value("时间", point.date, unit: .second), y: .value("CPU", point.cpu))
                        .foregroundStyle(.linearGradient(colors: [.cyan.opacity(0.2), .cyan.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("时间", point.date, unit: .second), y: .value("内存", point.mem))
                        .foregroundStyle(.purple)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    AreaMark(x: .value("时间", point.date, unit: .second), y: .value("内存", point.mem))
                        .foregroundStyle(.linearGradient(colors: [.purple.opacity(0.2), .purple.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                }
            }
            .chartXScale(domain: windowStart...now)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 2)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 10))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 25)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))%").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(14)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func formatMB(_ mb: UInt64) -> String {
        if mb >= 1024 { return String(format: "%.1fG", Double(mb) / 1024.0) }
        return "\(mb)M"
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        if bytes >= 1073741824 { return String(format: "%.1fG", Double(bytes) / 1073741824.0) }
        if bytes >= 1048576 { return String(format: "%.0fM", Double(bytes) / 1048576.0) }
        if bytes >= 1024 { return String(format: "%.0fK", Double(bytes) / 1024.0) }
        return "\(bytes)B"
    }

    private func formatRate(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        if value >= 1024 {
            return String(format: "%.1f MB/s", value / 1024.0)
        }
        return String(format: "%.1f KB/s", value)
    }

    private func networkInterface(_ stats: ServerStats) -> String {
        guard let iface = stats.net_interface, !iface.isEmpty else { return "N/A" }
        return iface
    }
}

enum ProcessSortField {
    case pid, user, cpu, mem, rss, stat, command
}

// MARK: - MonitorState

class MonitorState: ObservableObject {
    @Published var stats: ServerStats?
    @Published var loading = false
    @Published var error: String?
    @Published var history: [HistoryPoint] = []
    @Published var autoRefresh = false
    @Published var processes: [ServerProcess] = []
    @Published var processError: String?
    let interval = 3

    private let maxPoints = 200
    private var timer: Timer?

    func start(serverId: String, bridge: OrbitBridge) {
        refresh(serverId: serverId, bridge: bridge)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func toggleAutoRefresh(serverId: String, bridge: OrbitBridge) {
        timer?.invalidate()
        timer = nil
        if autoRefresh {
            weak var weakSelf = self
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { _ in
                weakSelf?.refresh(serverId: serverId, bridge: bridge)
            }
        }
    }

    func refresh(serverId: String, bridge: OrbitBridge) {
        loading = true
        error = nil
        processError = nil

        // Fetch stats and processes in parallel
        Task {
            async let statsResult = fetchStats(serverId: serverId, bridge: bridge)
            async let processesResult = fetchProcesses(serverId: serverId, bridge: bridge)

            let (s, p) = await (statsResult, processesResult)

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if let s = s {
                    self.stats = s.stats
                    let point = HistoryPoint(date: Date(), cpu: s.stats.cpu_usage, mem: s.stats.mem_percent)
                    self.history.append(point)
                    let cutoff = Date().addingTimeInterval(-600)
                    self.history.removeAll { $0.date < cutoff }
                    if self.history.count > self.maxPoints {
                        self.history.removeFirst(self.history.count - self.maxPoints)
                    }
                    self.error = s.error
                }
                if let p = p {
                    self.processes = p.processes
                    self.processError = p.error
                }
                self.loading = false
            }
        }
    }

    private struct StatsResult { let stats: ServerStats; let error: String? }
    private struct ProcessesResult { let processes: [ServerProcess]; let error: String? }

    private func fetchStats(serverId: String, bridge: OrbitBridge) async -> StatsResult? {
        do {
            let result = try await bridge.getServerStatsAsync(serverId: serverId)
            return StatsResult(stats: result, error: nil)
        } catch {
            return StatsResult(stats: stats ?? ServerStats(cpu_usage: 0, mem_total_mb: 0, mem_used_mb: 0, mem_percent: 0, disk_total: "", disk_used: "", disk_percent: 0, net_rx_kbps: nil, net_tx_kbps: nil, net_interface: nil, uptime: "", load_avg: ""), error: "获取监控数据失败: \(error.localizedDescription)")
        }
    }

    private func fetchProcesses(serverId: String, bridge: OrbitBridge) async -> ProcessesResult? {
        do {
            let result = try await bridge.getServerProcessesAsync(serverId: serverId)
            return ProcessesResult(processes: result, error: nil)
        } catch {
            return ProcessesResult(processes: [], error: "获取进程列表失败: \(error.localizedDescription)")
        }
    }

    deinit {
        timer?.invalidate()
    }
}
