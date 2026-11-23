import React, { useEffect, useState } from 'react';
import { Organization, Server, request } from './api';

export function Icon({ name }: { name: string }) {
  const paths: Record<string, React.ReactNode> = {
    search: <><circle cx="10" cy="10" r="6" /><path d="m15 15 5 5" /></>,
    server: <><rect x="3" y="4" width="18" height="13" rx="1" /><path d="M8 21h8m-4-4v4" /></>,
    folder: <path d="M3 7V5h6l2 2h10v13H3V7h18" />,
    clock: <><circle cx="12" cy="12" r="9" /><path d="M12 6v6H7" /></>,
    tag: <><path d="m3 12 9-9h8v8l-9 10z" /><circle cx="16" cy="7" r="1" /></>,
    database: <><ellipse cx="12" cy="5" rx="8" ry="3" /><path d="M4 5v14c0 4 16 4 16 0V5M4 12c0 4 16 4 16 0" /></>,
    key: <><path d="m12 2 8 4v7l-8 9-8-9V6z" /><circle cx="12" cy="9" r="2" /><path d="M12 11v5" /></>,
    snippets: <path d="M3 7h5m-3-3 3 3-3 3M12 5h9M12 10h9M3 15h18M3 20h18" />,
    monitor: <path d="M2 12h5l3-9 4 18 3-9h5" />,
    ai: <path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5zM20 2v4m-2-2h4" />,
    settings: <><path d="m10 2 4 0 1 3 3 1 3 1v4l-2 1v3l2 2-2 3-3-1-2 1-1 2h-4l-1-3-3-1-2-1v-4l2-1V9L3 7l2-3 3 1z" /><circle cx="12" cy="12" r="3" /></>,
    terminal: <><rect x="2" y="4" width="20" height="16" rx="2" /><path d="m6 8 4 4-4 4m7 0h5" /></>,
    logs: <><rect x="3" y="3" width="18" height="18" rx="2" /><path d="M7 8h1m3 0h6M7 12h1m3 0h6M7 16h1m3 0h6" /></>,
    more: <><circle cx="5" cy="12" r="1" /><circle cx="12" cy="12" r="1" /><circle cx="19" cy="12" r="1" /></>,
    plus: <path d="M12 3v18M3 12h18" />,
  };
  return <svg className="ui-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name] || paths.terminal}</svg>;
}

export function AssetSidebar({ servers, current, ready, connect, add, manage, database, snippets, remove, connected, edit, changed }: { edit: (server: Server) => void; changed: () => void; servers: Server[]; current?: string; ready: boolean; connected: string[]; remove: (server: Server) => void; connect: (server: Server) => void; add: () => void; manage: () => void; database: (connection?: { id: string; name: string }) => void; snippets: () => void }) {
  const [menu, setMenu] = useState(''); const [busy, setBusy] = useState(false); const [notice, setNotice] = useState('');
  useEffect(() => { const dismiss = (event: MouseEvent) => { if (!(event.target as Element).closest('.asset-entry')) setMenu(''); }; const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') setMenu(''); }; window.addEventListener('click', dismiss); window.addEventListener('keydown', escape); return () => { window.removeEventListener('click', dismiss); window.removeEventListener('keydown', escape); }; }, []);
  async function operate(action: string, args: Record<string, unknown>, success: string) { setBusy(true); setNotice(''); try { await request(action, args); changed(); setNotice(success); setMenu(''); } catch (error) { setNotice(String(error)); } finally { setBusy(false); } }
  const [query, setQuery] = useState(''); const [filter, setFilter] = useState('all');
  const [org, setOrg] = useState<Organization>({ folders: [], tags: [], tag_links: [] });
  const [databases, setDatabases] = useState<{ id: string; name: string; engine: string }[]>([]);
  const [credentials, setCredentials] = useState<{ id: string; name: string }[]>([]);
  const [savedSnippets, setSavedSnippets] = useState<{ id: string; name: string }[]>([]);
  useEffect(() => { const refresh = () => { void request<typeof databases>('database.list').then(value => setDatabases(value || [])).catch(() => {}); void request<typeof credentials>('credentials.list').then(value => setCredentials(value || [])).catch(() => {}); try { setSavedSnippets(JSON.parse(localStorage.getItem('orbit-snippets') || '[]')); } catch { setSavedSnippets([]); } }; refresh(); window.addEventListener('orbit-assets-changed', refresh); return () => window.removeEventListener('orbit-assets-changed', refresh); }, [servers]);
  const [expanded, setExpanded] = useState<string[]>([]);
  useEffect(() => { void request<Organization>('organization.list').then(value => { if (value) setOrg(value); }).catch(() => {}); }, [servers]);
  const matches = (server: Server) => `${server.name} ${server.host} ${server.username}`.toLowerCase().includes(query.toLowerCase());
  const row = (server: Server) => <div className="asset-entry" key={server.id} onContextMenu={event => { event.preventDefault(); setMenu(server.id); }}><button className={`asset-server ${current === server.id ? 'selected' : ''}`} disabled={!ready} aria-label={`${server.name} ${server.username}@${server.host}`} onClick={() => connect(server)}><Icon name="server" /><span>{server.is_pinned ? '★ ' : ''}{server.name}<small>{server.username}@{server.host}</small></span></button><button className="asset-delete" aria-label={`服务器操作 ${server.name}`} aria-expanded={menu === server.id} onClick={() => setMenu(value => value === server.id ? '' : server.id)}>⋯</button>{menu === server.id && <div className="asset-menu" role="menu" aria-label={`${server.name} 操作`}><button role="menuitem" onClick={() => { setMenu(''); connect(server); }}>连接</button><button role="menuitem" onClick={() => { setMenu(''); edit(server); }}>编辑连接</button><button role="menuitem" disabled={busy} onClick={() => void operate('server.duplicate', { id: server.id, name: `${server.name} 副本` }, '已复制服务器')}>复制服务器</button><button role="menuitem" disabled={busy} onClick={() => void operate('server.test', { id: server.id }, '连接测试成功')}>测试连接</button><button role="menuitem" disabled={busy} onClick={() => void operate('server.pin', { id: server.id, is_pinned: !server.is_pinned }, server.is_pinned ? '已取消置顶' : '已置顶')}>{server.is_pinned ? '取消置顶' : '置顶'}</button><button role="menuitem" onClick={() => void navigator.clipboard.writeText(`${server.username}@${server.host}:${server.port}`).then(() => { setMenu(''); setNotice('已复制连接地址'); }).catch(error => setNotice(String(error)))}>复制连接地址</button><button role="menuitem" disabled={busy || connected.includes(server.id)} onClick={() => { setMenu(''); remove(server); }}>删除服务器</button></div>}</div>;
  const folder = (id: string, ancestry: string[] = []): React.ReactNode => {
    const item = org.folders.find(item => item.id === id); if (!item || ancestry.includes(id)) return null;
    const items = servers.filter(server => server.folder_id === id && matches(server)); const open = expanded.includes(id) || !!query;
    return <div className="asset-folder" key={id}><button className="asset-row" aria-expanded={open} onClick={() => setExpanded(value => value.includes(id) ? value.filter(value => value !== id) : [...value, id])}><span className="disclosure">{open ? '⌄' : '›'}</span><Icon name="folder" /><strong>{item.name}</strong><small>{items.length}</small></button>{open && <div className="folder-children">{org.folders.filter(child => child.parent_id === id).map(child => folder(child.id, [...ancestry, id]))}{items.map(row)}</div>}</div>;
  };
  const visible = [...servers].sort((a, b) => (filter === 'recent' ? (b.last_connected_at || '').localeCompare(a.last_connected_at || '') : 0) || Number(!!b.is_pinned) - Number(!!a.is_pinned) || (a.pin_order || 0) - (b.pin_order || 0)).filter(matches).filter(server => filter === 'recent' ? !!server.last_connected_at : filter.startsWith('tag:') ? org.tag_links.some(link => link.server_id === server.id && link.tag_id === filter.slice(4)) : !server.folder_id);
  return <aside className="sidebar"><label className="asset-search"><Icon name="search" /><input aria-label="搜索服务器" placeholder="搜索资产…" value={query} onChange={event => setQuery(event.target.value)} /></label><nav>
    <div className="asset-heading"><Icon name="server" /><strong>服务器</strong><button title="资产与凭据管理" aria-label="资产与凭据管理" onClick={manage}><Icon name="folder" /></button><small>{servers.length}</small></div>
    <button className={`asset-row ${filter === 'all' ? 'selected' : ''}`} onClick={() => setFilter('all')}><Icon name="folder" /><span>全部服务器</span><small>{servers.length}</small></button>
    <button className={`asset-row ${filter === 'recent' ? 'selected' : ''}`} onClick={() => setFilter('recent')}><Icon name="clock" /><span>最近连接</span><small>{servers.filter(server => server.last_connected_at).length}</small></button>
    {filter === 'all' && org.folders.filter(item => !item.parent_id).map(item => folder(item.id))}{visible.map(row)}
    {!!org.tags.length && <><div className="asset-label">标签</div>{org.tags.map(tag => <button className={`asset-row ${filter === `tag:${tag.id}` ? 'selected' : ''}`} key={tag.id} onClick={() => setFilter(`tag:${tag.id}`)}><Icon name="tag" /><span>{tag.name}</span><small>{org.tag_links.filter(link => link.tag_id === tag.id).length}</small></button>)}</>}
    {([{ id: 'databases', name: '数据库', icon: 'database', items: databases, add: () => database(), select: (item: { id: string; name: string }) => database(item) }, { id: 'credentials', name: '凭据组', icon: 'key', items: credentials, add: manage, select: manage }, { id: 'snippets', name: '命令片段', icon: 'snippets', items: savedSnippets, add: snippets, select: snippets }]).map(section => <div key={section.id}><div className="asset-section"><button aria-label={`展开${section.name}`} aria-expanded={expanded.includes(section.id)} onClick={() => setExpanded(items => items.includes(section.id) ? items.filter(id => id !== section.id) : [...items, section.id])}><span className="disclosure">{expanded.includes(section.id) ? '⌄' : '›'}</span><Icon name={section.icon} /><strong>{section.name}</strong><small>{section.items.length}</small></button><button className="section-plus" aria-label={`管理${section.name}`} onClick={section.add}>＋</button></div>{expanded.includes(section.id) && section.items.filter(item => item.name.toLowerCase().includes(query.toLowerCase())).map(item => <button className="asset-row" key={item.id} onClick={() => section.select(item)}><Icon name={section.icon} /><span>{item.name}</span></button>)}</div>)}
  </nav>{notice && <p className="asset-notice" role="status">{notice}</p>}</aside>;
}

export function Home({ servers, connect, local, add, palette }: { servers: Server[]; connect: (server: Server) => void; local: () => void; add: () => void; palette: () => void }) {
  const recent = servers.filter(server => server.last_connected_at).sort((a, b) => (b.last_connected_at || '').localeCompare(a.last_connected_at || '')).slice(0, 8);
  const items = recent.length ? recent : servers.slice(0, 8);
  return <div className="home"><div className="home-content"><header><h2>{recent.length ? '最近连接' : '服务器'}</h2><span>{items.length} 台服务器</span></header><div className="recent-list">{items.map(server => <button key={server.id} onClick={() => connect(server)}><i className="dot" /><span><strong>{server.name}</strong>{server.group_name && <em>{server.group_name}</em>}<code>{server.host}:{server.port}</code></span><small>{server.last_connected_at ? new Date(server.last_connected_at).toLocaleDateString() : '尚未连接'}</small></button>)}{!items.length && <div className="home-empty"><Icon name="server" /><p>暂无服务器</p><small>添加服务器或打开本地终端，开始工作。</small></div>}</div><div className="home-actions"><button onClick={local}><Icon name="terminal" />本地终端</button><button aria-label="首页添加服务器" onClick={add}><Icon name="plus" />{servers.length ? '添加服务器' : '添加第一台服务器'}</button><button onClick={palette}><Icon name="search" />命令面板</button></div></div></div>;
}
