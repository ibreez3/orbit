import { useAppStore } from "../../stores/useAppStore";
import {
  Plus,
  Server,
  FolderSync,
  Terminal,
  FolderOpen,
  Activity,
  Pencil,
  Trash2,
  ChevronRight,
  ChevronDown,
} from "lucide-react";
import { useState, useMemo } from "react";
import type { Server as ServerType, Tab } from "../../types";

export default function Sidebar() {
  const {
    servers,
    sidebarCollapsed,
    openDialog,
    deleteServer,
    addTab,
  } = useAppStore();
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(
    new Set()
  );
  const [contextMenu, setContextMenu] = useState<{
    server: ServerType;
    x: number;
    y: number;
  } | null>(null);

  const groups = useMemo(() => {
    const map = new Map<string, ServerType[]>();
    for (const s of servers) {
      const g = s.group_name || "默认";
      if (!map.has(g)) map.set(g, []);
      map.get(g)!.push(s);
    }
    return map;
  }, [servers]);

  const toggleGroup = (name: string) => {
    setExpandedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  };

  const handleDoubleClick = (server: ServerType, type: Tab["type"]) => {
    const id = `${type}-${server.id}-${Date.now()}`;
    const titles: Record<string, string> = {
      terminal: `SSH: ${server.name}`,
      sftp: `SFTP: ${server.name}`,
      monitor: `Monitor: ${server.name}`,
    };
    addTab({
      id,
      type,
      serverId: server.id,
      serverName: server.name,
      title: titles[type],
    });
  };

  const handleContextMenu = (e: React.MouseEvent, server: ServerType) => {
    e.preventDefault();
    setContextMenu({ server, x: e.clientX, y: e.clientY });
  };

  if (sidebarCollapsed) {
    return (
      <div className="flex flex-col items-center py-2 gap-2">
        <button
          onClick={() => openDialog()}
          className="p-2 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-blue transition-colors"
          title="添加服务器"
        >
          <Plus size={18} />
        </button>
        {servers.map((s) => (
          <button
            key={s.id}
            onClick={() => handleDoubleClick(s, "terminal")}
            className="p-2 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-green transition-colors"
            title={s.name}
          >
            <Server size={16} />
          </button>
        ))}
      </div>
    );
  }

  return (
    <div className="flex-1 overflow-y-auto" onClick={() => setContextMenu(null)}>
      <div className="p-2">
        <button
          onClick={() => openDialog()}
          className="w-full flex items-center gap-2 px-3 py-2 rounded text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-blue transition-colors"
        >
          <Plus size={14} />
          添加服务器
        </button>
      </div>

      {servers.length === 0 && (
        <div className="px-4 py-8 text-center text-text-muted text-xs">
          暂无服务器，点击上方按钮添加
        </div>
      )}

      {Array.from(groups.entries()).map(([group, srvs]) => {
        const expanded = expandedGroups.has(group) || group === "默认";
        return (
          <div key={group}>
            {group !== "默认" && (
              <button
                onClick={() => toggleGroup(group)}
                className="w-full flex items-center gap-1 px-3 py-1.5 text-xs text-text-muted hover:text-text-secondary transition-colors"
              >
                {expanded ? (
                  <ChevronDown size={12} />
                ) : (
                  <ChevronRight size={12} />
                )}
                {group}
                <span className="ml-auto text-text-muted">
                  {srvs.length}
                </span>
              </button>
            )}
            {expanded &&
              srvs.map((server) => (
                <div
                  key={server.id}
                  className="flex items-center gap-2 px-3 py-1.5 mx-1 rounded text-sm cursor-pointer hover:bg-bg-tertiary group transition-colors"
                  onDoubleClick={() => handleDoubleClick(server, "terminal")}
                  onContextMenu={(e) => handleContextMenu(e, server)}
                >
                  <FolderSync
                    size={14}
                    className="text-accent-green flex-shrink-0"
                  />
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-text-secondary">
                      {server.name}
                    </div>
                    <div className="text-xs text-text-muted truncate">
                      {server.username}@{server.host}:{server.port}
                    </div>
                  </div>
                </div>
              ))}
          </div>
        );
      })}

      {contextMenu && (
        <div
          className="fixed bg-bg-secondary border border-border rounded-lg shadow-xl py-1 z-50 min-w-[160px]"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <button
            className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-blue transition-colors"
            onClick={() => {
              handleDoubleClick(contextMenu.server, "terminal");
              setContextMenu(null);
            }}
          >
            <Terminal size={14} />
            SSH 终端
          </button>
          <button
            className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-blue transition-colors"
            onClick={() => {
              handleDoubleClick(contextMenu.server, "sftp");
              setContextMenu(null);
            }}
          >
            <FolderOpen size={14} />
            SFTP 文件管理
          </button>
          <button
            className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-blue transition-colors"
            onClick={() => {
              handleDoubleClick(contextMenu.server, "monitor");
              setContextMenu(null);
            }}
          >
            <Activity size={14} />
            资源监控
          </button>
          <div className="border-t border-border my-1" />
          <button
            className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-yellow transition-colors"
            onClick={() => {
              openDialog(contextMenu.server);
              setContextMenu(null);
            }}
          >
            <Pencil size={14} />
            编辑
          </button>
          <button
            className="w-full flex items-center gap-2 px-3 py-2 text-sm text-text-secondary hover:bg-bg-tertiary hover:text-accent-red transition-colors"
            onClick={() => {
              deleteServer(contextMenu.server.id);
              setContextMenu(null);
            }}
          >
            <Trash2 size={14} />
            删除
          </button>
        </div>
      )}
    </div>
  );
}
