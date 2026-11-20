import { invoke } from '@tauri-apps/api/core';

export type Server = {
  id: string; name: string; host: string; port: number; username: string; auth_type: string;
  jump_server_id: string; group_name?: string; key_source?: string; key_file_path?: string;
  credential_group_id?: string; folder_id?: string | null; is_pinned?: boolean; pin_order?: number | null;
  last_connected_at?: string | null; last_connection_result?: string | null; last_connection_error?: string | null;
};
export type Credential = { id: string; name: string; username: string; auth_type: string; key_source: string; key_file_path: string };
export type Folder = { id: string; name: string; parent_id: string | null; sort_order: number };
export type Organization = { folders: Folder[]; tags: { id: string; name: string }[]; tag_links: { server_id: string; tag_id: string }[] };
export const request = <T,>(action: string, args: Record<string, unknown> = {}) => invoke<T>('request', { action, args });
export const message = (error: unknown) => String(error);
