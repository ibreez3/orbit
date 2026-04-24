import { useState, useMemo } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open as dialogOpen } from "@tauri-apps/plugin-dialog";
import { useAppStore } from "../../stores/useAppStore";
import { X, Eye, EyeOff, Plug, Loader2, FileKey, ClipboardPaste } from "lucide-react";
import type { ServerInput } from "../../types";

export default function ServerDialog() {
  const { editingServer, credentialGroups, dialogDefaults, closeDialog, addServer, updateServer, deleteServer } = useAppStore();

  const [form, setForm] = useState<ServerInput>({
    name: editingServer?.name ?? "",
    host: editingServer?.host ?? "",
    port: editingServer?.port ?? 22,
    group_name: editingServer?.group_name ?? dialogDefaults?.group_name ?? "",
    auth_type: editingServer?.auth_type ?? "password",
    username: editingServer?.username ?? "",
    password: editingServer?.password ?? "",
    private_key: editingServer?.private_key ?? "",
    key_source: editingServer?.key_source ?? "content",
    key_file_path: editingServer?.key_file_path ?? "",
    key_passphrase: editingServer?.key_passphrase ?? "",
    credential_group_id: editingServer?.credential_group_id ?? "",
  });
  const [showPassword, setShowPassword] = useState(false);
  const [showKeyPass, setShowKeyPass] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const useCg = !!form.credential_group_id;
  const selectedCg = credentialGroups.find((g) => g.id === form.credential_group_id);

  const [isCreatingGroup, setIsCreatingGroup] = useState(false);
  const [newGroupName, setNewGroupName] = useState("");

  const existingGroups = useMemo(() => {
    const s = new Set<string>();
    for (const sv of useAppStore.getState().servers) {
      if (sv.group_name) s.add(sv.group_name);
    }
    return Array.from(s).sort();
  }, []);

  const update = (key: keyof ServerInput, value: string | number) => {
    setForm((prev) => ({ ...prev, [key]: value }));
    setTestResult(null);
  };

  const pickKeyFile = async () => {
    const selected = await dialogOpen({
      multiple: false,
      filters: [{ name: "Private Key", extensions: ["pem", "key", "id_rsa", "id_ed25519", "id_ecdsa", ""] }],
    });
    if (selected) {
      update("key_file_path", selected as string);
    }
  };

  const handleTest = async () => {
    setTesting(true);
    setTestResult(null);
    try {
      const ok = await invoke<boolean>("test_connection", { input: form });
      setTestResult(ok ? "success" : "fail");
    } catch (e) {
      setTestResult(`error:${e}`);
    } finally {
      setTesting(false);
    }
  };

  const handleSave = async () => {
    if (!form.name || !form.host) return;
    if (!useCg && !form.username) return;
    setSaving(true);
    try {
      if (editingServer) {
        await updateServer(editingServer.id, form);
      } else {
        await addServer(form);
      }
      closeDialog();
    } catch (e) {
      console.error("保存失败:", e);
    } finally {
      setSaving(false);
    }
  };

  const inputCls = "w-full bg-bg-primary border border-border rounded px-3 py-2 text-sm text-text-primary focus:border-accent-blue";

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={closeDialog}>
      <div className="bg-bg-secondary rounded-xl border border-border shadow-2xl w-[520px] max-h-[90vh] overflow-y-auto" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-5 py-4 border-b border-border">
          <h2 className="text-sm font-semibold text-text-primary">{editingServer ? "编辑服务器" : "添加服务器"}</h2>
          <button onClick={closeDialog} className="p-1 rounded hover:bg-bg-tertiary text-text-muted hover:text-text-primary"><X size={16} /></button>
        </div>

        <div className="px-5 py-4 space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-text-muted mb-1">名称 *</label>
              <input type="text" value={form.name} onChange={(e) => update("name", e.target.value)} className={inputCls} placeholder="My Server" />
            </div>
            <div>
              <label className="block text-xs text-text-muted mb-1">分组</label>
              {isCreatingGroup ? (
                <input
                  type="text"
                  value={newGroupName}
                  onChange={(e) => {
                    setNewGroupName(e.target.value);
                    update("group_name", e.target.value);
                  }}
                  onBlur={() => {
                    if (!newGroupName.trim()) {
                      setIsCreatingGroup(false);
                      update("group_name", "");
                    }
                  }}
                  className={inputCls}
                  placeholder="输入新分组名称"
                  autoFocus
                />
              ) : (
                <select
                  value={form.group_name ?? ""}
                  onChange={(e) => {
                    const v = e.target.value;
                    if (v === "__new__") {
                      setIsCreatingGroup(true);
                      setNewGroupName("");
                      update("group_name", "");
                    } else {
                      update("group_name", v);
                    }
                  }}
                  className={inputCls}
                >
                  <option value="">默认分组</option>
                  {existingGroups.map((g) => (
                    <option key={g} value={g}>{g}</option>
                  ))}
                  <option value="__new__">+ 新建分组</option>
                </select>
              )}
            </div>
          </div>

          <div className="grid grid-cols-3 gap-3">
            <div className="col-span-2">
              <label className="block text-xs text-text-muted mb-1">主机地址 *</label>
              <input type="text" value={form.host} onChange={(e) => update("host", e.target.value)} className={inputCls} placeholder="192.168.1.1" />
            </div>
            <div>
              <label className="block text-xs text-text-muted mb-1">端口</label>
              <input type="number" value={form.port ?? 22} onChange={(e) => update("port", parseInt(e.target.value) || 22)} className={inputCls} />
            </div>
          </div>

          {/* Credential source */}
          <div>
            <label className="block text-xs text-text-muted mb-2">认证来源</label>
            <div className="flex gap-2">
              <button onClick={() => { update("credential_group_id", ""); }}
                className={`flex-1 py-2 rounded text-sm transition-colors ${!useCg ? "bg-accent-blue/20 text-accent-blue border border-accent-blue/50" : "bg-bg-primary text-text-muted border border-border hover:border-text-muted"}`}>
                自定义凭据
              </button>
              <button onClick={() => { if (credentialGroups.length > 0 && !form.credential_group_id) update("credential_group_id", credentialGroups[0].id); }}
                className={`flex-1 py-2 rounded text-sm transition-colors ${useCg ? "bg-accent-purple/20 text-accent-purple border border-accent-purple/50" : "bg-bg-primary text-text-muted border border-border hover:border-text-muted"}`}>
                凭据分组
              </button>
            </div>
          </div>

          {useCg ? (
            <div>
              <label className="block text-xs text-text-muted mb-1">选择凭据分组</label>
              <select value={form.credential_group_id ?? ""} onChange={(e) => update("credential_group_id", e.target.value)} className={inputCls}>
                {credentialGroups.map((g) => (
                  <option key={g.id} value={g.id}>{g.name} ({g.username})</option>
                ))}
              </select>
              {selectedCg && (
                <div className="mt-2 text-xs text-text-muted bg-bg-primary rounded px-3 py-2">
                  {selectedCg.auth_type === "password" ? "密码认证" : "密钥认证"} · {selectedCg.username}
                </div>
              )}
            </div>
          ) : (
            <>
              <div>
                <label className="block text-xs text-text-muted mb-1">用户名 *</label>
                <input type="text" value={form.username} onChange={(e) => update("username", e.target.value)} className={inputCls} placeholder="root" />
              </div>

              <div>
                <label className="block text-xs text-text-muted mb-2">认证方式</label>
                <div className="flex gap-2">
                  <button onClick={() => update("auth_type", "password")}
                    className={`flex-1 py-2 rounded text-sm transition-colors ${form.auth_type === "password" ? "bg-accent-blue/20 text-accent-blue border border-accent-blue/50" : "bg-bg-primary text-text-muted border border-border"}`}>
                    密码认证
                  </button>
                  <button onClick={() => update("auth_type", "key")}
                    className={`flex-1 py-2 rounded text-sm transition-colors ${form.auth_type === "key" ? "bg-accent-blue/20 text-accent-blue border border-accent-blue/50" : "bg-bg-primary text-text-muted border border-border"}`}>
                    密钥认证
                  </button>
                </div>
              </div>

              {form.auth_type === "password" ? (
                <div>
                  <label className="block text-xs text-text-muted mb-1">密码</label>
                  <div className="relative">
                    <input type={showPassword ? "text" : "password"} value={form.password ?? ""} onChange={(e) => update("password", e.target.value)}
                      className={`${inputCls} pr-10`} placeholder="Enter password" />
                    <button type="button" onClick={() => setShowPassword(!showPassword)} className="absolute right-2 top-1/2 -translate-y-1/2 text-text-muted hover:text-text-secondary">
                      {showPassword ? <EyeOff size={14} /> : <Eye size={14} />}
                    </button>
                  </div>
                </div>
              ) : (
                <>
                  <div>
                    <label className="block text-xs text-text-muted mb-2">密钥来源</label>
                    <div className="flex gap-2">
                      <button onClick={() => update("key_source", "content")}
                        className={`flex-1 py-1.5 rounded text-xs transition-colors flex items-center justify-center gap-1 ${form.key_source !== "file" ? "bg-accent-blue/20 text-accent-blue border border-accent-blue/50" : "bg-bg-primary text-text-muted border border-border"}`}>
                        <ClipboardPaste size={12} /> 粘贴内容
                      </button>
                      <button onClick={() => update("key_source", "file")}
                        className={`flex-1 py-1.5 rounded text-xs transition-colors flex items-center justify-center gap-1 ${form.key_source === "file" ? "bg-accent-blue/20 text-accent-blue border border-accent-blue/50" : "bg-bg-primary text-text-muted border border-border"}`}>
                        <FileKey size={12} /> 本地文件
                      </button>
                    </div>
                  </div>

                  {form.key_source === "file" ? (
                    <div>
                      <label className="block text-xs text-text-muted mb-1">密钥文件路径</label>
                      <div className="flex gap-2">
                        <input type="text" value={form.key_file_path ?? ""} onChange={(e) => update("key_file_path", e.target.value)}
                          className={`${inputCls} flex-1`} placeholder="~/.ssh/id_rsa" />
                        <button onClick={pickKeyFile} className="px-3 rounded bg-bg-tertiary text-text-secondary hover:text-text-primary text-sm">选择</button>
                      </div>
                    </div>
                  ) : (
                    <div>
                      <label className="block text-xs text-text-muted mb-1">私钥内容</label>
                      <textarea value={form.private_key ?? ""} onChange={(e) => update("private_key", e.target.value)}
                        className={`${inputCls} font-mono`} rows={6}
                        placeholder={"-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"} />
                    </div>
                  )}

                  <div>
                    <label className="block text-xs text-text-muted mb-1">密钥密码（可选）</label>
                    <div className="relative">
                      <input type={showKeyPass ? "text" : "password"} value={form.key_passphrase ?? ""} onChange={(e) => update("key_passphrase", e.target.value)}
                        className={`${inputCls} pr-10`} placeholder="Passphrase" />
                      <button type="button" onClick={() => setShowKeyPass(!showKeyPass)} className="absolute right-2 top-1/2 -translate-y-1/2 text-text-muted hover:text-text-secondary">
                        {showKeyPass ? <EyeOff size={14} /> : <Eye size={14} />}
                      </button>
                    </div>
                  </div>
                </>
              )}
            </>
          )}

          {testResult && (
            <div className={`text-xs px-3 py-2 rounded ${testResult === "success" ? "bg-accent-green/10 text-accent-green" : "bg-accent-red/10 text-accent-red"}`}>
              {testResult === "success" ? "连接成功" : `连接失败: ${testResult.replace("error:", "")}`}
            </div>
          )}
        </div>

        <div className="flex items-center justify-between px-5 py-4 border-t border-border">
          <button onClick={handleTest} disabled={testing || !form.host || (!useCg && !form.username)}
            className="flex items-center gap-1.5 px-3 py-2 rounded text-sm bg-bg-tertiary text-text-secondary hover:text-text-primary disabled:opacity-50">
            {testing ? <Loader2 size={14} className="animate-spin" /> : <Plug size={14} />} 测试连接
          </button>
          <div className="flex gap-2">
            {editingServer && (
              <button onClick={() => { deleteServer(editingServer.id); closeDialog(); }}
                className="px-3 py-2 rounded text-sm text-accent-red hover:bg-accent-red/10">删除</button>
            )}
            <button onClick={closeDialog} className="px-4 py-2 rounded text-sm text-text-muted hover:text-text-secondary">取消</button>
            <button onClick={handleSave} disabled={saving || !form.name || !form.host || (!useCg && !form.username)}
              className="px-4 py-2 rounded text-sm bg-accent-blue text-white hover:bg-accent-blue/80 disabled:opacity-50">
              {saving ? "保存中..." : "保存"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
