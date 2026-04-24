import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import type { Server, Tab } from "../types";

interface AppState {
  servers: Server[];
  tabs: Tab[];
  activeTabId: string | null;
  sidebarCollapsed: boolean;
  dialogOpen: boolean;
  editingServer: Server | null;
  loading: boolean;

  loadServers: () => Promise<void>;
  addServer: (input: any) => Promise<void>;
  updateServer: (id: string, input: any) => Promise<void>;
  deleteServer: (id: string) => Promise<void>;
  addTab: (tab: Tab) => void;
  removeTab: (id: string) => void;
  setActiveTab: (id: string | null) => void;
  toggleSidebar: () => void;
  openDialog: (server?: Server) => void;
  closeDialog: () => void;
}

export const useAppStore = create<AppState>((set, get) => ({
  servers: [],
  tabs: [],
  activeTabId: null,
  sidebarCollapsed: false,
  dialogOpen: false,
  editingServer: null,
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

  addTab: (tab) => {
    const existing = get().tabs.find(
      (t) => t.type === tab.type && t.serverId === tab.serverId
    );
    if (existing) {
      set({ activeTabId: existing.id });
      return;
    }
    set((s) => ({ tabs: [...s.tabs, tab], activeTabId: tab.id }));
  },

  removeTab: (id) => {
    set((s) => {
      const tabs = s.tabs.filter((t) => t.id !== id);
      let activeTabId = s.activeTabId;
      if (activeTabId === id) {
        const idx = s.tabs.findIndex((t) => t.id === id);
        activeTabId =
          tabs.length > 0
            ? tabs[Math.min(idx, tabs.length - 1)].id
            : null;
      }
      return { tabs, activeTabId };
    });
  },

  setActiveTab: (id) => set({ activeTabId: id }),
  toggleSidebar: () => set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),
  openDialog: (server) => set({ dialogOpen: true, editingServer: server ?? null }),
  closeDialog: () => set({ dialogOpen: false, editingServer: null }),
}));
