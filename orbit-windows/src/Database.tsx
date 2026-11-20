import React, { useEffect, useRef, useState } from 'react';
import { Settings } from './Settings';
import { autoLimit, tableQuery } from './queryPolicy';
import { open } from '@tauri-apps/plugin-dialog';
import { message, request, Server } from './api';

type Connection = { id: string; name: string; engine: string; group_name: string; host: string; port: number; username: string; database_name: string; sqlite_path: string; use_ssh_tunnel: boolean; ssh_server_id: string; ssl_mode: string };
type Schema = { tables: { name: string; columns: { name: string; db_type: string; nullable: boolean; primary_key: boolean }[] }[] };
type Result = { columns: string[]; rows: (string | null)[][]; affected_rows: number; elapsed_ms: number; message: string };
type Operation = { ok: boolean; code: string; message: string; artifact_path: string | null };
type Backup = { id: string; connection_name: string; artifact_path: string; operation: string; status: string; summary: string; created_at: string };
type Plan = { backup_path: string; target_connection_id: string; mode: string; tables: { source_table: string; target_table: string; columns: { source_column: string; target_column: string | null; target_type: string; required_without_default: boolean; [key: string]: unknown }[] }[] };

function ConnectionDialog({ connection, servers, close, saved }: { connection?: Connection; servers: Server[]; close: () => void; saved: () => void }) {
  const [engine, setEngine] = useState(connection?.engine || 'remote_sqlite'); const [tunnel, setTunnel] = useState(connection?.use_ssh_tunnel || false);
  const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault(); const data = new FormData(event.currentTarget); const text = (key: string) => String(data.get(key) || '').trim();
    setBusy(true); setError('');
    try { await request('database.save', { id: connection?.id, input: { name: text('name'), group_name: text('group_name'), engine, ssh_server_id: text('ssh_server_id'), use_ssh_tunnel: tunnel, host: text('host'), port: Number(text('port')) || (engine === 'mysql' ? 3306 : 5432), username: text('username'), password: String(data.get('password') || '') || null, database_name: text('database_name'), sqlite_path: text('sqlite_path'), ssl_mode: text('ssl_mode') } }); saved(); close(); }
    catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  return <div className="scrim"><form className="dialog" role="dialog" aria-label="数据库连接" onSubmit={submit}><h2>{connection ? '编辑' : '添加'}数据库</h2>
    <label>连接名称<input required name="name" defaultValue={connection?.name} /></label><label>分组<input name="group_name" defaultValue={connection?.group_name} /></label>
    <label>引擎<select value={engine} onChange={event => setEngine(event.target.value)}><option value="remote_sqlite">远程 SQLite</option><option value="mysql">MySQL</option><option value="postgres">PostgreSQL</option></select></label>
    {engine !== 'remote_sqlite' && <><label className="check"><input type="checkbox" checked={tunnel} onChange={event => setTunnel(event.target.checked)} />通过 SSH 隧道</label><div className="fields"><label>数据库主机<input required name="host" defaultValue={connection?.host || '127.0.0.1'} /></label><label className="port">端口<input key={engine} required name="port" type="number" min="1" max="65535" defaultValue={connection?.port || (engine === 'mysql' ? 3306 : 5432)} /></label></div><label>数据库名称<input name="database_name" placeholder={engine === 'mysql' ? '可选；留空可在工作台切换数据库' : '数据库名称'} required={engine !== 'mysql'} defaultValue={connection?.database_name} /></label><label>用户名<input name="username" required defaultValue={connection?.username} /></label><label>密码<input type="password" name="password" autoComplete="new-password" placeholder={connection ? '留空保留原密码' : ''} /></label><label>SSL<select name="ssl_mode" defaultValue={connection?.ssl_mode || 'prefer'}><option value="disable">禁用</option><option value="prefer">优先</option><option value="require">必须</option></select></label></>}
    {(engine === 'remote_sqlite' || tunnel) && <label>SSH 服务器<select name="ssh_server_id" required defaultValue={connection?.ssh_server_id}><option value="">请选择</option>{servers.map(server => <option key={server.id} value={server.id}>{server.name}</option>)}</select></label>}
    {engine === 'remote_sqlite' && <label>远程数据库路径<input name="sqlite_path" required defaultValue={connection?.sqlite_path} placeholder="/var/lib/app/data.db" /></label>}
    {error && <p className="error" role="alert">{error}</p>}<div className="dialog-actions"><button type="button" disabled={busy} onClick={close}>取消</button><button className="primary" disabled={busy}>保存连接</button></div>
  </form></div>;
}

export function Databases({ servers, close, visible, settings, connectionId, openConnection, removed, context }: { servers: Server[]; close: () => void; visible: boolean; settings: Settings; connectionId?: string; openConnection: (connection: { id: string; name: string }) => void; removed: (id: string) => void; context: (id: string, text: string) => void }) {
  const [connections, setConnections] = useState<Connection[]>([]); const [selected, setSelected] = useState(connectionId || ''); const [editing, setEditing] = useState<Connection | 'new' | null>(null);
  const [schema, setSchema] = useState<Schema | null>(null); const [result, setResult] = useState<Result | null>(null); const [sql, setSql] = useState(''); const [readOnly, setReadOnly] = useState(settings.dbReadOnly);
  const [busy, setBusy] = useState(false); const [error, setError] = useState(''); const [status, setStatus] = useState(''); const [backups, setBackups] = useState<Backup[]>([]); const [plan, setPlan] = useState<Plan | null>(null);
  const snapshots = useRef(new Map<string, { sql: string; schema: Schema | null; result: Result | null; readOnly: boolean }>());
  const connectionSignature = useRef('');
  const [browsing, setBrowsing] = useState(false); const [browseResult, setBrowseResult] = useState<Result | null>(null); const [browseTable, setBrowseTable] = useState('');
  const [catalogs, setCatalogs] = useState<string[]>([]); const [catalog, setCatalog] = useState('');
  const [filter, setFilter] = useState('');
  function selectConnection(id: string) {
    const target = connections.find(item => item.id === id); if (target && (!connectionId || target.id !== selected)) { openConnection(target); return; }
    if (selected) snapshots.current.set(selected, { sql, schema, result, readOnly });
    const next = snapshots.current.get(id); setSelected(id); setSql(next?.sql || ''); setSchema(next?.schema || null); setResult(next?.result || null); setReadOnly(next?.readOnly ?? settings.dbReadOnly); setPlan(null); setFilter(''); setError(''); setStatus('');
  }
  const connection = connections.find(connection => connection.id === selected);
  useEffect(() => { if (connectionId && connection) context(connectionId, JSON.stringify({ database: connection.database_name || catalog, connection: connection.name, engine: connection.engine, sql, tables: schema?.tables.slice(0, 30), result: result && { columns: result.columns, rows: result.rows.slice(0, 10), rowCount: result.rows.length } }).slice(0, 16000)); }, [connectionId, connection?.name, catalog, sql, schema, result]);
  const refresh = async () => {
    const items = await request<Connection[]>('database.list') || []; setConnections(items);
    setBackups(await request<Backup[]>('database.history') || []); window.dispatchEvent(new Event('orbit-assets-changed'));
    const current = items.find(item => item.id === selected);
    if (current) {
      const signature = JSON.stringify(current);
      if (connectionSignature.current !== signature) {
        connectionSignature.current = signature; snapshots.current.clear(); setCatalog(''); setCatalogs([]); setSchema(null); setResult(null); setBrowseResult(null); setBrowsing(false); setSql(''); setPlan(null);
        if (current.engine === 'mysql' && !current.database_name) setCatalogs(await request<string[]>('database.catalogs', { id: current.id }));
        else setSchema(await request<Schema>('database.schema', { id: current.id }));
      }
    }
  };
  const run = async (work: () => Promise<unknown>) => { setBusy(true); setError(''); setStatus(''); try { await work(); } catch (error) { setError(message(error)); } finally { setBusy(false); } };
  const operation = (result: Operation) => { if (!result.ok) throw new Error(result.message); setStatus(`${result.message}${result.artifact_path ? ` · ${result.artifact_path}` : ''}`); };
  useEffect(() => { void run(refresh); }, []);
  const databaseName = connection?.database_name || catalog;
  const needsCatalog = connection?.engine === 'mysql' && !databaseName;
  async function selectCatalog(name: string) {
    if (busy || plan) return;
    snapshots.current.set(catalog, { sql, schema, result, readOnly });
    const next = snapshots.current.get(name); setCatalog(name); setBrowsing(false); setBrowseResult(null); setBrowseTable(''); setSql(next?.sql || ''); setResult(next?.result || null); setSchema(null); setFilter(''); setError(''); setStatus('');
    if (name) await run(async () => setSchema(await request<Schema>('database.schema', { id: selected, database_name: name })));
  }
  async function browse(table: string) {
    if (busy || needsCatalog) return;
    const query = tableQuery(table, connection!.engine, 200); setBrowsing(true); setBrowseTable(table); setBrowseResult(null);
    await run(async () => setBrowseResult(await request<Result>('database.query', { id: selected, database_name: databaseName, input: { sql: query, read_only: true, timeout_ms: settings.dbTimeout * 1000 } })));
  }
  async function execute() {
    if (busy || needsCatalog) return;
    setResult(null);
    if (!readOnly && !window.confirm(`允许对“${connection?.name}”执行以下 SQL 写操作？\n\n${sql}`)) return;
    await run(async () => setResult(await request<Result>('database.query', { id: selected, database_name: databaseName, input: { sql: autoLimit(sql, settings.dbLimit, settings.dbAutoLimit), read_only: readOnly, timeout_ms: settings.dbTimeout * 1000 } })));
  }
  async function restore(importMode?: string) {
    const backup = await open({ multiple: false, filters: [{ name: 'Orbit 数据库备份', extensions: ['json'] }] });
    if (typeof backup !== 'string') return;
    if (importMode) { await run(async () => setPlan(await request<Plan>('database.prepare_import', { id: selected, database_name: databaseName, backup_path: backup, mode: importMode }))); return; }
    if (!window.confirm(`将备份“${backup}”恢复到“${connection?.name}”？这会修改目标数据库。`)) return;
    await run(async () => { operation(await request<Operation>('database.restore', { database_name: databaseName, input: { backup_path: backup, target_connection_id: selected, mode: 'overwrite' } })); await refresh(); });
  }
  const displayedResult = browsing ? browseResult : result;
  return <section className="tool-panel database-panel" style={{ display: visible ? undefined : 'none' }}><div className="dialog-heading"><h2>{connectionId ? connection?.name : '数据库工作台'}</h2><button disabled={busy} onClick={close}>返回终端</button></div>
    <div className="toolbar"><select aria-label="数据库连接" disabled={busy} value={selected} onChange={event => selectConnection(event.target.value)}><option value="">选择连接</option>{connections.map(connection => <option key={connection.id} value={connection.id}>{connection.name} · {connection.engine}</option>)}</select>{connection?.engine === 'mysql' && (connection.database_name ? <span>数据库：{connection.database_name}（固定）</span> : <select aria-label="当前数据库" disabled={busy || !!plan} value={catalog} onChange={event => void selectCatalog(event.target.value)}><option value="">选择数据库</option>{catalogs.map(name => <option key={name} value={name}>{name}</option>)}</select>)}<button disabled={busy} onClick={() => setEditing('new')}>添加数据库</button>{connection && <><button disabled={busy} onClick={() => setEditing(connection)}>编辑连接</button><button disabled={busy} onClick={() => { if (window.confirm(`删除连接“${connection.name}”？`)) void run(async () => { await request('database.delete', { id: selected }); removed(selected); setSelected(''); setSchema(null); setResult(null); await refresh(); }); }}>删除连接</button></>}</div>
    {error && <p className="error" role="alert">{error}</p>}{status && <p role="status">{status}</p>}
    {connection && <><div className="toolbar"><button disabled={busy} onClick={() => void run(async () => operation(await request<Operation>('database.test', { id: selected })))}>测试连接</button><button disabled={busy || needsCatalog} onClick={() => void run(async () => setSchema(await request<Schema>('database.schema', { id: selected, database_name: databaseName })))}>加载结构</button><button disabled={busy || needsCatalog} onClick={() => void run(async () => { operation(await request<Operation>('database.backup', { id: selected, database_name: databaseName })); await refresh(); })}>备份数据库</button><button disabled={busy || needsCatalog} onClick={() => void restore().catch(error => setError(message(error)))}>恢复备份</button>{connection.engine === 'mysql' && <><button disabled={busy || needsCatalog} onClick={() => void restore('new_table').catch(error => setError(message(error)))}>导入 SQLite → 新表</button><button disabled={busy || needsCatalog} onClick={() => void restore('existing_table').catch(error => setError(message(error)))}>导入 SQLite → 现有表</button></>}</div>
      <div className="database-workspace"><aside className="database-schema"><input aria-label="搜索数据表" placeholder="搜索数据表" value={filter} onChange={event => setFilter(event.target.value)} />{schema ? <><small>{schema.tables.length} 张表</small>{schema.tables.filter(table => table.name.toLowerCase().includes(filter.toLowerCase())).map(table => <details key={table.name}><summary className={browseTable === table.name ? 'selected' : ''} onClick={() => void browse(table.name)}>{table.name}</summary>{table.columns.map(column => <div className="schema-column" key={column.name}><span>{column.primary_key ? '◆ ' : ''}{column.name}</span><small>{column.db_type}{column.nullable ? '' : ' · 非空'}</small></div>)}</details>)}</> : <p className="muted">选择数据库后点击表，查看前 200 条数据</p>}</aside><div className="database-query">
      <div className="toolbar"><button aria-pressed={browsing} disabled={!browseTable || busy} onClick={() => setBrowsing(true)}>表数据</button><button aria-pressed={!browsing} disabled={busy} onClick={() => setBrowsing(false)}>SQL 查询</button>{browsing && <><span>{browseTable} · 前 200 行</span><button disabled={busy} onClick={() => void browse(browseTable)}>刷新数据</button></>}</div>
      {!browsing && <><textarea className="sql-editor" aria-label="SQL" disabled={busy} spellCheck={false} value={sql} onChange={event => setSql(event.target.value)} placeholder="输入 SQL" /><div className="toolbar"><label><input type="checkbox" disabled={busy} checked={readOnly} onChange={event => setReadOnly(event.target.checked)} />只读模式</label><button disabled={busy || needsCatalog || !sql.trim()} onClick={() => void execute()}>{busy ? '处理中…' : '执行 SQL'}</button></div></>}
      {displayedResult && <><p>{displayedResult.message} · {displayedResult.rows.length} 行 · 影响 {displayedResult.affected_rows} 行 · {displayedResult.elapsed_ms} ms</p><div className="scroll"><table className="data-table"><thead><tr>{displayedResult.columns.map((column, index) => <th key={index}>{column}</th>)}</tr></thead><tbody>{displayedResult.rows.map((row, index) => <tr key={index}>{row.map((value, column) => <td key={column} title={value === null ? 'NULL' : String(value)}>{value === null ? <em>NULL</em> : value}</td>)}</tr>)}</tbody></table></div></>}
    </div></div></>}
    {!!backups.length && <details><summary>备份与恢复记录</summary>{backups.map(backup => <div className="row" key={backup.id}><span>{backup.created_at} · {backup.connection_name} · {backup.operation} · {backup.status}<br />{backup.summary}<br />{backup.artifact_path}</span></div>)}</details>}
    {visible && editing && <ConnectionDialog servers={servers} connection={editing === 'new' ? undefined : editing} close={() => setEditing(null)} saved={() => void run(refresh)} />}
    {visible && plan && <div className="scrim"><section className="dialog wide" role="dialog" aria-label="导入字段映射"><h2>SQLite → MySQL 字段映射</h2>{plan.tables.map((table, tableIndex) => <fieldset key={tableIndex}><legend>{table.source_table}</legend><label>目标表<input value={table.target_table} onChange={event => setPlan({ ...plan, tables: plan.tables.map((item, index) => index === tableIndex ? { ...item, target_table: event.target.value } : item) })} /></label>{table.columns.map((column, columnIndex) => <div className="row" key={columnIndex}><span>{column.source_column}{column.required_without_default ? '（必填）' : ''}</span><input aria-label={`${column.source_column} 目标列`} value={column.target_column || ''} placeholder="留空忽略" onChange={event => setPlan({ ...plan, tables: plan.tables.map((item, index) => index === tableIndex ? { ...item, columns: item.columns.map((value, index) => index === columnIndex ? { ...value, target_column: event.target.value || null } : value) } : item) })} /><input aria-label={`${column.source_column} 类型`} value={column.target_type} onChange={event => setPlan({ ...plan, tables: plan.tables.map((item, index) => index === tableIndex ? { ...item, columns: item.columns.map((value, index) => index === columnIndex ? { ...value, target_type: event.target.value } : value) } : item) })} /></div>)}</fieldset>)}{error && <p className="error">{error}</p>}<div className="dialog-actions"><button disabled={busy} onClick={() => setPlan(null)}>取消</button><button disabled={busy} onClick={() => { if (window.confirm('确认按以上映射导入？这会修改目标 MySQL 数据库。')) void run(async () => { operation(await request<Operation>('database.import', { database_name: databaseName, input: { plan } })); setPlan(null); await refresh(); }); }}>确认导入</button></div></section></div>}
  </section>;
}
