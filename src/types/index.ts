export interface Server {
  id: string;
  name: string;
  host: string;
  port: number;
  group_name: string;
  auth_type: string;
  username: string;
  password: string;
  private_key: string;
  key_source: string;
  key_file_path: string;
  key_passphrase: string;
  credential_group_id: string;
  jump_server_id: string;
  created_at: string;
  updated_at: string;
}

export interface ServerInput {
  name: string;
  host: string;
  port?: number;
  group_name?: string;
  auth_type?: string;
  username: string;
  password?: string;
  private_key?: string;
  key_source?: string;
  key_file_path?: string;
  key_passphrase?: string;
  credential_group_id?: string;
  jump_server_id?: string;
}

export interface CredentialGroup {
  id: string;
  name: string;
  auth_type: string;
  username: string;
  password: string;
  private_key: string;
  key_source: string;
  key_file_path: string;
  key_passphrase: string;
  created_at: string;
  updated_at: string;
}

export interface CredentialGroupInput {
  name: string;
  auth_type?: string;
  username: string;
  password?: string;
  private_key?: string;
  key_source?: string;
  key_file_path?: string;
  key_passphrase?: string;
}

export interface ServerStats {
  cpu_usage: number;
  mem_total_mb: number;
  mem_used_mb: number;
  mem_percent: number;
  disk_total: string;
  disk_used: string;
  disk_percent: number;
  uptime: string;
  load_avg: string;
}

export interface FileEntry {
  name: string;
  path: string;
  is_dir: boolean;
  size: number;
  modified: string;
  permissions: string;
}

export interface Tab {
  id: string;
  type: "terminal" | "sftp" | "monitor";
  serverId: string;
  serverName: string;
  title: string;
  sessionId?: string;
}

export interface Pane {
  id: string;
  tabId: string | null;
  direction: "horizontal" | "vertical";
  size: number;
}
