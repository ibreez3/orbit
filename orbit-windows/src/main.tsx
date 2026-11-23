import { useUpdates, UpdateDialog } from './Updates';
import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Channel, invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { open, save } from '@tauri-apps/plugin-dialog';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { SearchAddon } from '@xterm/addon-search';
import { defaults, readSettings, Settings, SettingsDialog, terminalTheme } from './Settings';
import '@xterm/xterm/css/xterm.css';
import './style.css';
import { Server, request } from './api';
import { Monitor, Batch } from './Operations';
import { Databases } from './Database';
import { Forward, Forwards, Snippets } from './Tools';
import { AIChat, AuditEvent } from './AI';
import { Agent } from './Agent';
import { ServerDialog, AssetManager } from './Inventory';
import { actionFor } from './keyboard';
import { Pane, layout, leaves, splitPane, removePane, resizePane } from './panes';
import { CommandPalette } from './CommandPalette';
import { AssetSidebar, Home, Icon } from './WorkspaceChrome';

type Tab = { token: string; server: Server; temporary?: Record<string, unknown>; root: Pane; focused: string };
type HostKey = { id: string; host: string; port: number; role: string; algorithm: string; fingerprint: string; previous_fingerprint: string | null };
type Entry = { name: string; path: string; is_dir: boolean; size: number; permissions: string };
type TerminalEvent = { kind: 'data'; bytes: number[] } | { kind: 'closed' };
const message = (error: unknown) => String(error);

type TerminalHandle = { focus: () => void; find: () => void; clear: () => void; reconnect: () => void; paste: (text: string) => void; context: () => string };

function TerminalPane({ tab, active, focused, focus, handles, settings, style, saved, report }: { tab: Tab; active: boolean; focused: boolean; focus: () => void; handles: React.MutableRefObject<Map<string, TerminalHandle>>; settings: Settings; style?: React.CSSProperties; saved: () => void; report: (error: string) => void }) {
  const element = useRef<HTMLDivElement>(null);
  const terminal = useRef<Terminal | null>(null);
  const fit = useRef<FitAddon | null>(null);
  const session = useRef<string | null>(null);
  const preferences = useRef(settings); preferences.current = settings;
  const focusState = useRef(false); focusState.current = active && focused;
  const reconnectTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [status, setStatus] = useState('正在连接');
  const [attempt, setAttempt] = useState(0);
  const search = useRef<SearchAddon | null>(null); const [finding, setFinding] = useState(false); const [query, setQuery] = useState('');
  useEffect(() => {
    if (!element.current) return;
    let disposed = false;
    let ended = false;
    let input = Promise.resolve();
    const term = new Terminal({ fontFamily: settings.fontFamily, fontSize: settings.fontSize, allowProposedApi: true, cursorStyle: settings.cursorStyle, cursorBlink: settings.cursorBlink, scrollback: settings.scrollback, theme: terminalTheme(settings) });
    const addon = new FitAddon();
    terminal.current = term; fit.current = addon;
    const searchAddon = new SearchAddon(); search.current = searchAddon; term.loadAddon(searchAddon);
    term.loadAddon(addon); term.open(element.current); addon.fit();
    const token = `${tab.token}-${attempt}`;
    const channel = new Channel<TerminalEvent>();
    channel.onmessage = event => {
      if (disposed) return;
      if (event.kind === 'data') {
        term.write(new Uint8Array(event.bytes), () => {
          if (!disposed) void invoke('acknowledge', { token, bytes: event.bytes.length }).catch(report);
        });
      } else { ended = true; session.current = null; setStatus('连接已关闭'); if (preferences.current.reconnect && tab.server.id !== '__local__') reconnectTimer.current = setTimeout(() => { if (!disposed) setAttempt(value => value + 1); }, preferences.current.reconnectInterval * 1000); }
    };
    const resize = () => {
      if (!element.current?.offsetWidth) return;
      addon.fit();
      if (session.current) void invoke('resize', { id: session.current, cols: term.cols, rows: term.rows }).catch(error => { if (!disposed) report(message(error)); });
    };
    void Promise.all([400, 700].flatMap(weight => ['normal', 'italic'].map(style => document.fonts.load(`${style} ${weight} ${settings.fontSize}px "Maple Mono Normal"`)))).then(() => { if (!disposed) { resize(); term.refresh(0, term.rows - 1); } }).catch(error => { if (!disposed) report(message(error)); });
    const observer = new ResizeObserver(resize); observer.observe(element.current);
    const dimensions = term.onResize(({ cols, rows }) => {
      if (session.current) void invoke('resize', { id: session.current, cols, rows }).catch(error => { if (!disposed) report(message(error)); });
    });
    const subscription = term.onData(text => {
      const id = session.current;
      if (!id) return;
      input = input.then(() => invoke<void>('terminal_write', { id, bytes: Array.from(new TextEncoder().encode(text)) })).catch(error => { if (!disposed) report(message(error)); });
    });
    term.attachCustomKeyEventHandler(event => {
      if (event.type === 'keydown' && actionFor(event, preferences.current.bindings)) return false;
      if (event.type === 'keydown' && event.ctrlKey && event.shiftKey && event.code === 'KeyV') { void navigator.clipboard.readText().then(text => term.paste(text)).catch(error => report(message(error))); return false; }
      if (event.type === 'keydown' && event.ctrlKey && event.shiftKey && event.code === 'KeyC') {
        void navigator.clipboard.writeText(term.getSelection()).catch(error => report(message(error))); return false;
      }
      return true;
    });
    handles.current.set(tab.token, { focus: () => term.focus(), find: () => setFinding(value => !value), clear: () => term.clear(), reconnect: () => setAttempt(value => value + 1), paste: text => term.paste(text), context: () => { const buffer = term.buffer.active; return Array.from({ length: Math.min(buffer.length, 80) }, (_, index) => buffer.getLine(Math.max(0, buffer.length - 80) + index)?.translateToString(true) || '').join('\n').slice(-16000); } });
    const selection = term.onSelectionChange(() => { if (preferences.current.selectToCopy && term.hasSelection()) void navigator.clipboard.writeText(term.getSelection()).catch(() => {}); });
    setStatus('正在连接');
    void invoke<string>('connect', { token, serverId: tab.server.id, output: channel, temporary: tab.temporary || null }).then(id => {
      if (disposed || ended) { void invoke('disconnect', { token }).catch(() => {}); return; }
      session.current = id; setStatus('已连接'); resize(); if (focusState.current) term.focus();
    }).catch(error => { if (!disposed) { setStatus('连接失败'); report(message(error)); } });
    return () => {
      disposed = true; session.current = null; clearTimeout(reconnectTimer.current); handles.current.delete(tab.token); selection.dispose();
      observer.disconnect(); subscription.dispose(); dimensions.dispose(); term.dispose(); terminal.current = null; fit.current = null;
      void invoke('disconnect', { token }).catch(report);
    };
  }, [tab.token, attempt]);
  useEffect(() => { if (active) { fit.current?.fit(); if (focused) terminal.current?.focus(); } }, [active, focused]);
  useEffect(() => { if (terminal.current) { Object.assign(terminal.current.options, { fontSize: settings.fontSize, fontFamily: settings.fontFamily, cursorStyle: settings.cursorStyle, cursorBlink: settings.cursorBlink, scrollback: settings.scrollback, theme: terminalTheme(settings) }); fit.current?.fit(); } }, [settings]);
  useEffect(() => {
    const term = terminal.current; if (!term) return;
    let decorations: { dispose: () => void }[] = []; let frame = 0;
    const highlight = () => {
      decorations.forEach(item => item.dispose()); decorations = [];
      const buffer = term.buffer.active;
      for (let y = buffer.viewportY; y < Math.min(buffer.length, buffer.viewportY + term.rows); y++) {
        const line = buffer.getLine(y); if (!line) continue;
        let text = ''; const cells: { start: number; end: number; column: number; width: number }[] = [];
        for (let x = 0; x < line.length; x++) { const cell = line.getCell(x); if (!cell || cell.getWidth() === 0) continue; const value = cell.getChars() || ' '; cells.push({ start: text.length, end: text.length + value.length, column: x, width: cell.getWidth() }); text += value; }
        for (const rule of settings.keywords.filter(rule => rule.enabled && rule.text)) {
          let matches: RegExpMatchArray[]; try { matches = Array.from(text.matchAll(new RegExp(rule.text, 'gi'))).filter(match => match[0].length).slice(0, 100); } catch { continue; }
          for (const match of matches) {
            const index = match.index!; const first = cells.find(cell => cell.end > index), last = cells.find(cell => cell.end >= index + match[0].length);
            if (!first || !last) continue;
            const marker = term.registerMarker(y - buffer.baseY - buffer.cursorY); if (!marker) continue;
            const decoration = term.registerDecoration({ marker, x: first.column, width: last.column + last.width - first.column, foregroundColor: rule.color, layer: 'top' });
            decorations.push(marker); if (decoration) decorations.push(decoration);
          }
        }
      }
    };
    const schedule = () => { cancelAnimationFrame(frame); frame = requestAnimationFrame(highlight); };
    const writing = term.onWriteParsed(schedule), scrolling = term.onScroll(schedule), resizing = term.onResize(schedule); schedule();
    return () => { cancelAnimationFrame(frame); writing.dispose(); scrolling.dispose(); resizing.dispose(); decorations.forEach(item => item.dispose()); };
  }, [settings.keywords, attempt]);
  return <section className={`terminal-pane ${active ? 'active' : ''}`} onPointerDown={focus} data-focused={focused} aria-hidden={!active} style={{ background: terminalTheme(settings).background, ...style }}>
    <div className="session-toolbar"><span><i className={status === '已连接' ? 'dot online' : 'dot'} />{status}</span><code>{tab.server.id === '__local__' ? '本地 PowerShell' : `${tab.server.username}@${tab.server.host}:${tab.server.port}`}</code>{tab.temporary && <button disabled={!session.current} onClick={() => { const name = window.prompt('保存服务器名称', tab.server.name); if (name?.trim() && session.current) void request('server.promote', { id: session.current, input: { connection: tab.temporary, name, folder_id: null, tag_ids: [] } }).then(saved).catch(error => report(message(error))); }}>保存服务器</button>}<button onClick={() => setFinding(value => !value)}>搜索</button><button onClick={() => terminal.current?.clear()}>清屏</button><button onClick={() => setAttempt(value => value + 1)}>重新连接</button></div>{finding && <form className="terminal-search" onSubmit={event => { event.preventDefault(); search.current?.findNext(query); }}><input aria-label="搜索终端文本" autoFocus value={query} onChange={event => { setQuery(event.target.value); search.current?.findNext(event.target.value, { incremental: true }); }} /><button type="button" onClick={() => search.current?.findPrevious(query)}>上一个</button><button>下一个</button><button type="button" onClick={() => setFinding(false)}>关闭搜索</button></form>}
    <div className="terminal" ref={element} />
  </section>;
}

function Files({ server, close, visible }: { server: Server; close: () => void; visible: boolean }) {
  const panel = useRef<HTMLElement>(null); const dropHandler = useRef<(paths: string[]) => void>(() => {}); const [dropActive, setDropActive] = useState(false);
  const [path, setPath] = useState('.'); const [entries, setEntries] = useState<Entry[]>([]); const [error, setError] = useState('');
  const [editor, setEditor] = useState<{ path: string; content: string; original: string } | null>(null);
  const [hidden, setHidden] = useState(false); const [sort, setSort] = useState('name'); const [filter, setFilter] = useState('');
  type QueuedTransfer = { key: string; local: string; remote: string; upload: boolean; overwrite: boolean; state: string; progress: string };
  const [queue, setQueue] = useState<QueuedTransfer[]>([]); const transferring = useRef(false); const activeTransfer = useRef<string | null>(null); const mounted = useRef(true);
  useEffect(() => () => { mounted.current = false; if (activeTransfer.current) void invoke('cancel_transfer', { id: activeTransfer.current }).catch(() => {}); }, []);
  const [busy, setBusy] = useState(false); const [progress, setProgress] = useState(''); const [transferId, setTransferId] = useState<string | null>(null);
  async function load(next: string) {
    setBusy(true); setError('');
    try { const result = await invoke<Entry[]>('files', { serverId: server.id, path: next }); setEntries(result); setPath(next); }
    catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  useEffect(() => { void load('.'); }, [server.id]);
  useEffect(() => {
    if (transferring.current) return;
    const item = queue.find(item => item.state === '等待'); if (!item) return;
    transferring.current = true;
    const update = (state: string, progress: string) => { if (mounted.current) setQueue(items => items.map(value => value.key === item.key ? { ...value, state, progress } : value)); };
    void (async () => {
      try {
        update('传输中', '准备传输…');
        const id = await invoke<string>('reserve_transfer'); activeTransfer.current = id; setTransferId(id);
        if (!mounted.current) { await invoke('cancel_transfer', { id }); return; }
        const channel = new Channel<[number, number]>(); channel.onmessage = ([done, total]) => update('传输中', total ? `${Math.round(done / total * 100)}% · ${(done / 1024).toFixed(0)} KB` : '0 KB');
        await invoke('transfer', { request: { id, server_id: server.id, local_path: item.local, remote_path: item.remote, upload: item.upload, overwrite: item.overwrite }, progress: channel });
        update('完成', '传输完成'); if (mounted.current) await load(path);
      } catch (error) { update('未完成', message(error)); }
      finally { activeTransfer.current = null; transferring.current = false; if (mounted.current) { setTransferId(null); setQueue(items => [...items]); } }
    })();
  }, [queue]);
  function enqueue(paths: string[], upload: boolean, entry?: Entry) {
    const items: QueuedTransfer[] = [];
    for (const local of paths) {
      const name = local.split(/[\\/]/).pop()!;
      const remote = upload ? `${path.replace(/\/$/, '')}/${name}` : entry!.path;
      const overwrite = upload ? entries.some(entry => entry.name === name) : true;
      if (upload && overwrite && !window.confirm(`覆盖远程文件“${remote}”？`)) continue;
      items.push({ key: crypto.randomUUID(), local, remote, upload, overwrite, state: '等待', progress: '' });
    }
    setQueue(queue => [...queue, ...items]);
  }
  dropHandler.current = paths => { if (visible && !busy && !editor) enqueue(paths, true); };
  useEffect(() => {
    let disposed = false; const cleanup: (() => void)[] = [];
    const inside = (position: { x: number; y: number }) => { const box = panel.current?.getBoundingClientRect(); const x = position.x / window.devicePixelRatio, y = position.y / window.devicePixelRatio; return !!box && box.width > 0 && x >= box.left && x <= box.right && y >= box.top && y <= box.bottom; };
    const register = <T,>(name: string, callback: (payload: T) => void) => void listen<T>(name, event => callback(event.payload)).then(off => { if (disposed) off(); else cleanup.push(off); }).catch(error => setError(message(error)));
    register<{ position: { x: number; y: number } }>('tauri://drag-over', data => setDropActive(inside(data.position)));
    register<{ paths: string[]; position: { x: number; y: number } }>('tauri://drag-drop', data => { setDropActive(false); if (inside(data.position)) dropHandler.current(data.paths); });
    register('tauri://drag-leave', () => setDropActive(false));
    return () => { disposed = true; cleanup.forEach(off => off()); };
  }, []);
  async function transfer(upload: boolean, entry?: Entry) {
    setError('');
    try {
      const chosen = upload ? await open({ multiple: true, directory: false }) : await save({ defaultPath: entry?.name });
      if (chosen) enqueue(Array.isArray(chosen) ? chosen : [chosen], upload, entry);
    } catch (error) { setError(message(error)); }
  }
  async function fileAction(action: string, entry?: Entry) {
    setError('');
    let args: Record<string, unknown> = { server_id: server.id, path: entry?.path || path };
    if (action === 'mkdir') { const name = window.prompt('新目录名称'); if (!name?.trim()) return; args.path = `${path.replace(/\/$/, '')}/${name}`; }
    if (action === 'rename') { const name = window.prompt('新的完整路径', entry?.path); if (!name?.trim() || name === entry?.path) return; args.new_path = name; }
    if (action === 'remove') { if (!window.confirm(`删除“${entry?.path}”？目录必须为空。`)) return; args.is_dir = entry?.is_dir; }
    setBusy(true);
    try {
      if (action === 'read') { const content = await request<string>('sftp.read', args); setEditor({ path: entry!.path, content, original: content }); }
      else { await request(`sftp.${action}`, args); await load(path); }
    } catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  return <aside ref={panel} className={`files ${dropActive ? 'drop-active' : ''}`} style={{ display: visible ? undefined : 'none' }}><div className="dialog-heading"><h2>SFTP 文件</h2><button onClick={close} aria-label="关闭文件面板">×</button></div>
    <small className="muted">拖入本地文件可上传到当前目录</small>
    <form className="path" onSubmit={event => { event.preventDefault(); void load(path); }}><input aria-label="远程目录" disabled={busy || !!transferId} value={path} onChange={event => setPath(event.target.value)} /><button disabled={busy || !!transferId}>前往</button></form>
    <div className="file-actions"><button disabled={busy || !!transferId} onClick={() => void load(`${path}/..`)}>上一级</button><button disabled={busy} onClick={() => void transfer(true)}>上传文件</button><button disabled={busy || !!transferId} onClick={() => void fileAction('mkdir')}>新建目录</button></div><div className="toolbar"><label><input type="checkbox" checked={hidden} onChange={event => setHidden(event.target.checked)} />隐藏文件</label><input aria-label="搜索文件" placeholder="搜索文件" value={filter} onChange={event => setFilter(event.target.value)} /><select aria-label="文件排序" value={sort} onChange={event => setSort(event.target.value)}><option value="name">名称</option><option value="size">大小</option></select></div>
    {error && <p className="error" role="alert">{error}</p>}
    {busy ? <p className="muted">读取目录中…</p> : <div className="file-list">{entries.length === 0 && <p className="muted">此目录为空</p>}{entries.filter(entry => (hidden || !entry.name.startsWith('.')) && entry.name.toLowerCase().includes(filter.toLowerCase())).sort((a, b) => Number(b.is_dir) - Number(a.is_dir) || (sort === 'size' ? b.size - a.size : a.name.localeCompare(b.name))).map(entry => <div key={entry.path}><button className="file-row" key={entry.path} disabled={busy || !!transferId} onClick={() => entry.is_dir ? void load(entry.path) : void transfer(false, entry)}><span>{entry.is_dir ? '▸' : '↓'} {entry.name}</span><small>{entry.is_dir ? '目录' : `${(entry.size / 1024).toFixed(1)} KB`}</small></button><div className="file-controls">{!entry.is_dir && <button disabled={busy || !!transferId} onClick={() => void fileAction('read', entry)}>编辑文本</button>}<button disabled={busy || !!transferId} onClick={() => void fileAction('rename', entry)}>重命名</button><button disabled={busy || !!transferId} onClick={() => void fileAction('remove', entry)}>删除</button></div></div>)}</div>}
    {!!queue.length && <details className="transfer-queue" open><summary>传输队列 · {queue.filter(item => item.state === '完成').length}/{queue.length}</summary>{queue.map(item => <div className="row" key={item.key}><span>{item.upload ? '↑' : '↓'} {item.remote.split('/').pop()}<small>{item.state} · {item.progress}</small></span>{item.state === '未完成' && <button onClick={() => setQueue(items => items.map(value => value.key === item.key ? { ...value, state: '等待', progress: '' } : value))}>重试</button>}{item.state === '等待' && <button onClick={() => setQueue(items => items.filter(value => value.key !== item.key))}>移除</button>}</div>)}<button onClick={() => setQueue(items => items.filter(item => ['等待', '传输中'].includes(item.state)))}>清理已结束传输</button></details>}
    <footer>{progress}{transferId && <button onClick={() => void invoke('cancel_transfer', { id: transferId }).catch(error => setError(message(error)))}>取消传输</button>}</footer>
    {visible && editor && <div className="scrim"><section className="dialog file-editor" role="dialog" aria-label="远程文本编辑"><h2>{editor.path}</h2><textarea aria-label="文件内容" value={editor.content} disabled={busy} spellCheck={false} onChange={event => setEditor({ ...editor, content: event.target.value })} />{error && <p className="error">{error}</p>}<div className="dialog-actions"><button disabled={busy} onClick={() => { if (editor.content === editor.original || window.confirm('放弃未保存的修改？')) setEditor(null); }}>关闭编辑器</button><button disabled={busy || editor.content === editor.original} onClick={() => { setBusy(true); void request('sftp.write', { server_id: server.id, path: editor.path, content: editor.content }).then(() => { setEditor({ ...editor, original: editor.content }); setProgress('文件已保存'); }).catch(error => setError(message(error))).finally(() => setBusy(false)); }}>保存到服务器</button></div></section></div>}
  </aside>;
}

function App() {
  const databaseContexts = useRef(new Map<string, string>());
  const [databaseTabs, setDatabaseTabs] = useState<{ id: string; name: string }[]>([]);
  const [servers, setServers] = useState<Server[]>([]); const [tabs, setTabs] = useState<Tab[]>([]); const [active, setActive] = useState('');
  const [quick, setQuick] = useState(''); const [quickOpen, setQuickOpen] = useState(false); const [adding, setAdding] = useState(false); const [error, setError] = useState(''); const [fileServer, setFileServer] = useState<Server | null>(null);
  const [fileContexts, setFileContexts] = useState<Server[]>([]);
  useEffect(() => { if (fileServer) setFileContexts(items => items.some(item => item.id === fileServer.id) ? items : [...items, fileServer]); }, [fileServer]);
  const [hostKeys, setHostKeys] = useState<HostKey[]>([]);
  const [settings, setSettings] = useState<Settings>(readSettings); const [settingsOpen, setSettingsOpen] = useState(false);
  const updates = useUpdates(settings.autoUpdate);
  const handles = useRef(new Map<string, TerminalHandle>());
  const [palette, setPalette] = useState(false);
  const [credentialCreating, setCredentialCreating] = useState(false);
  const [paletteSnippets, setPaletteSnippets] = useState<{ id: string; name: string; command: string; group: string; description?: string; tags?: string[] }[]>([]);
  useEffect(() => { if (palette) { try { setPaletteSnippets(JSON.parse(localStorage.getItem('orbit-snippets') || '[]')); } catch { setPaletteSnippets([]); } } }, [palette]);
  const [ready, setReady] = useState(false);
  const [tool, setTool] = useState<'monitor' | 'database' | 'batch' | 'forwards' | 'snippets' | 'ai' | 'agent' | 'logs' | null>(null);
  const [aiConfigRequest, setAIConfigRequest] = useState({ id: '', serial: 0 });
  const [audit, setAudit] = useState<Record<string, AuditEvent[]>>({});
  const [aiContexts, setAIContexts] = useState<string[]>([]);
  useEffect(() => { if (tool === 'ai') setAIContexts(value => value.includes(active || 'home') ? value : [...value, active || 'home']); }, [tool, active]);
  const [openedTools, setOpenedTools] = useState<string[]>([]);
  useEffect(() => { if (tool) setOpenedTools(value => value.includes(tool) ? value : [...value, tool]); }, [tool]);
  const [forwards, setForwards] = useState<Forward[]>([]);
  const [temporaryOpen, setTemporaryOpen] = useState(false); const [connectionDefaults, setConnectionDefaults] = useState<Partial<Server>>({});
  const [managing, setManaging] = useState(false); const [editing, setEditing] = useState<Server | undefined>();
  const current = tabs.find(tab => tab.token === active);
  const refresh = () => { void invoke<Server[]>('servers').then(setServers).catch(error => setError(message(error))); };
  useEffect(() => {
    let disposed = false; let unlisten: (() => void) | undefined;
    void listen<HostKey>('host-key', event => setHostKeys(keys => keys.some(key => key.id === event.payload.id) ? keys : [...keys, event.payload])).then(off => { if (disposed) off(); else { unlisten = off; setReady(true); refresh(); } }).catch(error => setError(message(error)));
    return () => { disposed = true; unlisten?.(); };
  }, []);
  function connect(server: Server, splitFrom?: string, temporary?: Record<string, unknown>) { const token = crypto.randomUUID(); setTabs(tabs => [...tabs, { token, server, temporary, root: token, focused: token }]); setActive(token); setTool(null); }
  function openDatabase(connection: { id: string; name: string }) { setDatabaseTabs(items => items.some(item => item.id === connection.id) ? items : [...items, connection]); setActive(`db:${connection.id}`); setTool(null); }
  function closeDatabase(id: string) { setDatabaseTabs(items => items.filter(item => item.id !== id)); if (active === `db:${id}`) setActive(tabs.at(-1)?.token || ''); }
  function returnToTerminal() { setTool(null); if (active.startsWith('db:')) setActive(tabs.at(-1)?.token || ''); }
  function closeTab(token: string) {
    const remaining = tabs.filter(tab => tab.token !== token); setTabs(remaining);
    if (active === token) setActive(remaining.at(-1)?.token || '');
  }
  async function trust(accepted: boolean) {
    try { await invoke('resolve_host_key', { id: hostKeys[0].id, trust: accepted }); setHostKeys(keys => keys.slice(1)); if (accepted) setError('主机指纹已保存，请点击终端上的“重新连接”。'); }
    catch (error) { setError(message(error)); }
  }
  const localServer: Server = { id: '__local__', name: 'PowerShell', host: 'localhost', port: 0, username: '', auth_type: '', jump_server_id: '' };
  function splitCurrent(vertical: boolean) { if (!current) return; const next = crypto.randomUUID(); setTabs(value => value.map(tab => tab.token === active ? { ...tab, root: splitPane(tab.root, tab.focused, next, vertical), focused: next } : tab)); }
  function focusPane(id: string) { setTabs(value => value.map(tab => tab.token === active && tab.focused !== id ? { ...tab, focused: id } : tab)); }
  function closePane() { if (!current) return; const root = removePane(current.root, current.focused); if (!root) closeTab(current.token); else setTabs(value => value.map(tab => tab.token === active ? { ...tab, root, focused: leaves(root)[0] } : tab)); }
  function changeRatio(id: string, ratio: number) { setTabs(value => value.map(tab => tab.token === active ? { ...tab, root: resizePane(tab.root, id, ratio) } : tab)); }
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      const action = actionFor(event, settings.bindings); if (!action || document.querySelector('.scrim')) return;
      event.preventDefault(); const terminal = current && handles.current.get(current.focused);
      if (action === 'newTerminal') connect(localServer);
      if (action === 'closePane') closePane();
      if (action === 'commandPalette') setPalette(value => !value);
      if (action === 'settings') setSettingsOpen(true);
      if (action === 'quickConnect') document.querySelector<HTMLInputElement>('[aria-label="快速连接"]')?.focus();
      if (action === 'toggleSftp' && current && current.server.id !== '__local__' && !current.temporary) setFileServer(fileServer ? null : current.server);
      if (action === 'findInTerminal') terminal?.find();
      if (action === 'clearScreen') terminal?.clear();
      if (action === 'reconnect') terminal?.reconnect();
      if (action === 'splitHorizontal' || action === 'splitVertical') splitCurrent(action === 'splitVertical');
      if (current && (action === 'navPrevPane' || action === 'navNextPane')) { const ids = leaves(current.root); focusPane(ids[(ids.indexOf(current.focused) + (action === 'navNextPane' ? 1 : ids.length - 1)) % ids.length]); }
      if (current && typeof current.root !== 'string' && (action === 'growPane' || action === 'shrinkPane')) changeRatio(current.root.id, current.root.ratio + (action === 'growPane' ? 5 : -5));
    };
    window.addEventListener('keydown', handler); return () => window.removeEventListener('keydown', handler);
  }, [active, tabs, settings.bindings, fileServer]);
  useEffect(() => { void request('settings.connection', { timeout: settings.timeout, keepalive: settings.keepalive }).catch(error => setError(message(error))); }, [settings.timeout, settings.keepalive]);
  const key = hostKeys[0];
  return <div className="app"><UpdateDialog updates={updates} />
    <header className="global-toolbar"><span>SSH 工作台</span><div className="quick-connect"><Icon name="search" /><input aria-label="快速连接" placeholder="搜索服务器或输入 user@host:port" value={quick} onFocus={() => setQuickOpen(true)} onChange={event => setQuick(event.target.value)} onKeyDown={event => { if (event.key === 'Escape') setQuickOpen(false); if (event.key === 'Enter') { const match = /^([^@\s]+)@([^:\s]+)(?::(\d+))?$/.exec(quick.trim()); if (match && Number(match[3] || 22) <= 65535 && Number(match[3] || 22) > 0) { setConnectionDefaults({ name: match[2], username: match[1], host: match[2], port: Number(match[3] || 22) }); setTemporaryOpen(true); setQuickOpen(false); } else { const found = servers.find(server => `${server.name} ${server.host}`.toLowerCase().includes(quick.toLowerCase())); if (found) { connect(found); setQuickOpen(false); } } } }} />{quickOpen && <div className="quick-results">{servers.filter(server => `${server.name} ${server.host}`.toLowerCase().includes(quick.toLowerCase())).map(server => <button key={server.id} onClick={() => { connect(server); setQuickOpen(false); setQuick(''); }}><Icon name="server" /><span>{server.name}<small>{server.username}@{server.host}:{server.port}</small></span></button>)}<button onClick={() => { setTemporaryOpen(true); setQuickOpen(false); }}>临时连接</button><button onClick={() => setQuickOpen(false)}>关闭</button></div>}</div><div className="global-actions"><details className="workspace-menu new-menu"><summary aria-label="新增" title="新增"><Icon name="plus" /></summary><div onClick={event => { const menu = event.currentTarget.closest('details'); if (menu) menu.open = false; }}><button onClick={() => setTemporaryOpen(true)}>临时连接</button><button onClick={() => connect(localServer)}>本地终端</button><button onClick={() => setAdding(true)}>添加服务器</button><button onClick={() => setCredentialCreating(true)}>新建凭据组</button></div></details><button title="设置" aria-label="设置" onClick={() => setSettingsOpen(true)}><Icon name="settings" /></button></div></header>
    <div className="workbench"><AssetSidebar changed={refresh} edit={server => { setEditing(server); setAdding(true); }} servers={servers} connected={tabs.map(tab => tab.server.id)} remove={server => { if (window.confirm(`删除服务器“${server.name}”？`)) void invoke('delete_server', { id: server.id }).then(refresh).catch(error => setError(message(error))); }} current={current?.server.id} ready={ready} connect={server => connect(server)} add={() => setAdding(true)} manage={() => setManaging(true)} database={connection => connection ? openDatabase(connection) : setTool('database')} snippets={() => setTool('snippets')} />
    <main><div className="tabbar"><div className="tabs" role="tablist">{tabs.map(tab => <div className={`tab ${active === tab.token ? 'selected' : ''}`} key={tab.token}><i className="dot" /><button role="tab" aria-selected={active === tab.token} onClick={() => { setActive(tab.token); }}>{tab.server.name}</button><button aria-label={`关闭 ${tab.server.name}`} onClick={() => closeTab(tab.token)}>×</button></div>)}{databaseTabs.map(tab => <div className={`tab ${active === `db:${tab.id}` ? 'selected' : ''}`} key={tab.id}><Icon name="database" /><button role="tab" aria-selected={active === `db:${tab.id}`} onClick={() => { setActive(`db:${tab.id}`); setTool(null); }}>{tab.name}</button><button aria-label={`关闭数据库 ${tab.name}`} onClick={() => closeDatabase(tab.id)}>×</button></div>)}</div><div className="tab-actions"><details className="workspace-menu"><summary aria-label="工作区操作" title="工作区操作"><Icon name="more" /></summary><div><button onClick={() => setTool('agent')}>Agent</button><button onClick={() => setTool('batch')}>批量执行</button><button onClick={() => setTool('forwards')}>转发</button>{current && <><button onClick={() => { splitCurrent(false); }}>左右分屏</button><button onClick={() => { splitCurrent(true); }}>上下分屏</button></>}</div></details></div></div>
      {error && <div className="notice" role="alert"><span>{error}</span><button aria-label="关闭提示" onClick={() => setError('')}>×</button></div>}
      <div className="workspace" data-tool={tool || ''}><Agent servers={servers} visible={tool === 'agent'} close={() => setTool(null)} />{aiContexts.filter(id => id === 'home' || tabs.some(tab => tab.token === id) || databaseTabs.some(tab => `db:${tab.id}` === id)).map(id => { const target = tabs.find(tab => tab.token === id); return <AIChat configRequest={aiConfigRequest.id === id ? aiConfigRequest.serial : 0} key={id} audit={event => setAudit(value => ({ ...value, [id]: [...(value[id] || []).slice(-99), event] }))} servers={servers} visible={tool === 'ai' && (active || 'home') === id} contextLabel={id.startsWith('db:') ? '附加当前数据库上下文' : '附加当前终端最近输出'} context={() => target ? handles.current.get(target.focused)?.context() || '' : databaseContexts.current.get(id.slice(3)) || ''} insert={text => { if (target) { handles.current.get(target.focused)?.paste(text); setTool(null); } else setError('请先打开终端'); }} close={() => setTool(null)} />; })}{tool === 'logs' && <section className="tool-panel audit-panel"><div className="dialog-heading"><h2>执行日志</h2><button onClick={() => setTool(null)}>关闭</button></div><p className="muted">当前会话的 AI 命令执行记录</p>{!(audit[active || 'home'] || []).length && <p className="muted">暂无执行记录</p>}{(audit[active || 'home'] || []).slice().reverse().map(event => <details key={event.id}><summary>{event.success ? '成功' : '失败'} · {event.server} · {new Date(event.time).toLocaleTimeString()}</summary><pre className="result-output">$ {event.command}{'\n'}{event.output}</pre></details>)}</section>}{tool === 'snippets' && <Snippets insert={text => { if (current) { handles.current.get(current.focused)?.paste(text); setTool(null); } else setError('请先打开终端'); }} close={() => setTool(null)} />}{tool === 'forwards' && <Forwards servers={servers} forwards={forwards} setForwards={setForwards} close={() => setTool(null)} />}{openedTools.includes('database') && <Databases context={(id, text) => databaseContexts.current.set(id, text)} servers={servers} settings={settings} visible={tool === 'database'} openConnection={openDatabase} removed={closeDatabase} close={returnToTerminal} />}{databaseTabs.map(tab => <Databases context={(id, text) => databaseContexts.current.set(id, text)} key={tab.id} connectionId={tab.id} servers={servers} settings={settings} visible={active === `db:${tab.id}` && tool !== 'database'} openConnection={openDatabase} removed={closeDatabase} close={returnToTerminal} />)}{openedTools.includes('batch') && <Batch servers={servers} visible={tool === 'batch'} close={() => setTool(null)} />}{tool === 'monitor' && current && <Monitor settings={settings} key={current.server.id} server={current.server} close={() => setTool(null)} />}{tabs.length ? tabs.flatMap(tab => layout(tab.root).panes.map(pane => <TerminalPane key={pane.id} tab={{ ...tab, token: pane.id }} active={tab.token === active} focused={tab.focused === pane.id} focus={() => focusPane(pane.id)} handles={handles} settings={settings} saved={refresh} style={{ top: `${pane.rect.top}%`, left: `${pane.rect.left}%`, width: `${pane.rect.width}%`, height: `${pane.rect.height}%`, bottom: 'auto', right: 'auto' }} report={setError} />)) : <Home servers={servers} connect={server => connect(server)} local={() => connect(localServer)} add={() => setAdding(true)} palette={() => setPalette(true)} />}{current && layout(current.root).dividers.map(({ node, rect }) => <div key={node.id} role="separator" aria-label="调整分屏" aria-orientation={node.vertical ? 'horizontal' : 'vertical'} aria-valuenow={node.ratio} aria-valuemin={10} aria-valuemax={90} tabIndex={0} className={`pane-divider ${node.vertical ? 'horizontal' : 'vertical'}`} style={node.vertical ? { left: `${rect.left}%`, width: `${rect.width}%`, top: `${rect.top + rect.height * node.ratio / 100}%` } : { top: `${rect.top}%`, height: `${rect.height}%`, left: `${rect.left + rect.width * node.ratio / 100}%` }} onKeyDown={event => { if (['ArrowLeft', 'ArrowUp', 'ArrowRight', 'ArrowDown'].includes(event.key)) { event.preventDefault(); changeRatio(node.id, node.ratio + (['ArrowLeft', 'ArrowUp'].includes(event.key) ? -5 : 5)); } }} onPointerDown={event => { event.preventDefault(); event.currentTarget.setPointerCapture(event.pointerId); }} onPointerMove={event => { if (!event.currentTarget.hasPointerCapture(event.pointerId)) return; const box = event.currentTarget.parentElement!.getBoundingClientRect(); const position = node.vertical ? (event.clientY - box.top) / box.height * 100 : (event.clientX - box.left) / box.width * 100; changeRatio(node.id, (position - (node.vertical ? rect.top : rect.left)) / (node.vertical ? rect.height : rect.width) * 100); }} onPointerUp={event => event.currentTarget.releasePointerCapture(event.pointerId)} />)}{current && leaves(current.root).length > 1 && <button className="merge-panes" onClick={() => setTabs(value => value.map(tab => tab.token === active ? { ...tab, root: tab.focused } : tab))}>合并视图</button>}{fileContexts.map(server => <Files key={server.id} server={server} visible={fileServer?.id === server.id} close={() => setFileServer(null)} />)}</div>
      <footer className="statusbar"><span>{current && `${tabs.length} 个终端`}</span><button onClick={() => setPalette(true)}>Ctrl Shift P 命令面板</button></footer>
    </main>
    <aside className="tool-dock" aria-label="会话工具">{([{ name: 'AI', icon: 'ai', value: 'ai' }, { name: '文件', icon: 'folder', value: 'files' }, { name: '监控', icon: 'monitor', value: 'monitor' }, { name: '片段', icon: 'snippets', value: 'snippets' }, { name: '日志', icon: 'logs', value: 'logs' }] as const).map(item => <button key={item.value} title={item.name} aria-label={item.name} aria-pressed={item.value === 'files' ? !!fileServer : tool === item.value} disabled={['files', 'monitor'].includes(item.value) && (!current || current.server.id === '__local__' || !!current.temporary)} onClick={() => { if (item.value === 'files') setFileServer(fileServer ? null : current!.server); else setTool(tool === item.value ? null : item.value); }}><Icon name={item.icon} /></button>)}</aside></div>
    {temporaryOpen && <ServerDialog servers={servers} initial={connectionDefaults} close={() => { setTemporaryOpen(false); setConnectionDefaults({}); }} created={refresh} temporary={input => { const server: Server = { id: `temporary:${crypto.randomUUID()}`, name: String(input.name || input.host), host: String(input.host), port: Number(input.port), username: String(input.username), auth_type: String(input.auth_type), jump_server_id: String(input.jump_server_id || '') }; connect(server, undefined, input); }} />}
    {settingsOpen && <SettingsDialog checkUpdates={() => void updates.checkNow()} openPanel={panel => { setSettingsOpen(false); if (panel === 'ai') setAIConfigRequest(value => ({ id: active || 'home', serial: value.serial + 1 })); setTool(panel); }} imported={refresh} settings={settings} close={() => setSettingsOpen(false)} save={settings => { setSettings(settings); localStorage.setItem('orbit-settings', JSON.stringify(settings)); }} />}
    {palette && <CommandPalette close={() => setPalette(false)} actions={[
      { id: 'local', name: '新建本地终端', run: () => connect(localServer) },
      { id: 'add', name: '添加服务器', run: () => setAdding(true) },
      { id: 'temporary', name: '临时连接', run: () => setTemporaryOpen(true) },
      { id: 'credentials', name: '新建凭据组', run: () => { setCredentialCreating(true); } },
      { id: 'settings', name: '打开设置', run: () => setSettingsOpen(true) },
      { id: 'database', name: '数据库', run: () => setTool('database') },
      { id: 'batch', name: '批量执行', run: () => setTool('batch') },
      { id: 'forwards', name: '端口转发', run: () => setTool('forwards') },
      { id: 'snippets', name: '管理命令片段', run: () => setTool('snippets') },
      { id: 'agent', name: 'AI Agent 授权与审计', run: () => setTool('agent') },
      { id: 'split', name: '左右分屏', disabled: !current, run: () => splitCurrent(false) },
      { id: 'vertical', name: '上下分屏', disabled: !current, run: () => splitCurrent(true) },
      ...servers.map(server => ({ id: server.id, name: `连接 ${server.name}`, detail: `${server.username}@${server.host}:${server.port}`, run: () => connect(server) })),
      ...paletteSnippets.map(snippet => ({ id: `snippet-${snippet.id}`, name: snippet.name, detail: `${snippet.group} · ${snippet.command} · ${snippet.description || ''} ${(snippet.tags || []).join(' ')}`, disabled: !current, run: () => handles.current.get(current!.focused)?.paste(snippet.command) })),
    ]} />}
    {credentialCreating && <ServerDialog servers={servers} credentialsOnly close={() => setCredentialCreating(false)} created={() => window.dispatchEvent(new Event('orbit-assets-changed'))} />}
    {managing && <AssetManager servers={servers} changed={refresh} close={() => setManaging(false)} edit={server => { setEditing(server); setAdding(true); }} />}
    {adding && <ServerDialog servers={servers} server={editing} close={() => { setAdding(false); setEditing(undefined); }} created={refresh} />}
    {key && <div className="scrim"><div className="dialog" role="dialog" aria-modal="true" aria-labelledby="trust-title"><small>SSH 主机验证 · {key.role}</small><h2 id="trust-title">{key.previous_fingerprint ? '主机指纹发生变化' : '确认服务器身份'}</h2><p>{key.host}:{key.port} · {key.algorithm}</p><label>当前指纹<code className="fingerprint">{key.fingerprint}</code></label>{key.previous_fingerprint && <label>此前指纹<code className="fingerprint">{key.previous_fingerprint}</code></label>}<p className="muted">请与服务器管理员提供的指纹核对，确认一致后再信任。</p><div className="dialog-actions"><button onClick={() => void trust(false)}>拒绝</button><button className="primary" onClick={() => void trust(true)}>信任此指纹</button></div></div></div>}
  </div>;
}

createRoot(document.getElementById('root')!).render(<App />);
