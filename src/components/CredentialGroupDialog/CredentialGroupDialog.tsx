import { useState } from "react";
import { open as dialogOpen } from "@tauri-apps/plugin-dialog";
import { useAppStore } from "../../stores/useAppStore";
import { X, Eye, EyeOff, FileKey, ClipboardPaste } from "lucide-react";
import type { CredentialGroupInput } from "../../types";

export default function CredentialGroupDialog() {
  const { editingCg, closeCgDialog, addCg, updateCg } = useAppStore();

  const [form, setForm] = useState<CredentialGroupInput>({
    name: editingCg?.name ?? "",
    auth_type: editingCg?.auth_type ?? "password",
    username: editingCg?.username ?? "",
    password: editingCg?.password ?? "",
    private_key: editingCg?.private_key ?? "",
    key_source: editingCg?.key_source ?? "content",
    key_file_path: editingCg?.key_file_path ?? "",
    key_passphrase: editingCg?.key_passphrase ?? "",
  });
  const [showPassword, setShowPassword] = useState(false);
  const [showKeyPass, setShowKeyPass] = useState(false);
  const [saving, setSaving] = useState(false);

  const update = (key: keyof CredentialGroupInput, value: string) => {
    setForm((prev) => ({ ...prev, [key]: value }));
  };

  const pickKeyFile = async () => {
    const selected = await dialogOpen({
      multiple: false,
      filters: [{ name: "Private Key", extensions: ["pem", "key", "id_rsa", "id_ed25519", "id_ecdsa", ""] }],
    });
    if (selected) update("key_file_path", selected as string);
  };

  const handleSave = async () => {
    if (!form.name || !form.username) return;
    setSaving(true);
    try {
      if (editingCg) {
        await updateCg(editingCg.id, form);
      } else {
        await addCg(form);
      }
      closeCgDialog();
    } catch (e) {
      console.error("保存失败:", e);
    } finally {
      setSaving(false);
    }
  };

  const inputCls = "w-full bg-bg-primary border border-border rounded px-3 py-2 text-sm text-text-primary focus:border-accent-blue";

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={closeCgDialog}>
      <div className="bg-bg-secondary rounded-xl border border-border shadow-2xl w-[460px] max-h-[90vh] overflow-y-auto" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-5 py-4 border-b border-border">
          <h2 className="text-sm font-semibold text-text-primary">{editingCg ? "编辑凭据分组" : "新建凭据分组"}</h2>
          <button onClick={closeCgDialog} className="p-1 rounded hover:bg-bg-tertiary text-text-muted hover:text-text-primary"><X size={16} /></button>
        </div>

        <div className="px-5 py-4 space-y-4">
          <div>
            <label className="block text-xs text-text-muted mb-1">分组名称 *</label>
            <input type="text" value={form.name} onChange={(e) => update("name", e.target.value)} className={inputCls} placeholder="生产环境密钥" />
          </div>

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
                    <input type="text" value={form.key_file_path ?? ""} onChange={(e) => update("key_file_path", e.target.value)} className={`${inputCls} flex-1`} placeholder="~/.ssh/id_rsa" />
                    <button onClick={pickKeyFile} className="px-3 rounded bg-bg-tertiary text-text-secondary hover:text-text-primary text-sm">选择</button>
                  </div>
                </div>
              ) : (
                <div>
                  <label className="block text-xs text-text-muted mb-1">私钥内容</label>
                  <textarea value={form.private_key ?? ""} onChange={(e) => update("private_key", e.target.value)}
                    className={`${inputCls} font-mono`} rows={5}
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

          <div className="text-xs text-text-muted bg-bg-primary rounded px-3 py-2">
            关联此分组的服务器将使用该分组的凭据进行连接，无需单独配置密码或密钥。
          </div>
        </div>

        <div className="flex justify-end gap-2 px-5 py-4 border-t border-border">
          <button onClick={closeCgDialog} className="px-4 py-2 rounded text-sm text-text-muted hover:text-text-secondary">取消</button>
          <button onClick={handleSave} disabled={saving || !form.name || !form.username}
            className="px-4 py-2 rounded text-sm bg-accent-purple text-white hover:bg-accent-purple/80 disabled:opacity-50">
            {saving ? "保存中..." : "保存"}
          </button>
        </div>
      </div>
    </div>
  );
}
