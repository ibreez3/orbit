use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseConnection {
    pub id: String,
    pub name: String,
    pub group_name: String,
    pub engine: String,
    pub ssh_server_id: String,
    pub use_ssh_tunnel: bool,
    pub host: String,
    pub port: u16,
    pub database_name: String,
    pub username: String,
    pub password: String,
    pub sqlite_path: String,
    pub ssl_mode: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseConnectionInput {
    pub name: String,
    pub group_name: Option<String>,
    pub engine: String,
    pub ssh_server_id: Option<String>,
    pub use_ssh_tunnel: Option<bool>,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub database_name: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub sqlite_path: Option<String>,
    pub ssl_mode: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseBackupRecord {
    pub id: String,
    pub connection_id: String,
    pub connection_name: String,
    pub engine: String,
    pub artifact_path: String,
    pub operation: String,
    pub status: String,
    pub summary: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseBackupRecordInput {
    pub connection_id: String,
    pub connection_name: String,
    pub engine: String,
    pub artifact_path: String,
    pub operation: String,
    pub status: String,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseOperationResult {
    pub success: bool,
    pub message: String,
}
