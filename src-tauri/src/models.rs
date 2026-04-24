use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Server {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub group_name: String,
    pub auth_type: String,
    pub username: String,
    pub password: String,
    pub private_key: String,
    pub key_passphrase: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
pub struct ServerInput {
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub group_name: Option<String>,
    pub auth_type: Option<String>,
    pub username: String,
    pub password: Option<String>,
    pub private_key: Option<String>,
    pub key_passphrase: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ServerStats {
    pub cpu_usage: f64,
    pub mem_total_mb: u64,
    pub mem_used_mb: u64,
    pub mem_percent: f64,
    pub disk_total: String,
    pub disk_used: String,
    pub disk_percent: f64,
    pub uptime: String,
    pub load_avg: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: String,
    pub permissions: String,
}
