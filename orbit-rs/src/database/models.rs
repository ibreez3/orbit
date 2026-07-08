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
    pub ok: bool,
    pub code: String,
    pub message: String,
    pub artifact_path: Option<String>,
    pub affected_rows: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseImportPlan {
    pub backup_path: String,
    pub target_connection_id: String,
    pub mode: String,
    pub tables: Vec<DatabaseImportTablePlan>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseImportTablePlan {
    pub source_table: String,
    pub target_table: String,
    pub columns: Vec<DatabaseImportColumnMapping>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseImportColumnMapping {
    pub source_column: String,
    pub target_column: Option<String>,
    pub target_type: String,
    pub required_without_default: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseImportRequest {
    pub plan: DatabaseImportPlan,
}

#[cfg(test)]
impl DatabaseImportPlan {
    pub fn single_table_for_test(
        source_table: &str,
        target_table: &str,
        mappings: Vec<(&str, &str)>,
    ) -> Self {
        Self {
            backup_path: "/tmp/source.orbit-db-backup.json".into(),
            target_connection_id: "target-mysql".into(),
            mode: "new_table".into(),
            tables: vec![DatabaseImportTablePlan {
                source_table: source_table.into(),
                target_table: target_table.into(),
                columns: mappings
                    .into_iter()
                    .map(
                        |(source_column, target_column)| DatabaseImportColumnMapping {
                            source_column: source_column.into(),
                            target_column: Some(target_column.into()),
                            target_type: "TEXT".into(),
                            required_without_default: false,
                        },
                    )
                    .collect(),
            }],
        }
    }
}
