import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Cpu, MemoryStick, HardDrive, Clock, Activity, RefreshCw } from "lucide-react";
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import type { Tab, ServerStats } from "../../types";

interface Props {
  tab: Tab;
}

export default function MonitorPanel({ tab }: Props) {
  const [stats, setStats] = useState<ServerStats | null>(null);
  const [loading, setLoading] = useState(false);
  const [autoRefresh, setAutoRefresh] = useState(false);
  const [history, setHistory] = useState<
    { time: string; cpu: number; mem: number }[]
  >([]);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await invoke<ServerStats>("get_server_stats", {
        serverId: tab.serverId,
      });
      setStats(result);
      const now = new Date().toLocaleTimeString("zh-CN", {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      });
      setHistory((prev) => [
        ...prev.slice(-29),
        { time: now, cpu: result.cpu_usage, mem: result.mem_percent },
      ]);
    } catch (e) {
      console.error("获取监控数据失败:", e);
    } finally {
      setLoading(false);
    }
  }, [tab.serverId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!autoRefresh) return;
    const interval = setInterval(refresh, 3000);
    return () => clearInterval(interval);
  }, [autoRefresh, refresh]);

  return (
    <div className="flex flex-col h-full overflow-y-auto p-4 gap-4">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-text-primary flex items-center gap-2">
          <Activity size={16} className="text-accent-blue" />
          资源监控 - {tab.serverName}
        </h2>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setAutoRefresh(!autoRefresh)}
            className={`px-3 py-1 rounded text-xs transition-colors ${
              autoRefresh
                ? "bg-accent-blue/20 text-accent-blue"
                : "bg-bg-tertiary text-text-muted hover:text-text-secondary"
            }`}
          >
            自动刷新
          </button>
          <button
            onClick={refresh}
            disabled={loading}
            className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-text-primary transition-colors"
          >
            <RefreshCw size={14} className={loading ? "animate-spin" : ""} />
          </button>
        </div>
      </div>

      {stats ? (
        <>
          <div className="grid grid-cols-3 gap-4">
            <div className="bg-bg-secondary rounded-lg p-4 border border-border">
              <div className="flex items-center gap-2 text-text-muted text-xs mb-2">
                <Cpu size={14} />
                CPU 使用率
              </div>
              <div className="text-2xl font-bold text-accent-cyan">
                {stats.cpu_usage.toFixed(1)}%
              </div>
              <div className="mt-2 h-2 bg-bg-tertiary rounded-full overflow-hidden">
                <div
                  className="h-full bg-accent-cyan rounded-full transition-all"
                  style={{ width: `${Math.min(stats.cpu_usage, 100)}%` }}
                />
              </div>
            </div>

            <div className="bg-bg-secondary rounded-lg p-4 border border-border">
              <div className="flex items-center gap-2 text-text-muted text-xs mb-2">
                <MemoryStick size={14} />
                内存使用
              </div>
              <div className="text-2xl font-bold text-accent-purple">
                {stats.mem_percent.toFixed(1)}%
              </div>
              <div className="text-xs text-text-muted mt-1">
                {stats.mem_used_mb} MB / {stats.mem_total_mb} MB
              </div>
              <div className="mt-2 h-2 bg-bg-tertiary rounded-full overflow-hidden">
                <div
                  className="h-full bg-accent-purple rounded-full transition-all"
                  style={{ width: `${Math.min(stats.mem_percent, 100)}%` }}
                />
              </div>
            </div>

            <div className="bg-bg-secondary rounded-lg p-4 border border-border">
              <div className="flex items-center gap-2 text-text-muted text-xs mb-2">
                <HardDrive size={14} />
                磁盘使用
              </div>
              <div className="text-2xl font-bold text-accent-yellow">
                {stats.disk_percent.toFixed(1)}%
              </div>
              <div className="text-xs text-text-muted mt-1">
                {stats.disk_used} / {stats.disk_total}
              </div>
              <div className="mt-2 h-2 bg-bg-tertiary rounded-full overflow-hidden">
                <div
                  className="h-full bg-accent-yellow rounded-full transition-all"
                  style={{ width: `${Math.min(stats.disk_percent, 100)}%` }}
                />
              </div>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="bg-bg-secondary rounded-lg p-4 border border-border">
              <div className="flex items-center gap-2 text-text-muted text-xs mb-1">
                <Clock size={14} />
                运行时间
              </div>
              <div className="text-sm text-text-primary">{stats.uptime || "N/A"}</div>
            </div>
            <div className="bg-bg-secondary rounded-lg p-4 border border-border">
              <div className="flex items-center gap-2 text-text-muted text-xs mb-1">
                <Activity size={14} />
                负载均值
              </div>
              <div className="text-sm text-text-primary">{stats.load_avg || "N/A"}</div>
            </div>
          </div>

          {history.length > 1 && (
            <div className="bg-bg-secondary rounded-lg p-4 border border-border">
              <div className="text-text-muted text-xs mb-2">
                CPU / 内存 使用趋势
              </div>
              <ResponsiveContainer width="100%" height={200}>
                <AreaChart data={history}>
                  <defs>
                    <linearGradient id="cpuGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#7dcfff" stopOpacity={0.3} />
                      <stop offset="95%" stopColor="#7dcfff" stopOpacity={0} />
                    </linearGradient>
                    <linearGradient id="memGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#bb9af7" stopOpacity={0.3} />
                      <stop offset="95%" stopColor="#bb9af7" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <XAxis
                    dataKey="time"
                    tick={{ fontSize: 10, fill: "#565f89" }}
                    interval="preserveStartEnd"
                  />
                  <YAxis
                    tick={{ fontSize: 10, fill: "#565f89" }}
                    domain={[0, 100]}
                  />
                  <Tooltip
                    contentStyle={{
                      background: "#24283b",
                      border: "1px solid #3b4261",
                      borderRadius: "8px",
                      fontSize: "12px",
                    }}
                  />
                  <Area
                    type="monotone"
                    dataKey="cpu"
                    stroke="#7dcfff"
                    fill="url(#cpuGrad)"
                    name="CPU %"
                  />
                  <Area
                    type="monotone"
                    dataKey="mem"
                    stroke="#bb9af7"
                    fill="url(#memGrad)"
                    name="内存 %"
                  />
                </AreaChart>
              </ResponsiveContainer>
            </div>
          )}
        </>
      ) : (
        <div className="flex items-center justify-center flex-1 text-text-muted text-sm">
          {loading ? "加载中..." : "暂无数据"}
        </div>
      )}
    </div>
  );
}
