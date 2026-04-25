import { useAppStore } from "../../stores/useAppStore";
import {
  Plus, Server, FolderSync, Terminal, FolderOpen, Activity,
  Pencil, Trash2, ChevronRight, ChevronDown, KeyRound, Route,
} from "lucide-react";
import { useState, useMemo } from "react";
import type { Server as ServerType, Tab } from "../../types";

export default function Sidebar() {
  const {
    servers, credentialGroups, sidebarCollapsed,
    openDialog, deleteServer, addTab, openCgDialog, deleteCg,
    moveServerToGroup,
  } = useAppStore();

  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set());
  const [showCredGroups, setShowCredGroups] = useState(false);
  const [contextMenu, setContextMenu] = useState<{
    server: ServerType; x: number; y: number;
  } | null>(null);
  const [dragOverGroup, setDragOverGroup] = useState<string | null>(null);

  const DEFAULT_GROUP = "默认";

  const groups = useMemo(() => {
    const map = new Map<string, ServerType[]>();
    for (const s of servers) {
      const g = s.group_name || DEFAULT_GROUP;
      if (!map.has(g)) map.set(g, []);
      map.get(g)!.push(s);
    }
    return map;
  }, [servers]);

  const toggleGroup = (name: string) => {
    setExpandedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name); else next.add(name);
      return next;
    });
  };

  const openTab = (server: ServerType, type: Tab["type"]) => {
    const id = `${type}-${server.id}-${Date.now()}`;
    const titles: Record<string, string> = {
      terminal: `SSH: ${server.name}`,
      sftp: `SFTP: ${server.name}`,
      monitor: `Monitor: ${server.name}`,
    };
    addTab({ id, type, serverId: server.id, serverName: server.name, title: titles[type] });
  };

  const getCgName = (server: ServerType) => {
    if (!server.credential_group_id) return null;
    return credentialGroups.find((g) => g.id === server.credential_group_id)?.name ?? null;
  };

  const handleDragStart = (e: React.DragEvent, server: ServerType) => {
    e.dataTransfer.setData("text/plain", server.id);
    e.dataTransfer.effectAllowed = "move";
  };

  const handleDrop = async (e: React.DragEvent, targetGroup: string) => {
    e.preventDefault();
    setDragOverGroup(null);
    const serverId = e.dataTransfer.getData("text/plain");
    if (!serverId) return;
    const groupName = targetGroup === DEFAULT_GROUP ? "" : targetGroup;
    await moveServerToGroup(serverId, groupName);
  };

  if (sidebarCollapsed) {
    return (
      <div className="flex flex-col items-center py-2 gap-2">
        <button onClick={() => openDialog()} className="p-2 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-blue" title="添加服务器">
          <Plus size={18} />
        </button>
        {servers.map((s) => (
          <button key={s.id} onClick={() => openTab(s, "terminal")} className="p-2 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-green" title={s.name}>
            <Server size={16} />
          </button>
        ))}
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full" onClick={() => setContextMenu(null)}>
      <div className="flex-1 overflow-y-auto">
        <div className="p-2">
          <button onClick={() => openDialog()} className="w-full flex items-center gap-2 px-3 py-2 rounded text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-blue">
            <Plus size={14} /> 添加服务器
          </button>
        </div>

        {servers.length === 0 && (
          <div className="px-4 py-8 text-center text-text-muted text-xs">暂无服务器</div>
        )}

        {Array.from(groups.entries()).map(([group, srvs]) => {
          const expanded = expandedGroups.has(group) || group === DEFAULT_GROUP;
          const isDragOver = dragOverGroup === group;
          return (
            <div key={group}
              onDragOver={(e) => { e.preventDefault(); e.dataTransfer.dropEffect = "move"; setDragOverGroup(group); }}
              onDragLeave={() => setDragOverGroup(null)}
              onDrop={(e) => handleDrop(e, group)}
              className={isDragOver ? "bg-accent-blue/5 rounded" : ""}
            >
              {group !== DEFAULT_GROUP ? (
                <div className={`flex items-center ${isDragOver ? "bg-accent-blue/10 rounded-t" : ""}`}>
                  <button onClick={() => toggleGroup(group)} className="flex-1 flex items-center gap-1 px-3 py-1.5 text-xs text-text-muted hover:text-text-secondary">
                    {expanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
                    {group}
                    <span className="ml-auto">{srvs.length}</span>
                  </button>
                  <button onClick={() => openDialog(undefined, { group_name: group })} className="p-1 mr-2 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-blue" title={`在「${group}」分组添加服务器`}>
                    <Plus size={12} />
                  </button>
                </div>
              ) : (
                <div className={`flex items-center px-3 py-1.5 text-xs text-text-muted ${isDragOver ? "bg-accent-blue/10 rounded-t" : ""}`}>
                  <span className="flex items-center gap-1">
                    {expanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
                    {DEFAULT_GROUP}
                    <span className="ml-auto">{srvs.length}</span>
                  </span>
                </div>
              )}
              {expanded && srvs.map((server) => {
                const cgName = getCgName(server);
                return (
                  <div key={server.id}
                    draggable
                    onDragStart={(e) => handleDragStart(e, server)}
                    className={`flex items-center gap-2 px-3 py-1.5 mx-1 rounded text-sm cursor-pointer hover:bg-bg-tertiary group ${isDragOver ? "bg-accent-blue/5" : ""}`}
                    onDoubleClick={() => openTab(server, "terminal")}
                    onContextMenu={(e) => { e.preventDefault(); setContextMenu({ server, x: e.clientX, y: e.clientY }); }}
                  >
                    <div className="flex items-center gap-1">
                      <FolderSync size={14} className="text-accent-green flex-shrink-0" />
                      {server.jump_server_id && <Route size={10} className="text-accent-cyan flex-shrink-0" />}
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="truncate text-text-secondary">{server.name}</div>
                      <div className="text-xs text-text-muted truncate">
                        {cgName ? (
                          <span className="text-accent-purple">{cgName}</span>
                        ) : (
                          <span>{server.username}@{server.host}:{server.port}</span>
                        )}
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          );
        })}
      </div>

      <div className="border-t border-border">
        <button onClick={() => setShowCredGroups(!showCredGroups)}
          className="w-full flex items-center gap-1.5 px-3 py-2 text-xs text-text-muted hover:text-text-secondary">
          {showCredGroups ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
          <KeyRound size={12} /> 凭据分组
          <span className="ml-auto">{credentialGroups.length}</span>
        </button>
        {showCredGroups && (
          <div className="pb-2">
            {credentialGroups.map((cg) => (
              <div key={cg.id} className="flex items-center gap-2 px-3 py-1 mx-1 rounded text-xs hover:bg-bg-tertiary group">
                <KeyRound size={12} className="text-accent-purple flex-shrink-0" />
                <span className="truncate flex-1 text-text-secondary">{cg.name}</span>
                <span className="text-text-muted opacity-0 group-hover:opacity-100">
                  <button onClick={() => openCgDialog(cg)} className="p-0.5 hover:text-accent-yellow"><Pencil size={11} /></button>
                  <button onClick={() => deleteCg(cg.id)} className="p-0.5 hover:text-accent-red ml-1"><Trash2 size={11} /></button>
                </span>
              </div>
            ))}
            <button onClick={() => openCgDialog()} className="w-full flex items-center gap-1.5 px-3 py-1.5 text-xs text-text-muted hover:text-accent-blue">
              <Plus size={11} /> 新建凭据分组
            </button>
          </div>
        )}
      </div>

      {contextMenu && (
        <div className="fixed bg-bg-secondary border border-border rounded-lg shadow-xl py-1 z-50 min-w-[160px]"
          style={{ left: contextMenu.x, top: contextMenu.y }}>
          <button className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-blue"
            onClick={() => { openTab(contextMenu.server, "terminal"); setContextMenu(null); }}>
            <Terminal size={14} /> SSH 终端
          </button>
          <button className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-blue"
            onClick={() => { openTab(contextMenu.server, "sftp"); setContextMenu(null); }}>
            <FolderOpen size={14} /> SFTP 文件管理
          </button>
          <button className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-blue"
            onClick={() => { openTab(contextMenu.server, "monitor"); setContextMenu(null); }}>
            <Activity size={14} /> 资源监控
          </button>
          <div className="border-t border-border my-1" />
          <button className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-yellow"
            onClick={() => { openDialog(contextMenu.server); setContextMenu(null); }}>
            <Pencil size={14} /> 编辑
          </button>
          <button className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-red"
            onClick={() => { deleteServer(contextMenu.server.id); setContextMenu(null); }}>
            <Trash2 size={14} /> 删除
          </button>
        </div>
      )}
    </div>
  );
}
