import { useEffect } from "react";
import { useAppStore } from "./stores/useAppStore";
import Sidebar from "./components/Sidebar/Sidebar";
import TerminalTab from "./components/Terminal/TerminalTab";
import SftpPanel from "./components/Sftp/SftpPanel";
import MonitorPanel from "./components/Monitor/MonitorPanel";
import ServerDialog from "./components/ServerDialog/ServerDialog";
import {
  Server,
  Terminal,
  FolderOpen,
  Activity,
  X,
  PanelLeftClose,
  PanelLeft,
} from "lucide-react";

const TAB_ICONS: Record<string, React.ReactNode> = {
  terminal: <Terminal size={14} />,
  sftp: <FolderOpen size={14} />,
  monitor: <Activity size={14} />,
};

export default function App() {
  const {
    tabs,
    activeTabId,
    sidebarCollapsed,
    dialogOpen,
    loadServers,
    setActiveTab,
    removeTab,
    toggleSidebar,
  } = useAppStore();

  useEffect(() => {
    loadServers();
  }, []);

  const activeTab = tabs.find((t) => t.id === activeTabId);

  return (
    <div className="flex h-full">
      {dialogOpen && <ServerDialog />}

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
              >
                {TAB_ICONS[tab.type]}
                <span>{tab.title}</span>
                <button
                  className="ml-1 p-0.5 rounded opacity-0 group-hover:opacity-100 hover:bg-bg-tertiary transition-all"
                  onClick={(e) => {
                    e.stopPropagation();
                    removeTab(tab.id);
                  }}
                >
                  <X size={12} />
                </button>
              </div>
            ))}
          </div>
        )}

        <div className="flex-1 relative">
          {tabs.map((tab) => (
            <div
              key={tab.id}
              className={`absolute inset-0 ${
                tab.id === activeTabId ? "block" : "hidden"
              }`}
            >
              {tab.type === "terminal" && (
                <TerminalTab tab={tab} />
              )}
              {tab.type === "sftp" && (
                <SftpPanel tab={tab} />
              )}
              {tab.type === "monitor" && (
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

        <div className="flex items-center px-3 py-1 border-t border-border bg-bg-secondary text-text-muted text-xs">
          <span>
            {activeTab
              ? `${activeTab.serverName} (${activeTab.type})`
              : "就绪"}
          </span>
        </div>
      </div>
    </div>
  );
}
