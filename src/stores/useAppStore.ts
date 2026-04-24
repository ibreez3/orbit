import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import type { Server, Tab, CredentialGroup, ServerInput } from "../types";

interface AppState {
  servers: Server[];
  credentialGroups: CredentialGroup[];
  tabs: Tab[];
  activeTabId: string | null;
  sidebarCollapsed: boolean;
  dialogOpen: boolean;
  editingServer: Server | null;
  dialogDefaults: Partial<ServerInput> | null;
  cgDialogOpen: boolean;
  editingCg: CredentialGroup | null;
  loading: boolean;

  loadServers: () => Promise<void>;
  addServer: (input: any) => Promise<void>;
  updateServer: (id: string, input: any) => Promise<void>;
  deleteServer: (id: string) => Promise<void>;
  loadCredentialGroups: () => Promise<void>;
  addCg: (input: any) => Promise<void>;
  updateCg: (id: string, input: any) => Promise<void>;
  deleteCg: (id: string) => Promise<void>;
  addTab: (tab: Tab) => void;
  removeTab: (id: string) => void;
  setActiveTab: (id: string | null) => void;
  updateTabSessionId: (tabId: string, sessionId: string) => void;
  toggleSidebar: () => void;
  openDialog: (server?: Server, defaults?: Partial<ServerInput>) => void;
  closeDialog: () => void;
  moveServerToGroup: (serverId: string, groupName: string) => Promise<void>;
  openCgDialog: (cg?: CredentialGroup) => void;
  closeCgDialog: () => void;
}

export const useAppStore = create<AppState>((set, get) => ({
  servers: [],
  credentialGroups: [],
  tabs: [],
  activeTabId: null,
  sidebarCollapsed: false,
  dialogOpen: false,
  editingServer: null,
  dialogDefaults: null,
  cgDialogOpen: false,
  editingCg: null,
  loading: false,

  loadServers: async () => {
    set({ loading: true });
    try {
      const servers = await invoke<Server[]>("list_servers");
      set({ servers });
    } catch (e) {
      console.error("加载服务器列表失败:", e);
    } finally {
      set({ loading: false });
    }
  },

  addServer: async (input) => {
    const server = await invoke<Server>("add_server", { input });
    set((s) => ({ servers: [...s.servers, server] }));
  },

  updateServer: async (id, input) => {
    const server = await invoke<Server>("update_server", { id, input });
    set((s) => ({
      servers: s.servers.map((sv) => (sv.id === id ? server : sv)),
    }));
  },

  deleteServer: async (id) => {
    await invoke("delete_server", { id });
    set((s) => ({
      servers: s.servers.filter((sv) => sv.id !== id),
      tabs: s.tabs.filter((t) => t.serverId !== id),
    }));
  },

  loadCredentialGroups: async () => {
    try {
      const credentialGroups = await invoke<CredentialGroup[]>("list_credential_groups");
      set({ credentialGroups });
    } catch (e) {
      console.error("加载凭据分组失败:", e);
    }
  },

  addCg: async (input) => {
    const cg = await invoke<CredentialGroup>("add_credential_group", { input });
    set((s) => ({ credentialGroups: [...s.credentialGroups, cg] }));
  },

  updateCg: async (id, input) => {
    const cg = await invoke<CredentialGroup>("update_credential_group", { id, input });
    set((s) => ({
      credentialGroups: s.credentialGroups.map((g) => (g.id === id ? cg : g)),
    }));
  },

  deleteCg: async (id) => {
    await invoke("delete_credential_group", { id });
    set((s) => ({
      credentialGroups: s.credentialGroups.filter((g) => g.id !== id),
    }));
  },

  addTab: (tab) => {
    if (tab.type === "monitor") {
      const existing = get().tabs.find(
        (t) => t.type === "monitor" && t.serverId === tab.serverId
      );
      if (existing) {
        set({ activeTabId: existing.id });
        return;
      }
    }
    set((s) => ({ tabs: [...s.tabs, tab], activeTabId: tab.id }));
  },

  removeTab: (id) => {
    set((s) => {
      const tabs = s.tabs.filter((t) => t.id !== id);
      let activeTabId = s.activeTabId;
      if (activeTabId === id) {
        const idx = s.tabs.findIndex((t) => t.id === id);
        activeTabId = tabs.length > 0 ? tabs[Math.min(idx, tabs.length - 1)].id : null;
      }
      return { tabs, activeTabId };
    });
  },

  setActiveTab: (id) => set({ activeTabId: id }),
  updateTabSessionId: (tabId, sessionId) => {
    set((s) => ({
      tabs: s.tabs.map((t) => (t.id === tabId ? { ...t, sessionId } : t)),
    }));
  },
  toggleSidebar: () => set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),
  openDialog: (server?, defaults?) => set({ dialogOpen: true, editingServer: server ?? null, dialogDefaults: defaults ?? null }),
  closeDialog: () => set({ dialogOpen: false, editingServer: null, dialogDefaults: null }),
  moveServerToGroup: async (serverId, groupName) => {
    const sv = get().servers.find((s) => s.id === serverId);
    if (!sv) return;
    const input = {
      name: sv.name,
      host: sv.host,
      port: sv.port,
      group_name: groupName,
      auth_type: sv.auth_type,
      username: sv.username,
      password: sv.password,
      private_key: sv.private_key,
      key_source: sv.key_source,
      key_file_path: sv.key_file_path,
      key_passphrase: sv.key_passphrase,
      credential_group_id: sv.credential_group_id,
    };
    const updated = await invoke<Server>("update_server", { id: serverId, input });
    set((s) => ({
      servers: s.servers.map((x) => (x.id === serverId ? updated : x)),
    }));
  },
  openCgDialog: (cg?: CredentialGroup) => set({ cgDialogOpen: true, editingCg: cg ?? null }),
  closeCgDialog: () => set({ cgDialogOpen: false, editingCg: null }),
}));
