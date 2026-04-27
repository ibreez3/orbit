import SwiftUI
import Charts

struct MonitorView: View {
    let tab: TabItem
    @Environment(AppState.self) var appState
    @State private var stats: ServerStats?
    @State private var loading: Bool = false
    @State private var autoRefresh: Bool = false
    @State private var history: [HistoryPoint] = []
    @State private var timer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let stats = stats {
                    statsGrid(stats)
                    infoGrid(stats)
                    if history.count > 1 {
                        chartSection
                    }
                } else {
                    Spacer()
                    ProgressView(loading ? "加载中..." : "暂无数据")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refresh() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: autoRefresh) { _, newVal in
            timer?.invalidate()
            if newVal {
                timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                    refresh()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label("资源监控 - \(tab.serverName)", systemImage: "chart.xyaxes.line")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Toggle("自动刷新", isOn: $autoRefresh)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(loading ? 360 : 0))
                    .animation(loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: loading)
            }
            .buttonStyle(.plain)
            .disabled(loading)
        }
    }

    private func statsGrid(_ stats: ServerStats) -> some View {
        Grid {
            GridRow {
                statCard(title: "CPU 使用率", value: String(format: "%.1f%%", stats.cpu_usage),
                         color: .cyan, progress: stats.cpu_usage / 100)
                statCard(title: "内存使用", value: String(format: "%.1f%%", stats.mem_percent),
                         color: .purple, progress: stats.mem_percent / 100,
                         subtitle: "\(stats.mem_used_mb) MB / \(stats.mem_total_mb) MB")
                statCard(title: "磁盘使用", value: String(format: "%.1f%%", stats.disk_percent),
                         color: .yellow, progress: stats.disk_percent / 100,
                         subtitle: "\(stats.disk_used) / \(stats.disk_total)")
            }
        }
    }

    private func statCard(title: String, value: String, color: Color, progress: Double, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func infoGrid(_ stats: ServerStats) -> some View {
        Grid {
            GridRow {
                infoCard(icon: "clock", title: "运行时间", value: stats.uptime.isEmpty ? "N/A" : stats.uptime)
                infoCard(icon: "waveform.path", title: "负载均值", value: stats.load_avg.isEmpty ? "N/A" : stats.load_avg)
            }
        }
    }

    private func infoCard(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CPU / 内存 使用趋势")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(history) { point in
                    LineMark(x: .value("时间", point.time), y: .value("CPU", point.cpu))
                        .foregroundStyle(.cyan)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("时间", point.time), y: .value("CPU", point.cpu))
                        .foregroundStyle(.cyan.opacity(0.1))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("时间", point.time), y: .value("内存", point.mem))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("时间", point.time), y: .value("内存", point.mem))
                        .foregroundStyle(.purple.opacity(0.1))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 200)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func refresh() {
        loading = true
        Task {
            do {
                let result = try appState.bridge.getServerStats(serverId: tab.serverId)
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                let point = HistoryPoint(time: formatter.string(from: Date()), cpu: result.cpu_usage, mem: result.mem_percent)
                await MainActor.run {
                    stats = result
                    history.append(point)
                    if history.count > 30 { history.removeFirst() }
                    loading = false
                }
            } catch {
                print("获取监控数据失败: \(error)")
                await MainActor.run { loading = false }
            }
        }
    }
}
