use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};

use crate::database::models::{
    DatabaseBackupArtifact, DatabaseBackupSource, DatabaseBackupTable, DatabaseColumnSchema,
    DatabaseConnection, DatabaseOperationResult, DatabaseTableSchema,
};
use crate::database::store::DatabaseStore;
use crate::db::Database;

pub fn backup_directory() -> Result<PathBuf> {
    let base = dirs::data_dir()
        .ok_or_else(|| anyhow!("unable to locate application support directory"))?
        .join("orbit")
        .join("backups");
    fs::create_dir_all(&base)?;
    Ok(base)
}

pub fn backup_path_for(connection: &DatabaseConnection) -> Result<PathBuf> {
    let timestamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ");
    let safe_name = sanitize_filename(&connection.name);
    Ok(backup_directory()?.join(format!(
        "{}-{}-{}.orbit-db-backup.json",
        timestamp, connection.engine, safe_name
    )))
}

pub fn write_artifact(path: &Path, artifact: &DatabaseBackupArtifact) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(artifact)?;
    fs::write(path, json)?;
    Ok(())
}

pub fn read_artifact(path: &str) -> Result<DatabaseBackupArtifact> {
    let bytes = fs::read(path)?;
    let artifact: DatabaseBackupArtifact = serde_json::from_slice(&bytes)?;
    if artifact.format_version != 1 {
        return Err(anyhow!(
            "unsupported backup artifact format version {}",
            artifact.format_version
        ));
    }
    Ok(artifact)
}

pub fn artifact_from_tables(
    connection: &DatabaseConnection,
    tables: Vec<DatabaseBackupTable>,
) -> DatabaseBackupArtifact {
    DatabaseBackupArtifact {
        format_version: 1,
        source: DatabaseBackupSource {
            engine: connection.engine.clone(),
            connection_name: connection.name.clone(),
        },
        created_at: chrono::Utc::now().to_rfc3339(),
        tables,
    }
}

pub fn table_to_backup_rows(
    table: &DatabaseTableSchema,
    rows: Vec<Vec<Option<String>>>,
) -> DatabaseBackupTable {
    let backup_rows = rows
        .into_iter()
        .map(|row| {
            table
                .columns
                .iter()
                .zip(row)
                .map(|(column, value)| (column.name.clone(), value))
                .collect::<HashMap<_, _>>()
        })
        .collect();

    DatabaseBackupTable {
        name: table.name.clone(),
        columns: table.columns.clone(),
        rows: backup_rows,
    }
}

pub fn create_backup_record(
    db: &Database,
    connection: &DatabaseConnection,
    operation: &str,
    artifact_path: &str,
    artifact: &DatabaseBackupArtifact,
) -> Result<DatabaseOperationResult> {
    let summary = format!(
        "{} tables, {} rows",
        artifact.tables.len(),
        artifact.row_count()
    );
    DatabaseStore::add_backup_record(
        db,
        &crate::database::models::DatabaseBackupRecordInput {
            connection_id: connection.id.clone(),
            connection_name: connection.name.clone(),
            engine: connection.engine.clone(),
            artifact_path: artifact_path.into(),
            operation: operation.into(),
            status: "success".into(),
            summary: summary.clone(),
        },
    )?;
    Ok(DatabaseOperationResult::ok(operation, summary)
        .with_artifact(artifact_path)
        .with_affected_rows(artifact.row_count() as u64))
}

pub fn create_table_sql(table: &DatabaseBackupTable, engine: &str) -> String {
    let columns = table
        .columns
        .iter()
        .map(|column| create_column_sql(column, engine))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "CREATE TABLE {} ({})",
        quote_ident(&table.name, engine),
        columns
    )
}

pub fn insert_rows_sql(
    table: &DatabaseBackupTable,
    engine: &str,
    batch: &[usize],
) -> Option<String> {
    if batch.is_empty() || table.columns.is_empty() {
        return None;
    }
    let column_names = table
        .columns
        .iter()
        .map(|column| quote_ident(&column.name, engine))
        .collect::<Vec<_>>()
        .join(", ");
    let values = batch
        .iter()
        .map(|row_index| {
            let row = &table.rows[*row_index];
            let values = table
                .columns
                .iter()
                .map(|column| sql_literal(row.get(&column.name).and_then(|v| v.as_deref())))
                .collect::<Vec<_>>()
                .join(", ");
            format!("({})", values)
        })
        .collect::<Vec<_>>()
        .join(", ");
    Some(format!(
        "INSERT INTO {} ({}) VALUES {}",
        quote_ident(&table.name, engine),
        column_names,
        values
    ))
}

pub fn drop_table_sql(table_name: &str, engine: &str) -> String {
    format!("DROP TABLE IF EXISTS {}", quote_ident(table_name, engine))
}

pub fn quote_ident(identifier: &str, engine: &str) -> String {
    match engine {
        "mysql" => format!("`{}`", identifier.replace('`', "``")),
        _ => format!("\"{}\"", identifier.replace('"', "\"\"")),
    }
}

pub fn sql_literal(value: Option<&str>) -> String {
    match value {
        Some(value) => format!("'{}'", value.replace('\'', "''")),
        None => "NULL".into(),
    }
}

fn create_column_sql(column: &DatabaseColumnSchema, engine: &str) -> String {
    let mut parts = vec![quote_ident(&column.name, engine), column.db_type.clone()];
    if !column.nullable {
        parts.push("NOT NULL".into());
    }
    if let Some(default_value) = &column.default_value {
        parts.push(format!("DEFAULT {}", default_value));
    }
    if column.primary_key {
        parts.push("PRIMARY KEY".into());
    }
    parts.join(" ")
}

fn sanitize_filename(value: &str) -> String {
    let sanitized: String = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '-'
            }
        })
        .collect();
    sanitized.trim_matches('-').to_string()
}

#[cfg(test)]
mod tests {
    use crate::database::models::DatabaseBackupArtifact;

    #[test]
    fn backup_artifact_round_trips_schema_and_rows() {
        let artifact = DatabaseBackupArtifact::single_table_for_test(
            "users",
            vec![("id", "INTEGER"), ("system", "TEXT")],
            vec![vec![("id", Some("1")), ("system", Some("prod"))]],
        );

        let json = serde_json::to_string(&artifact).expect("serialize");
        let parsed: DatabaseBackupArtifact = serde_json::from_str(&json).expect("parse");

        assert_eq!(parsed.tables[0].name, "users");
        assert_eq!(parsed.tables[0].columns[1].name, "system");
        assert_eq!(
            parsed.tables[0].rows[0].get("system").unwrap().as_deref(),
            Some("prod")
        );
    }
}
