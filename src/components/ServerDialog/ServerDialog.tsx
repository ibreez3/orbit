import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/useAppStore";
import { X, Eye, EyeOff, Plug, Loader2 } from "lucide-react";
import type { ServerInput } from "../../types";

export default function ServerDialog() {
  const { editingServer, closeDialog, addServer, updateServer, deleteServer } =
    useAppStore();

  const [form, setForm] = useState<ServerInput>({
    name: editingServer?.name ?? "",
    host: editingServer?.host ?? "",
    port: editingServer?.port ?? 22,
    group_name: editingServer?.group_name ?? "",
    auth_type: editingServer?.auth_type ?? "password",
    username: editingServer?.username ?? "",
    password: editingServer?.password ?? "",
    private_key: editingServer?.private_key ?? "",
    key_passphrase: editingServer?.key_passphrase ?? "",
  });
  const [showPassword, setShowPassword] = useState(false);
  const [showKeyPass, setShowKeyPass] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const update = (key: keyof ServerInput, value: string | number) => {
    setForm((prev) => ({ ...prev, [key]: value }));
    setTestResult(null);
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
    if (!form.name || !form.host || !form.username) return;
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

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      onClick={closeDialog}
    >
      <div
        className="bg-bg-secondary rounded-xl border border-border shadow-2xl w-[480px] max-h-[90vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-5 py-4 border-b border-border">
          <h2 className="text-sm font-semibold text-text-primary">
            {editingServer ? "编辑服务器" : "添加服务器"}
          </h2>
          <button
            onClick={closeDialog}
            className="p-1 rounded hover:bg-bg-tertiary text-text-muted hover:text-text-primary"
          >
            <X size={16} />
          </button>
        </div>

        <div className="px-5 py-4 space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-text-muted mb-1">
                名称 *
              </label>
              <input
                type="text"
                value={form.name}
                onChange={(e) => update("name", e.target.value)}
                className="w-full bg-bg-primary border border-border rounded px-3 py-2 text-sm text-text-primary focus:border-accent-blue"
                placeholder="My Server"
              />
            </div>
            <div>
              <label className="block text-xs text-text-muted mb-1">
                分组
              </label>
              <input
                type="text"
                value={form.group_name ?? ""}
                onChange={(e) => update("group_name", e.target.value)}
                className="w-full bg-bg-primary border border-border rounded px-3 py-2 text-sm text-text-primary focus:border-accent-blue"
                placeholder="Production"
              />
            </div>
          </div>

          <div className="grid grid-cols-3 gap-3">
            <div className="col-span-2">
              <label className="block text-xs text-text-muted mb-1">
                主机地址 *
              </label>
              <input
                type="text"
                value={form.host}
                onChange={(e) => update("host", e.target.value)}
                className="w-full bg-bg-primary border border-border rounded px-3 py-2 text-sm text-text-primary focus:border-accent-blue"
                placeholder="192.168.1.1"
              />
            </div>
            <div>
              <label className="block text-xs text-text-muted mb-1">
                端口
              </label>
              <input
                type="number"
                value={form.port ?? 22}
                onChange={(e) => update("port", parseInt(e.target.value) || 22)}
                className="w-full bg-bg-primary border border-border rounded px-3 py-2 text-sm text-text-primary focus:border-accent-blue"
              />
            </div>
          </div>

          <div>
            <label className="block text-xs text-text-muted mb-1">
              用户名 *
            </label>
            <input
              type="text"
              value={form.username}
              onChange={(e) => update("username", e.target.value)}
              className="w-full bg-bg-primary border border-border rounded px-3 py-2 text-sm text-text-primary focus:border-accent-blue"
              placeholder="root"
            />
          </div>

          <div>
            <label className="block text-xs text-text-muted mb-2">
              认证方式
            </label>
            <div className="flex gap-2">
              <button
                onClick={() => update("auth_type", "password")}
                className={`flex-1 py-2 rounded text-sm transition-colors ${
                  form.auth_type === "password"
                    ? "bg-accent-blue/20 text-accent-blue border border-accent-blue/50"
                    : "bg-bg-primary text-text-muted border border-border hover:border-text-muted"
                }`}
              >
                密码认证
              </button>
              <button
                onClick={() => update("auth_type", "key")}
                className={`flex-1 py-2 rounded text-sm transition-colors ${
                  form.auth_type === "key"
                    ? "bg-accent-blue/20 text-accent-blue border border-accent-blue/50"
                    : "bg-bg-primary text-text-muted border border-border hover:border-text-muted"
                }`}
              >
                密钥认证
              </button>
            </div>
          </div>

          {form.auth_type === "password" ? (
            <div>
              <label className="block text-xs text-text-muted mb-1">
                密码
              </label>
              <div className="relative">
                <input
                  type={showPassword ? "text" : "password"}
                  value={form.password ?? ""}
                  onChange={(e) => update("password", e.target.value)}
                  className="w-full bg-bg-primary border border-border rounded px-3 py-2 pr-10 text-sm text-text-primary focus:border-accent-blue"
                  placeholder="Enter password"
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="absolute right-2 top-1/2 -translate-y-1/2 text-text-muted hover:text-text-secondary"
                >
                  {showPassword ? <EyeOff size={14} /> : <Eye size={14} />}
                </button>
              </div>
            </div>
          ) : (
            <>
              <div>
                <label className="block text-xs text-text-muted mb-1">
                  私钥内容
                </label>
                <textarea
                  value={form.private_key ?? ""}
                  onChange={(e) => update("private_key", e.target.value)}
                  className="w-full bg-bg-primary border border-border rounded px-3 py-2 text-sm text-text-primary focus:border-accent-blue font-mono"
                  rows={6}
                  placeholder="-----BEGIN OPENSSH PRIVATE KEY-----&#10;...&#10;-----END OPENSSH PRIVATE KEY-----"
                />
              </div>
              <div>
                <label className="block text-xs text-text-muted mb-1">
                  密钥密码（可选）
                </label>
                <div className="relative">
                  <input
                    type={showKeyPass ? "text" : "password"}
                    value={form.key_passphrase ?? ""}
                    onChange={(e) => update("key_passphrase", e.target.value)}
                    className="w-full bg-bg-primary border border-border rounded px-3 py-2 pr-10 text-sm text-text-primary focus:border-accent-blue"
                    placeholder="Passphrase"
                  />
                  <button
                    type="button"
                    onClick={() => setShowKeyPass(!showKeyPass)}
                    className="absolute right-2 top-1/2 -translate-y-1/2 text-text-muted hover:text-text-secondary"
                  >
                    {showKeyPass ? (
                      <EyeOff size={14} />
                    ) : (
                      <Eye size={14} />
                    )}
                  </button>
                </div>
              </div>
            </>
          )}

          {testResult && (
            <div
              className={`text-xs px-3 py-2 rounded ${
                testResult === "success"
                  ? "bg-accent-green/10 text-accent-green"
                  : "bg-accent-red/10 text-accent-red"
              }`}
            >
              {testResult === "success"
                ? "连接成功"
                : `连接失败: ${testResult.replace("error:", "")}`}
            </div>
          )}
        </div>

        <div className="flex items-center justify-between px-5 py-4 border-t border-border">
          <button
            onClick={handleTest}
            disabled={testing || !form.host || !form.username}
            className="flex items-center gap-1.5 px-3 py-2 rounded text-sm bg-bg-tertiary text-text-secondary hover:text-text-primary disabled:opacity-50 transition-colors"
          >
            {testing ? (
              <Loader2 size={14} className="animate-spin" />
            ) : (
              <Plug size={14} />
            )}
            测试连接
          </button>
          <div className="flex gap-2">
            {editingServer && (
              <button
                onClick={() => {
                  deleteServer(editingServer.id);
                  closeDialog();
                }}
                className="px-3 py-2 rounded text-sm text-accent-red hover:bg-accent-red/10 transition-colors"
              >
                删除
              </button>
            )}
            <button
              onClick={closeDialog}
              className="px-4 py-2 rounded text-sm text-text-muted hover:text-text-secondary transition-colors"
            >
              取消
            </button>
            <button
              onClick={handleSave}
              disabled={saving || !form.name || !form.host || !form.username}
              className="px-4 py-2 rounded text-sm bg-accent-blue text-white hover:bg-accent-blue/80 disabled:opacity-50 transition-colors"
            >
              {saving ? "保存中..." : "保存"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
