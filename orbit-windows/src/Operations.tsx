import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Settings } from './Settings';
import { message, request, Server } from './api';

type Stats = { cpu_usage: number; mem_percent: number; disk_percent: number; mem_used_mb: number; mem_total_mb: number; disk_used: string; disk_total: string; uptime: string; load_avg: string; net_rx_bytes: number | null; net_tx_bytes: number | null; net_interface: string };
type Process = { pid: number; user: string; cpu: number; mem: number; command: string };

type Sample = Stats & { time: number; rx: number | null; tx: number | null };
function Trend({ values, maximum = 100 }: { values: number[]; maximum?: number }) {
  return <svg viewBox="0 0 200 45" preserveAspectRatio="none" role="img" aria-label="最近采样趋势"><polyline fill="none" stroke="#547b68" strokeWidth="2" points={values.map((value, index) => `${index / Math.max(values.length - 1, 1) * 200},${44 - Math.min(maximum, Math.max(0, value)) / Math.max(1, maximum) * 42}`).join(' ')} /></svg>;
}

export function Monitor({ server, close, settings }: { server: Server; close: () => void; settings: Settings }) {
  const [stats, setStats] = useState<Stats | null>(null); const [history, setHistory] = useState<Sample[]>([]);
  const [processes, setProcesses] = useState<Process[]>([]); const [error, setError] = useState(''); const [paused, setPaused] = useState(false);
  const [filter, setFilter] = useState(''); const [sort, setSort] = useState<'cpu' | 'mem' | 'pid'>('cpu');
  useEffect(() => {
    let disposed = false; let timer: ReturnType<typeof setTimeout>;
    async function sample() {
      try {
        const [next, processes] = await Promise.all([request<Stats>('monitor.stats', { server_id: server.id }), request<Process[]>('monitor.processes', { server_id: server.id })]);
        if (!disposed) { setStats(next); setProcesses(processes); setHistory(history => { const time = Date.now(), previous = history.at(-1); const seconds = previous ? (time - previous.time) / 1000 : 0; const rate = (field: 'net_rx_bytes' | 'net_tx_bytes') => previous && seconds > 0 && previous.net_interface === next.net_interface && previous[field] !== null && next[field] !== null && next[field]! >= previous[field]! ? (next[field]! - previous[field]!) / seconds : null; return [...history.slice(-(settings.monitorHistory - 1)), { ...next, time, rx: rate('net_rx_bytes'), tx: rate('net_tx_bytes') }]; }); setError(''); }
      } catch (error) { if (!disposed) setError(message(error)); }
      finally { if (!disposed && !paused) timer = setTimeout(() => void sample(), settings.monitorInterval * 1000); }
    }
    if (!paused) void sample();
    return () => { disposed = true; clearTimeout(timer); };
  }, [server.id, paused, settings.monitorInterval, settings.monitorHistory]);
  return <section className="tool-panel"><div className="dialog-heading"><h2>资源监控 · {server.name}</h2><div className="toolbar"><button onClick={() => setPaused(!paused)}>{paused ? '继续采样' : '暂停采样'}</button><button onClick={close}>返回终端</button></div></div>
    {error && <p className="error" role="alert">{error}</p>}
    {!stats ? <p>等待 Linux 服务器采样…</p> : <><div className="metric-grid">{([['CPU', 'cpu_usage'], ['内存', 'mem_percent'], ['磁盘', 'disk_percent']] as const).map(([label, field]) => <div className={`metric ${field === 'disk_percent' && stats.disk_percent >= settings.diskThreshold ? 'warning' : ''}`} key={field}><span>{label}</span><strong>{stats[field].toFixed(1)}%</strong><Trend values={history.map(sample => sample[field])} /></div>)}</div>
      <div className="toolbar"><span>内存 {stats.mem_used_mb} / {stats.mem_total_mb} MB</span><span>磁盘 {stats.disk_used} / {stats.disk_total}</span><span>运行 {stats.uptime}</span><span>负载 {stats.load_avg}</span></div>
      <div className="network-metrics">{(['rx', 'tx'] as const).map(field => { const value = history.at(-1)?.[field]; const values = history.map(sample => (sample[field] || 0) / 1024); return <div className="metric" key={field}><span>{field === 'rx' ? '接收' : '发送'} · {stats.net_interface}</span><strong>{value == null ? '等待采样' : `${(value / 1024).toFixed(1)} KB/s`}</strong><Trend values={values} maximum={Math.max(1, ...values)} /></div>; })}</div><div className="toolbar"><input aria-label="搜索进程" placeholder="搜索 PID、用户或命令" value={filter} onChange={event => setFilter(event.target.value)} /><select aria-label="进程排序" value={sort} onChange={event => setSort(event.target.value as typeof sort)}><option value="cpu">CPU 降序</option><option value="mem">内存降序</option><option value="pid">PID 升序</option></select></div>
      <div className="scroll"><table className="data-table"><thead><tr>{['PID', '用户', 'CPU %', '内存 %', '命令'].map(label => <th key={label}>{label}</th>)}</tr></thead><tbody>{processes.filter(process => `${process.pid} ${process.user} ${process.command}`.toLowerCase().includes(filter.toLowerCase())).sort((a, b) => sort === 'pid' ? a.pid - b.pid : b[sort] - a[sort]).map(process => <tr key={process.pid}><td>{process.pid}</td><td>{process.user}</td><td>{process.cpu}</td><td>{process.mem}</td><td>{process.command}</td></tr>)}</tbody></table></div></>}
  </section>;
}

export function Batch({ servers, close, visible }: { servers: Server[]; close: () => void; visible: boolean }) {
  const [ids, setIds] = useState<string[]>([]); const [command, setCommand] = useState(''); const [busy, setBusy] = useState(false);
  const [timeout, setTimeoutSeconds] = useState(15); const [concurrency, setConcurrency] = useState(5);
  const [results, setResults] = useState<{ id: string; output: string; status: string }[]>([]);
  const cancelled = useRef(false), jobs = useRef(new Set<string>()), alive = useRef(true);
  const cancel = () => { cancelled.current = true; for (const id of jobs.current) void invoke('command_cancel', { id }).catch(() => {}); };
  useEffect(() => () => { alive.current = false; cancel(); }, []);
  const update = (id: string, output: string, status: string) => { if (alive.current) setResults(items => items.map(item => item.id === id ? { id, output, status } : item)); };
  const execute = async () => {
    if (!window.confirm(`在选中的 ${ids.length} 台服务器上执行以下命令？\n\n${command}`)) return;
    cancelled.current = false; setBusy(true); setResults(ids.map(id => ({ id, output: '', status: '等待' })));
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(concurrency, ids.length) }, async () => {
      while (next < ids.length) {
        const serverId = ids[next++];
        if (cancelled.current) { update(serverId, '', '已取消'); continue; }
        let id: string | undefined; let output = ''; let cursor = 0;
        try {
          update(serverId, '', '执行中');
          id = await invoke<string>('command_start', { serverId, command, timeoutMs: timeout * 1000 }); jobs.current.add(id);
          if (cancelled.current) await invoke('command_cancel', { id });
          while (alive.current) {
            const result = await invoke<{ status: { status: string; exitCode: number | null; truncated: boolean }; output: { chunk: string; nextCursor: number } }>('command_poll', { id, cursor });
            output += result.output.chunk; cursor = result.output.nextCursor;
            const status = result.status.status;
            update(serverId, output, status === 'running' ? '执行中' : `${status} · 退出码 ${result.status.exitCode ?? '—'}${result.status.truncated ? ' · 输出已截断' : ''}`);
            if (status !== 'running') break;
            await new Promise(resolve => setTimeout(resolve, 300));
          }
        } catch (error) { update(serverId, output + '\n' + message(error), '失败'); }
        finally { if (id) { jobs.current.delete(id); await invoke('command_release', { id }).catch(() => {}); } }
      }
    }));
    if (alive.current) setBusy(false);
  };
  return <section className="tool-panel" style={{ display: visible ? undefined : 'none' }}><div className="dialog-heading"><h2>批量执行</h2><button onClick={close}>关闭</button></div><div className="toolbar"><button disabled={busy} onClick={() => setIds(servers.map(server => server.id))}>全选</button><button disabled={busy} onClick={() => setIds([])}>清空选择</button>{servers.map(server => <label key={server.id}><input type="checkbox" disabled={busy} checked={ids.includes(server.id)} onChange={event => setIds(ids => event.target.checked ? [...ids, server.id] : ids.filter(id => id !== server.id))} />{server.name}</label>)}</div><textarea aria-label="批量命令" className="sql-editor" disabled={busy} value={command} onChange={event => setCommand(event.target.value)} placeholder="输入要执行的 Shell 命令" /><div className="toolbar"><label>超时（秒）<input disabled={busy} type="number" min="1" max="300" value={timeout} onChange={event => setTimeoutSeconds(Math.max(1, Math.min(300, Number(event.target.value))))} /></label><label>最大并发<input disabled={busy} type="number" min="1" max="16" value={concurrency} onChange={event => setConcurrency(Math.max(1, Math.min(16, Number(event.target.value))))} /></label><button disabled={busy || !ids.length || !command.trim()} onClick={() => void execute()}>{busy ? '执行中…' : '确认并执行'}</button>{busy && <button onClick={cancel}>取消执行</button>}</div>{results.map(result => <div key={result.id}><h3>{servers.find(server => server.id === result.id)?.name} · {result.status}</h3><pre className="result-output">{result.output}</pre></div>)}</section>;
}
