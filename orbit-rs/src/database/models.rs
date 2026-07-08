use serde::{Deserialize, Serialize};
use std::collections::HashMap;

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
pub struct DatabaseColumnSchema {
    pub name: String,
    pub db_type: String,
    pub nullable: bool,
    pub primary_key: bool,
    pub default_value: Option<String>,
    #[serde(default)]
    pub auto_generated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseTableSchema {
    pub name: String,
    pub columns: Vec<DatabaseColumnSchema>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseSchema {
    pub connection_id: String,
    pub engine: String,
    pub tables: Vec<DatabaseTableSchema>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseQueryRequest {
    pub sql: String,
    pub read_only: bool,
    pub timeout_ms: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseQueryResult {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Option<String>>>,
    pub affected_rows: u64,
    pub elapsed_ms: u64,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseBackupSource {
    pub engine: String,
    pub connection_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseBackupTable {
    pub name: String,
    pub columns: Vec<DatabaseColumnSchema>,
    pub rows: Vec<HashMap<String, Option<String>>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseBackupArtifact {
    pub format_version: u32,
    pub source: DatabaseBackupSource,
    pub created_at: String,
    pub tables: Vec<DatabaseBackupTable>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseRestoreRequest {
    pub backup_path: String,
    pub target_connection_id: String,
    pub mode: String,
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

impl DatabaseOperationResult {
    pub fn ok(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            ok: true,
            code: code.into(),
            message: message.into(),
            artifact_path: None,
            affected_rows: None,
        }
    }

    pub fn with_artifact(mut self, artifact_path: impl Into<String>) -> Self {
        self.artifact_path = Some(artifact_path.into());
        self
    }

    pub fn with_affected_rows(mut self, affected_rows: u64) -> Self {
        self.affected_rows = Some(affected_rows);
        self
    }
}

impl DatabaseQueryResult {
    pub fn empty_message(message: impl Into<String>, affected_rows: u64, elapsed_ms: u64) -> Self {
        Self {
            columns: Vec::new(),
            rows: Vec::new(),
            affected_rows,
            elapsed_ms,
            message: message.into(),
        }
    }
}

impl DatabaseBackupArtifact {
    pub fn row_count(&self) -> usize {
        self.tables.iter().map(|table| table.rows.len()).sum()
    }
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

#[cfg(test)]
impl DatabaseBackupArtifact {
    pub fn single_table_for_test(
        table_name: &str,
        columns: Vec<(&str, &str)>,
        rows: Vec<Vec<(&str, Option<&str>)>>,
    ) -> Self {
        Self {
            format_version: 1,
            source: DatabaseBackupSource {
                engine: "remote_sqlite".into(),
                connection_name: "test sqlite".into(),
            },
            created_at: "2026-07-08T00:00:00+00:00".into(),
            tables: vec![DatabaseBackupTable {
                name: table_name.into(),
                columns: columns
                    .into_iter()
                    .map(|(name, db_type)| DatabaseColumnSchema {
                        name: name.into(),
                        db_type: db_type.into(),
                        nullable: true,
                        primary_key: false,
                        default_value: None,
                        auto_generated: false,
                    })
                    .collect(),
                rows: rows
                    .into_iter()
                    .map(|row| {
                        row.into_iter()
                            .map(|(name, value)| (name.into(), value.map(str::to_string)))
                            .collect()
                    })
                    .collect(),
            }],
        }
    }
}
