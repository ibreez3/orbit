import React, { useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { open } from '@tauri-apps/plugin-dialog';
import { Credential, message, Organization, request, Server } from './api';

export function ServerDialog({ servers, server, credential, credentialsOnly = false, temporary, initial, close, created }: {
  servers: Server[]; initial?: Partial<Server>; server?: Server; credential?: Credential; credentialsOnly?: boolean; temporary?: (input: Record<string, unknown>) => void; close: () => void; created: () => void;
}) {
  const existing = credentialsOnly ? credential : server;
  const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  const [auth, setAuth] = useState(existing?.auth_type || 'password');
  const [source, setSource] = useState(existing?.key_source || 'content');
  const [keyPath, setKeyPath] = useState(existing?.key_file_path || '');
  const [group, setGroup] = useState(server?.credential_group_id || '');
  const [groups, setGroups] = useState<Credential[]>([]);
  useEffect(() => { if (!credentialsOnly) void request<Credential[]>('credentials.list').then(value => setGroups(value || [])).catch(error => setError(message(error))); }, []);
  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault(); const data = new FormData(event.currentTarget); setBusy(true); setError('');
    const value = (key: string) => String(data.get(key) || '').trim();
    const secret = (key: string) => String(data.get(key) || '') || (existing ? null : '');
    const input = {
      name: value('name'), username: value('username'), auth_type: auth,
      password: group ? '' : auth === 'password' ? secret('password') : '',
      private_key: group ? '' : auth === 'key' && source === 'content' ? secret('private_key') : '',
      key_source: source, key_file_path: source === 'file' ? keyPath : '',
      key_passphrase: group ? '' : auth === 'key' ? secret('key_passphrase') : '',
      ...(credentialsOnly ? {} : { host: value('host'), port: Number(value('port')), credential_group_id: group,
        jump_server_id: value('jump_server_id'), group_name: value('group_name') }),
    };
    try {
      if (temporary) { temporary(input); close(); return; }
      if (credentialsOnly) await request('credentials.save', { id: credential?.id, input });
      else if (server) await request('server.update', { id: server.id, input });
      else await invoke('add_server', { input });
      created(); close();
    } catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  return <div className="scrim"><form className="dialog server-dialog" role="dialog" aria-modal="true" aria-labelledby="server-title" onSubmit={submit}>
    <div className="dialog-heading"><h2 id="server-title">{existing ? '编辑' : '添加'}{credentialsOnly ? '凭据组' : ' SSH 服务器'}</h2><button type="button" aria-label="关闭" disabled={busy} onClick={close}>×</button></div>
    <div className="server-form-content"><h3>基本信息</h3><label>名称<input name="name" required autoFocus defaultValue={existing?.name || initial?.name} /></label>
    {!credentialsOnly && <><h3>连接信息</h3><div className="fields"><label>主机地址<input name="host" required defaultValue={server?.host || initial?.host} /></label><label className="port">端口<input name="port" type="number" min="1" max="65535" defaultValue={server?.port || initial?.port || 22} required /></label></div>
      <label>分组名称<input name="group_name" defaultValue={server?.group_name} /></label>
      <label>凭据组<select value={group} onChange={event => { setGroup(event.target.value); const selected = groups.find(group => group.id === event.target.value); if (selected) setAuth(selected.auth_type); }}><option value="">单独配置</option>{groups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select></label></>}
    <h3>身份认证</h3><label>用户名<input name="username" required autoComplete="off" defaultValue={existing?.username || initial?.username} /></label>
    {!group && <><label>认证方式<select value={auth} onChange={event => setAuth(event.target.value)}><option value="password">密码</option><option value="key">私钥</option></select></label>
      {auth === 'password' ? <label>密码<input name="password" type="password" autoComplete="new-password" required={!existing} placeholder={existing ? '留空保留原密码' : ''} /></label> : <>
        <label>密钥来源<select value={source} onChange={event => setSource(event.target.value)}><option value="content">私钥内容</option><option value="file">本地密钥文件</option></select></label>
        {source === 'content' ? <label>私钥<textarea name="private_key" rows={4} required={!existing} spellCheck={false} placeholder={existing ? '留空保留原私钥' : ''} /></label> : <label>密钥文件<input required value={keyPath} onChange={event => setKeyPath(event.target.value)} /><button type="button" onClick={() => void open({ multiple: false }).then(path => { if (typeof path === 'string') setKeyPath(path); }).catch(error => setError(message(error)))}>选择文件</button></label>}
        <label>私钥口令<input name="key_passphrase" type="password" autoComplete="new-password" placeholder={existing ? '留空保留原口令' : '可选'} /></label>
      </>}</>}
    {!credentialsOnly && <label>跳板机<select name="jump_server_id" defaultValue={server?.jump_server_id || ''}><option value="">直接连接</option>{servers.filter(item => item.id !== server?.id).map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>}
    {error && <p className="error" role="alert">{error}</p>}
    </div><div className="dialog-actions"><button type="button" disabled={busy} onClick={close}>取消</button><button className="primary" disabled={busy}>{busy ? '正在保存…' : temporary ? '临时连接' : credentialsOnly ? '保存凭据组' : '保存服务器'}</button></div>
  </form></div>;
}

export function AssetManager({ servers, changed, close, edit }: { servers: Server[]; changed: () => void; close: () => void; edit: (server: Server) => void }) {
  const [organization, setOrganization] = useState<Organization>({ folders: [], tags: [], tag_links: [] });
  const [credentials, setCredentials] = useState<Credential[]>([]); const [selected, setSelected] = useState('');
  const [credential, setCredential] = useState<Credential | 'new' | null>(null);
  const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  const [name, setName] = useState(''); const [parent, setParent] = useState('');
  const load = async () => { const [org, groups] = await Promise.all([request<Organization>('organization.list'), request<Credential[]>('credentials.list')]); setOrganization(org || { folders: [], tags: [], tag_links: [] }); setCredentials(groups || []); };
  useEffect(() => { void load().catch(error => setError(message(error))); }, []);
  const run = async (action: string, args: Record<string, unknown>) => { setBusy(true); setError(''); try { await request(action, args); await load(); changed(); } catch (error) { setError(message(error)); } finally { setBusy(false); } };
  const server = servers.find(server => server.id === selected);
  return <div className="scrim"><section className="dialog wide" role="dialog" aria-modal="true" aria-label="资产管理">
    <div className="dialog-heading"><h2>资产管理</h2><button disabled={busy} onClick={close}>关闭</button></div>
    {error && <p className="error" role="alert">{error}</p>}
    <fieldset disabled={busy}><legend>服务器</legend><select aria-label="管理服务器" value={selected} onChange={event => setSelected(event.target.value)}><option value="">选择服务器</option>{servers.map(server => <option key={server.id} value={server.id}>{server.name}</option>)}</select>
      {server && <div className="stack"><div className="toolbar"><button onClick={() => edit(server)}>编辑连接</button><button onClick={() => void run('server.duplicate', { id: server.id, name: `${server.name} 副本` })}>复制服务器</button><button onClick={() => void run('server.test', { id: server.id })}>测试连接</button><button onClick={() => void run('server.pin', { id: server.id, is_pinned: !server.is_pinned })}>{server.is_pinned ? '取消置顶' : '置顶'}</button></div>
        <label>目录<select value={server.folder_id || ''} onChange={event => void run('server.move', { id: server.id, folder_id: event.target.value || null })}><option value="">根目录</option>{organization.folders.map(folder => <option key={folder.id} value={folder.id}>{folder.name}</option>)}</select></label>
        <div className="toolbar">{organization.tags.map(tag => <label className="check" key={tag.id}><input type="checkbox" checked={organization.tag_links.some(link => link.server_id === server.id && link.tag_id === tag.id)} onChange={event => { const ids = organization.tag_links.filter(link => link.server_id === server.id && link.tag_id !== tag.id).map(link => link.tag_id); if (event.target.checked) ids.push(tag.id); void run('server.tags', { id: server.id, tag_ids: ids }); }} />{tag.name}</label>)}</div>
        <p className="muted">最近连接：{server.last_connected_at || '尚未连接'} · {server.last_connection_result || ''} {server.last_connection_error || ''}</p>
      </div>}
    </fieldset>
    <fieldset disabled={busy}><legend>目录与标签</legend><div className="toolbar"><input aria-label="新目录或标签名称" value={name} onChange={event => setName(event.target.value)} placeholder="名称" /><select aria-label="父目录" value={parent} onChange={event => setParent(event.target.value)}><option value="">根目录</option>{organization.folders.map(folder => <option key={folder.id} value={folder.id}>{folder.name}</option>)}</select><button disabled={!name.trim()} onClick={() => void run('folder.create', { input: { name, parent_id: parent || null } })}>新建目录</button><button disabled={!name.trim()} onClick={() => void run('tag.create', { name })}>新建标签</button></div>
      {organization.folders.map(folder => <div className="row" key={folder.id}><span>{folder.parent_id ? `${organization.folders.find(parent => parent.id === folder.parent_id)?.name} / ` : ''}{folder.name}</span><button onClick={() => { const name = window.prompt('目录名称', folder.name); if (name?.trim()) void run('folder.rename', { id: folder.id, input: { name } }); }}>重命名</button><button onClick={() => { if (window.confirm(`删除目录“${folder.name}”？${parent ? '服务器移入上方选中的目标目录。' : '仅能删除空目录；非空目录请先在上方选择目标目录。'}`)) void run('folder.delete', { id: folder.id, input: { destination_folder_id: parent || null, delete_servers: false } }); }}>删除目录</button></div>)}
      <div className="toolbar">{organization.tags.map(tag => <button key={tag.id} onClick={() => { if (window.confirm(`删除标签“${tag.name}”？`)) void run('tag.delete', { id: tag.id }); }}>{tag.name} ×</button>)}</div>
    </fieldset>
    <fieldset disabled={busy}><legend>共享凭据</legend><button onClick={() => setCredential('new')}>添加凭据组</button>{credentials.map(group => <div className="row" key={group.id}><span>{group.name} · {group.username} · {group.auth_type}</span><button onClick={() => setCredential(group)}>编辑</button><button onClick={() => { if (window.confirm(`删除凭据组“${group.name}”？`)) void run('credentials.delete', { id: group.id }); }}>删除</button></div>)}</fieldset>
    {credential && <ServerDialog servers={servers} credentialsOnly credential={credential === 'new' ? undefined : credential} close={() => setCredential(null)} created={() => void load().catch(error => setError(message(error)))} />}
  </section></div>;
}
