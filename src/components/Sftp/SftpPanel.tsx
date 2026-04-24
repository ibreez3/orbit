import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  FolderOpen,
  File,
  RefreshCw,
  FolderPlus,
  Trash2,
  Download,
  Upload,
  Home,
  ChevronRight,
  ArrowLeft,
} from "lucide-react";
import type { Tab, FileEntry } from "../../types";

interface Props {
  tab: Tab;
}

export default function SftpPanel({ tab }: Props) {
  const [path, setPath] = useState("");
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [selectedEntry, setSelectedEntry] = useState<FileEntry | null>(null);
  const [pathHistory, setPathHistory] = useState<string[]>([]);

  const loadDir = useCallback(
    async (dirPath: string) => {
      setLoading(true);
      try {
        const result = await invoke<FileEntry[]>("sftp_list", {
          serverId: tab.serverId,
          path: dirPath,
        });
        setEntries(result);
        setPath(dirPath);
        setSelectedEntry(null);
      } catch (e) {
        console.error("加载目录失败:", e);
      } finally {
        setLoading(false);
      }
    },
    [tab.serverId]
  );

  useEffect(() => {
    invoke<string>("get_server_home", { serverId: tab.serverId })
      .then((home) => {
        setPath(home);
        setPathHistory([home]);
        loadDir(home);
      })
      .catch(() => {
        setPath("/");
        setPathHistory(["/"]);
        loadDir("/");
      });
  }, []);

  const navigateTo = (newPath: string) => {
    setPathHistory((prev) => [...prev, newPath]);
    loadDir(newPath);
  };

  const goBack = () => {
    if (pathHistory.length > 1) {
      const prev = [...pathHistory];
      prev.pop();
      const lastPath = prev[prev.length - 1];
      setPathHistory(prev);
      loadDir(lastPath);
    }
  };

  const handleDoubleClick = (entry: FileEntry) => {
    if (entry.is_dir) {
      navigateTo(entry.path);
    }
  };

  const handleDownload = async () => {
    if (!selectedEntry || selectedEntry.is_dir) return;
    try {
      await invoke("sftp_download", {
        serverId: tab.serverId,
        remotePath: selectedEntry.path,
        localPath: `~/Downloads/${selectedEntry.name}`,
      });
    } catch (e) {
      console.error("下载失败:", e);
    }
  };

  const handleDelete = async () => {
    if (!selectedEntry) return;
    try {
      await invoke("sftp_remove", {
        serverId: tab.serverId,
        path: selectedEntry.path,
        isDir: selectedEntry.is_dir,
      });
      loadDir(path);
    } catch (e) {
      console.error("删除失败:", e);
    }
  };

  const formatSize = (bytes: number) => {
    if (bytes === 0) return "-";
    const units = ["B", "KB", "MB", "GB"];
    let i = 0;
    let size = bytes;
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return `${size.toFixed(1)} ${units[i]}`;
  };

  return (
    <div className="flex flex-col h-full bg-bg-primary">
      <div className="flex items-center gap-2 px-3 py-2 border-b border-border bg-bg-secondary">
        <button
          onClick={goBack}
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-text-primary"
        >
          <ArrowLeft size={14} />
        </button>
        <button
          onClick={() => loadDir(path)}
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-text-primary"
        >
          <RefreshCw size={14} />
        </button>
        <button
          onClick={() => navigateTo("/")}
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-text-primary"
        >
          <Home size={14} />
        </button>
        <div className="flex items-center flex-1 bg-bg-primary rounded px-2 py-1 text-sm">
          {path.split("/").map(
            (segment, i, arr) =>
              segment && (
                <span key={i} className="flex items-center">
                  <button
                    onClick={() =>
                      navigateTo("/" + arr.slice(1, i + 1).join("/"))
                    }
                    className="text-text-secondary hover:text-accent-blue"
                  >
                    {segment}
                  </button>
                  {i < arr.length - 1 && (
                    <ChevronRight
                      size={12}
                      className="mx-1 text-text-muted"
                    />
                  )}
                </span>
              )
          )}
        </div>
        <button
          onClick={handleDownload}
          disabled={!selectedEntry || selectedEntry.is_dir}
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-green disabled:opacity-30"
          title="下载"
        >
          <Download size={14} />
        </button>
        <button
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-blue"
          title="上传"
        >
          <Upload size={14} />
        </button>
        <button
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-yellow"
          title="新建文件夹"
        >
          <FolderPlus size={14} />
        </button>
        <button
          onClick={handleDelete}
          disabled={!selectedEntry}
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-red disabled:opacity-30"
          title="删除"
        >
          <Trash2 size={14} />
        </button>
      </div>

      <div className="flex-1 overflow-y-auto">
        {loading ? (
          <div className="flex items-center justify-center h-full text-text-muted text-sm">
            加载中...
          </div>
        ) : (
          <table className="w-full text-sm">
            <thead>
              <tr className="text-text-muted text-xs border-b border-border sticky top-0 bg-bg-primary">
                <th className="text-left px-3 py-2 font-normal">名称</th>
                <th className="text-right px-3 py-2 font-normal w-24">
                  大小
                </th>
                <th className="text-right px-3 py-2 font-normal w-44">
                  修改时间
                </th>
                <th className="text-right px-3 py-2 font-normal w-20">
                  权限
                </th>
              </tr>
            </thead>
            <tbody>
              {entries.map((entry) => (
                <tr
                  key={entry.path}
                  className={`border-b border-border/30 cursor-pointer transition-colors ${
                    selectedEntry?.path === entry.path
                      ? "bg-accent-blue/10 text-accent-blue"
                      : "text-text-secondary hover:bg-bg-tertiary/50"
                  }`}
                  onClick={() => setSelectedEntry(entry)}
                  onDoubleClick={() => handleDoubleClick(entry)}
                >
                  <td className="px-3 py-1.5 flex items-center gap-2">
                    {entry.is_dir ? (
                      <FolderOpen
                        size={14}
                        className="text-accent-yellow flex-shrink-0"
                      />
                    ) : (
                      <File
                        size={14}
                        className="text-text-muted flex-shrink-0"
                      />
                    )}
                    <span className="truncate">{entry.name}</span>
                  </td>
                  <td className="text-right px-3 py-1.5 text-text-muted">
                    {entry.is_dir ? "-" : formatSize(entry.size)}
                  </td>
                  <td className="text-right px-3 py-1.5 text-text-muted">
                    {entry.modified}
                  </td>
                  <td className="text-right px-3 py-1.5 text-text-muted">
                    {entry.permissions}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="px-3 py-1.5 border-t border-border bg-bg-secondary text-xs text-text-muted flex items-center gap-4">
        <span>{entries.length} 项</span>
        {selectedEntry && <span>已选: {selectedEntry.name}</span>}
      </div>
    </div>
  );
}
