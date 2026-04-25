import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { open, save } from "@tauri-apps/plugin-dialog";
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

interface TransferProgress {
  transferred: number;
  total: number;
}

function formatSize(bytes: number) {
  if (bytes === 0) return "-";
  const units = ["B", "KB", "MB", "GB"];
  let i = 0;
  let size = bytes;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return `${size.toFixed(1)} ${units[i]}`;
}

export default function SftpPanel({ tab }: Props) {
  const [path, setPath] = useState("");
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [selectedEntry, setSelectedEntry] = useState<FileEntry | null>(null);
  const [pathHistory, setPathHistory] = useState<string[]>([]);
  const [transfer, setTransfer] = useState<{
    direction: "upload" | "download";
    fileName: string;
    transferred: number;
    total: number;
  } | null>(null);

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
  }, [tab.serverId, loadDir]);

  useEffect(() => {
    let dlUnlisten: UnlistenFn | undefined;
    let ulUnlisten: UnlistenFn | undefined;

    const dlEvent = `sftp-download-${tab.serverId}`;
    const ulEvent = `sftp-upload-${tab.serverId}`;

    listen<TransferProgress>(dlEvent, (e) => {
      setTransfer((prev) => {
        const transferred = e.payload.transferred;
        const total = e.payload.total;
        if (transferred >= total) return null;
        if (prev?.direction === "download") {
          return { ...prev, transferred, total };
        }
        return prev;
      });
    }).then((fn) => { dlUnlisten = fn; });

    listen<TransferProgress>(ulEvent, (e) => {
      setTransfer((prev) => {
        const transferred = e.payload.transferred;
        const total = e.payload.total;
        if (transferred >= total) return null;
        if (prev?.direction === "upload") {
          return { ...prev, transferred, total };
        }
        return prev;
      });
    }).then((fn) => { ulUnlisten = fn; });

    return () => {
      dlUnlisten?.();
      ulUnlisten?.();
    };
  }, [tab.serverId]);

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
      const savePath = await save({
        defaultPath: selectedEntry.name,
      });
      if (!savePath) return;
      setTransfer({ direction: "download", fileName: selectedEntry.name, transferred: 0, total: selectedEntry.size });
      await invoke("sftp_download", {
        serverId: tab.serverId,
        remotePath: selectedEntry.path,
        localPath: savePath,
      });
      setTransfer(null);
    } catch (e) {
      setTransfer(null);
      console.error("下载失败:", e);
    }
  };

  const handleUpload = async () => {
    try {
      const selected = await open({
        multiple: false,
      });
      if (!selected) return;
      const fileName = selected.split("/").pop() || selected.split("\\").pop() || "upload";
      const remotePath = path === "/" ? `/${fileName}` : `${path}/${fileName}`;
      setTransfer({ direction: "upload", fileName, transferred: 0, total: 0 });
      await invoke("sftp_upload", {
        serverId: tab.serverId,
        localPath: selected,
        remotePath,
      });
      setTransfer(null);
      loadDir(path);
    } catch (e) {
      setTransfer(null);
      console.error("上传失败:", e);
    }
  };

  const handleMkdir = async () => {
    const name = prompt("文件夹名称:");
    if (!name) return;
    try {
      const dirPath = path === "/" ? `/${name}` : `${path}/${name}`;
      await invoke("sftp_mkdir", {
        serverId: tab.serverId,
        path: dirPath,
      });
      loadDir(path);
    } catch (e) {
      console.error("创建文件夹失败:", e);
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

  const transferPercent = transfer && transfer.total > 0
    ? Math.round((transfer.transferred / transfer.total) * 100)
    : 0;

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
          disabled={!selectedEntry || selectedEntry.is_dir || !!transfer}
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-green disabled:opacity-30"
          title="下载"
        >
          <Download size={14} />
        </button>
        <button
          onClick={handleUpload}
          disabled={!!transfer}
          className="p-1.5 rounded hover:bg-bg-tertiary text-text-muted hover:text-accent-blue disabled:opacity-30"
          title="上传"
        >
          <Upload size={14} />
        </button>
        <button
          onClick={handleMkdir}
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

      {transfer && (
        <div className="px-3 py-1.5 border-t border-border bg-bg-secondary">
          <div className="flex items-center justify-between text-xs text-text-muted mb-1">
            <span>
              {transfer.direction === "download" ? "下载" : "上传"}: {transfer.fileName}
            </span>
            <span>
              {formatSize(transfer.transferred)} / {transfer.total > 0 ? formatSize(transfer.total) : "..."}
              {transfer.total > 0 && ` (${transferPercent}%)`}
            </span>
          </div>
          <div className="w-full h-1.5 bg-bg-primary rounded-full overflow-hidden">
            <div
              className="h-full bg-accent-blue rounded-full transition-all duration-150"
              style={{ width: `${transferPercent}%` }}
            />
          </div>
        </div>
      )}

      <div className="px-3 py-1.5 border-t border-border bg-bg-secondary text-xs text-text-muted flex items-center gap-4">
        <span>{entries.length} 项</span>
        {selectedEntry && <span>已选: {selectedEntry.name}</span>}
      </div>
    </div>
  );
}
