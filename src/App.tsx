import { useEffect, useState, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { ask } from "@tauri-apps/plugin-dialog";
import { useAppStore } from "./stores/useAppStore";
import Sidebar from "./components/Sidebar/Sidebar";
import TerminalTab from "./components/Terminal/TerminalTab";
import SftpPanel from "./components/Sftp/SftpPanel";
import MonitorPanel from "./components/Monitor/MonitorPanel";
import ServerDialog from "./components/ServerDialog/ServerDialog";
import CredentialGroupDialog from "./components/CredentialGroupDialog/CredentialGroupDialog";
import {
  Server,
  Terminal,
  FolderOpen,
  Activity,
  X,
  PanelLeftClose,
  PanelLeft,
  ArrowDown,
  ArrowUp,
  Columns2,
  Rows2,
  SplitSquareVertical,
} from "lucide-react";
import type { Tab } from "./types";

const TAB_ICONS: Record<string, React.ReactNode> = {
  terminal: <Terminal size={14} />,
  sftp: <FolderOpen size={14} />,
  monitor: <Activity size={14} />,
};

function formatSpeed(bytesPerSec: number): string {
  if (bytesPerSec < 1024) return `${bytesPerSec} B/s`;
  if (bytesPerSec < 1024 * 1024) return `${(bytesPerSec / 1024).toFixed(1)} KB/s`;
  return `${(bytesPerSec / 1024 / 1024).toFixed(1)} MB/s`;
}

function TrafficDisplay({ sessionId }: { sessionId: string }) {
  const [speed, setSpeed] = useState({ down: 0, up: 0 });
  const prevRef = useRef({ read: 0, written: 0, time: Date.now() });

  useEffect(() => {
    const timer = setInterval(async () => {
      try {
        const stats = await invoke<{ bytes_read: number; bytes_written: number }>("get_ssh_traffic", { sessionId });
        const now = Date.now();
        const dt = (now - prevRef.current.time) / 1000;
        if (dt > 0) {
          setSpeed({
            down: Math.max(0, Math.round((stats.bytes_read - prevRef.current.read) / dt)),
            up: Math.max(0, Math.round((stats.bytes_written - prevRef.current.written) / dt)),
          });
        }
        prevRef.current = { read: stats.bytes_read, written: stats.bytes_written, time: now };
      } catch {}
    }, 1500);
    return () => clearInterval(timer);
  }, [sessionId]);

  return (
    <span className="flex items-center gap-2 ml-auto">
      <span className="flex items-center gap-0.5 text-accent-cyan">
        <ArrowDown size={11} /> {formatSpeed(speed.down)}
      </span>
      <span className="flex items-center gap-0.5 text-accent-yellow">
        <ArrowUp size={11} /> {formatSpeed(speed.up)}
      </span>
    </span>
  );
}

function TabContextMenu() {
  const { contextMenu, splitPane, hideContextMenu } = useAppStore();
  if (!contextMenu) return null;

  return (
    <>
      <div className="fixed inset-0 z-40" onClick={hideContextMenu} onContextMenu={(e) => { e.preventDefault(); hideContextMenu(); }} />
      <div
        className="fixed z-50 bg-bg-secondary border border-border rounded shadow-lg py-1 min-w-[160px]"
        style={{ left: contextMenu.x, top: contextMenu.y }}
      >
        <button
          className="w-full px-3 py-1.5 text-xs text-text-secondary hover:bg-bg-tertiary hover:text-text-primary flex items-center gap-2 text-left"
          onClick={() => { splitPane(contextMenu.tabId, "horizontal"); hideContextMenu(); }}
        >
          <Columns2 size={13} /> 左右分屏
        </button>
        <button
          className="w-full px-3 py-1.5 text-xs text-text-secondary hover:bg-bg-tertiary hover:text-text-primary flex items-center gap-2 text-left"
          onClick={() => { splitPane(contextMenu.tabId, "vertical"); hideContextMenu(); }}
        >
          <Rows2 size={13} /> 上下分屏
        </button>
      </div>
    </>
  );
}

function PaneContent({ tab }: { tab: Tab }) {
  if (tab.type === "terminal") return <TerminalTab tab={tab} />;
  if (tab.type === "sftp") return <SftpPanel tab={tab} />;
  return <MonitorPanel tab={tab} />;
}

export default function App() {
  const {
    tabs,
    activeTabId,
    sidebarCollapsed,
    dialogOpen,
    cgDialogOpen,
    panes,
    loadServers,
    loadCredentialGroups,
    setActiveTab,
    removeTab,
    toggleSidebar,
    showContextMenu,
    closePane,
  } = useAppStore();

  useEffect(() => {
    loadServers();
    loadCredentialGroups();
  }, []);

  useEffect(() => {
    const handler = () => useAppStore.getState().hideContextMenu();
    window.addEventListener("scroll", handler, true);
    return () => window.removeEventListener("scroll", handler, true);
  }, []);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (!mod) return;
      const state = useAppStore.getState();
      if (!state.activeTabId) return;
      const tab = state.tabs.find((t) => t.id === state.activeTabId);
      if (!tab) return;
      const paneExists = state.panes.some((p) => p.tabId === tab.id);
      switch (e.key.toLowerCase()) {
        case "l":
        case "r":
          e.preventDefault();
          if (!paneExists) state.splitPane(tab.id, "horizontal");
          break;
        case "u":
        case "d":
          e.preventDefault();
          if (!paneExists) state.splitPane(tab.id, "vertical");
          break;
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  const handleCloseTab = async (tab: Tab) => {
    try {
      if (tab.type === "terminal" && tab.sessionId) {
        const confirmed = await ask(`确定关闭终端 "${tab.title}" 吗？\n连接将被断开。`, {
          title: "关闭确认",
          kind: "warning",
        });
        if (!confirmed) return;
      }
      removeTab(tab.id);
    } catch (e) {
      console.error("关闭 Tab 失败:", e);
      removeTab(tab.id);
    }
  };

  const activeTab = tabs.find((t) => t.id === activeTabId);
  const splitDirection = panes.length > 0 ? panes[panes.length - 1].direction : null;

  const renderContent = () => {
    if (panes.length === 0) {
      return (
        <div className="flex-1 relative">
          {tabs.map((tab) => (
            <div
              key={tab.id}
              className={`absolute inset-0 ${
                tab.id === activeTabId ? "block" : "hidden"
              }`}
            >
              {tab.type === "terminal" ? (
                tab.id === activeTabId && <TerminalTab tab={tab} />
              ) : tab.type === "sftp" ? (
                <SftpPanel tab={tab} />
              ) : (
                <MonitorPanel tab={tab} />
              )}
            </div>
          ))}
          {tabs.length === 0 && (
            <div className="flex items-center justify-center h-full text-text-muted">
              <div className="text-center">
                <Terminal size={48} className="mx-auto mb-4 opacity-30" />
                <p className="text-lg">Orbit</p>
                <p className="text-sm mt-1">
                  轻量 SSH 管理终端 · 从左侧添加服务器
                </p>
              </div>
            </div>
          )}
        </div>
      );
    }

    const mainTab = activeTab;
    if (!mainTab) return null;

    return (
      <div className={`flex-1 flex ${splitDirection === "vertical" ? "flex-col" : "flex-row"} min-h-0`}>
        <div className="flex-1 min-h-0 min-w-0 relative">
          <PaneContent tab={mainTab} />
        </div>
        {panes.map((pane) => {
          const paneTab = tabs.find((t) => t.id === pane.tabId);
          return (
            <div key={pane.id} className="flex-1 min-h-0 min-w-0 flex flex-col">
              <div className="flex items-center justify-between px-2 py-0.5 bg-bg-secondary border-t border-border text-xs text-text-muted">
                <span className="truncate">{paneTab?.title ?? "未分配"}</span>
                <button
                  className="p-0.5 rounded hover:bg-bg-tertiary hover:text-accent-red"
                  onClick={() => closePane(pane.id)}
                >
                  <X size={11} />
                </button>
              </div>
              <div className="flex-1 min-h-0 relative">
                {paneTab && <PaneContent tab={paneTab} />}
              </div>
            </div>
          );
        })}
      </div>
    );
  };

  return (
    <div className="flex h-full">
      {dialogOpen && <ServerDialog />}
      {cgDialogOpen && <CredentialGroupDialog />}
      <TabContextMenu />

      <div
        className={`flex flex-col border-r border-border ${
          sidebarCollapsed ? "w-12" : "w-64"
        } transition-all duration-200 bg-bg-secondary flex-shrink-0`}
      >
        <div className="flex items-center justify-between px-3 py-2 border-b border-border">
          {!sidebarCollapsed && (
            <div className="flex items-center gap-2 text-accent-blue">
              <Server size={16} />
              <span className="font-semibold text-sm">Orbit</span>
            </div>
          )}
          <button
            onClick={toggleSidebar}
            className="p-1 rounded hover:bg-bg-tertiary text-text-muted hover:text-text-primary transition-colors"
          >
            {sidebarCollapsed ? (
              <PanelLeft size={16} />
            ) : (
              <PanelLeftClose size={16} />
            )}
          </button>
        </div>
        <Sidebar />
      </div>

      <div className="flex flex-col flex-1 min-w-0">
        {tabs.length > 0 && (
          <div className="flex items-center bg-bg-secondary border-b border-border overflow-x-auto">
            {tabs.map((tab) => (
              <div
                key={tab.id}
                className={`flex items-center gap-1.5 px-3 py-1.5 text-xs cursor-pointer border-r border-border group whitespace-nowrap ${
                  tab.id === activeTabId
                    ? "bg-bg-primary text-text-primary border-b-2 border-b-accent-blue"
                    : "text-text-muted hover:text-text-secondary"
                }`}
                onClick={() => setActiveTab(tab.id)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  showContextMenu(tab.id, e.clientX, e.clientY);
                }}
              >
                {TAB_ICONS[tab.type]}
                <span>{tab.title}</span>
                <button
                  className="ml-1 p-0.5 rounded opacity-0 group-hover:opacity-100 hover:bg-bg-tertiary transition-all"
                  onClick={(e) => {
                    e.stopPropagation();
                    handleCloseTab(tab);
                  }}
                >
                  <X size={12} />
                </button>
              </div>
            ))}
          </div>
        )}

        {renderContent()}

        <div className="flex items-center px-3 py-1 border-t border-border bg-bg-secondary text-text-muted text-xs">
          <span>
            {activeTab
              ? `${activeTab.serverName} (${activeTab.type})`
              : "就绪"}
          </span>
          {activeTab?.type === "terminal" && activeTab.sessionId && (
            <TrafficDisplay sessionId={activeTab.sessionId} />
          )}
          {panes.length > 0 && (
            <span className="ml-2 text-accent-cyan">
              <SplitSquareVertical size={11} className="inline mr-1" />
              分屏 x{panes.length + 1}
            </span>
          )}
        </div>
      </div>
    </div>
  );
}
