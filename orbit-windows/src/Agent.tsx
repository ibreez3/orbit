import { useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { message, Server } from './api';

type Approval = { requestId: string; kind: string; agentName: string; serverId: string | null; command: string };
type Snapshot = { enabled: boolean; exposed: string[]; approvals: Approval[]; sessions: { sessionId: string; agentName: string; createdAt: number; openJobCount: number; writeServers: string[] }[]; audit: Record<string, unknown>[] };
const empty: Snapshot = { enabled: false, exposed: [], approvals: [], sessions: [], audit: [] };

export function Agent({ servers, visible, close }: { servers: Server[]; visible: boolean; close: () => void }) {
  const [snapshot, setSnapshot] = useState<Snapshot>(empty); const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  const refresh = async () => setSnapshot(await invoke<Snapshot>('gateway_snapshot') || empty);
  useEffect(() => {
    let disposed = false; let off: (() => void) | undefined;
    void listen('agent-changed', () => void refresh().catch(error => setError(message(error)))).then(unlisten => { if (disposed) unlisten(); else off = unlisten; }).catch(error => setError(message(error)));
    void refresh().catch(error => setError(message(error)));
    return () => { disposed = true; off?.(); };
  }, []);
  const run = async (command: string, args: Record<string, unknown>) => { setBusy(true); setError(''); try { await invoke(command, args); await refresh(); } catch (error) { setError(message(error)); } finally { setBusy(false); } };
  const approval = snapshot.approvals[0];
  return <>{visible && <section className="tool-panel"><div className="dialog-heading"><h2>Agent 授权与活动</h2><button onClick={close}>关闭</button></div>
    <label className="toolbar"><input type="checkbox" disabled={busy} checked={snapshot.enabled} onChange={event => void run('gateway_enable', { enabled: event.target.checked })} />启用本机 Agent 网关</label>
    <p className="muted">客户端通过 Windows 本机命名管道连接。每个客户端首次连接需批准；仅开放下方选中的服务器。写权限按客户端会话和服务器授予，撤销会停止该会话的作业。</p>
    {error && <p className="error" role="alert">{error}</p>}
    <fieldset disabled={busy}><legend>向 Agent 开放的服务器</legend>{servers.map(server => <label className="toolbar" key={server.id}><input type="checkbox" checked={snapshot.exposed.includes(server.id)} onChange={event => void run('gateway_expose', { id: server.id, enabled: event.target.checked })} />{server.name} · {server.host}</label>)}</fieldset>
    <fieldset><legend>已授权客户端</legend>{!snapshot.sessions.length && <p className="muted">暂无已授权客户端</p>}{snapshot.sessions.map(session => <div className="row" key={session.sessionId}><span>{session.agentName} · {new Date(session.createdAt * 1000).toLocaleString()} · {session.openJobCount} 个运行作业<br />写权限：{session.writeServers.map(id => servers.find(server => server.id === id)?.name || id).join('、') || '无'}</span><button disabled={busy} onClick={() => void run('gateway_revoke', { id: session.sessionId })}>撤销授权</button></div>)}</fieldset>
    <details><summary>最近审计记录</summary>{snapshot.audit.slice().reverse().map((event, index) => <pre key={index} className="result-output">{JSON.stringify(event, null, 2)}</pre>)}</details>
    <p>CLI：<code>orbit-cli.exe auth --client Codex</code><br />MCP：<code>orbit-cli.exe mcp --client Codex</code></p>
  </section>}
  {approval && <div className="scrim agent-approval"><section className="dialog" role="dialog" aria-modal="true" aria-label="Agent 授权请求"><h2>{approval.kind === 'admission' ? '允许客户端连接？' : '允许服务器写入？'}</h2><p>客户端声明的名称：<strong>{approval.agentName}</strong></p>{approval.kind === 'admission' ? <p>批准后，此客户端可读取已开放服务器的列表并执行只读命令。写操作仍需单独授权。</p> : <><p>服务器：{servers.find(server => server.id === approval.serverId)?.name || approval.serverId}</p><pre className="result-output">{approval.command}</pre><p>批准后，该客户端在当前会话内获得此服务器的写权限。后续写命令不再逐条询问，可在 Agent 面板随时撤销。</p></>}{error && <p className="error">{error}</p>}<div className="dialog-actions"><button disabled={busy} onClick={() => void run('gateway_approve', { id: approval.requestId, approved: false })}>拒绝</button><button disabled={busy} className="primary" onClick={() => void run('gateway_approve', { id: approval.requestId, approved: true })}>批准</button></div></section></div>}
  </>;
}
