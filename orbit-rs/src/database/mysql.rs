use std::collections::HashMap;
use std::time::Instant;

use anyhow::{anyhow, Result};
use mysql::prelude::Queryable;
use mysql::{OptsBuilder, Value};

use crate::database::backup::{drop_table_sql, insert_rows_sql, quote_ident, sql_literal};
use crate::database::models::{
    DatabaseBackupArtifact, DatabaseBackupTable, DatabaseColumnSchema, DatabaseConnection,
    DatabaseImportPlan, DatabaseOperationResult, DatabaseQueryResult, DatabaseTableSchema,
};
use crate::database::sql::is_write_statement;

pub struct MysqlEngine;

impl MysqlEngine {
    pub fn test_connection(connection: &DatabaseConnection) -> Result<DatabaseOperationResult> {
        let mut conn = Self::connect(connection)?;
        conn.query_drop("SELECT 1")?;
        Ok(DatabaseOperationResult::ok(
            "ok",
            "MySQL connection succeeded",
        ))
    }

    pub fn list_schema(connection: &DatabaseConnection) -> Result<Vec<DatabaseTableSchema>> {
        let mut conn = Self::connect(connection)?;
        list_schema_with_conn(&mut conn, connection)
    }

    pub fn execute(
        connection: &DatabaseConnection,
        sql: &str,
        read_only: bool,
    ) -> Result<DatabaseQueryResult> {
        if read_only && is_write_statement(sql) {
            return Err(anyhow!("read-only database query rejected write statement"));
        }

        let started = Instant::now();
        let mut conn = Self::connect(connection)?;
        if is_write_statement(sql) {
            conn.query_drop(sql)?;
            return Ok(DatabaseQueryResult::empty_message(
                "Query executed",
                conn.affected_rows(),
                started.elapsed().as_millis() as u64,
            ));
        }

        let result = conn.query_iter(sql)?;
        let columns = result
            .columns()
            .as_ref()
            .iter()
            .map(|column| column.name_str().to_string())
            .collect::<Vec<_>>();
        let rows = result
            .map(|row| {
                let row = row?;
                row.unwrap()
                    .into_iter()
                    .map(mysql_value_to_string)
                    .collect::<Result<Vec<_>>>()
            })
            .collect::<Result<Vec<_>>>()?;

        Ok(DatabaseQueryResult {
            columns,
            rows,
            affected_rows: 0,
            elapsed_ms: started.elapsed().as_millis() as u64,
            message: String::new(),
        })
    }

    pub fn backup_tables(connection: &DatabaseConnection) -> Result<Vec<DatabaseBackupTable>> {
        let mut conn = Self::connect(connection)?;
        let schema = list_schema_with_conn(&mut conn, connection)?;
        let mut tables = Vec::new();
        for table in schema {
            let rows = backup_rows_with_conn(&mut conn, &table)?;
            tables.push(DatabaseBackupTable {
                name: table.name,
                columns: table.columns,
                rows,
            });
        }
        Ok(tables)
    }

    pub fn restore_artifact(
        connection: &DatabaseConnection,
        artifact: &DatabaseBackupArtifact,
    ) -> Result<u64> {
        let mut conn = Self::connect(connection)?;
        let mut inserted = 0;
        for table in &artifact.tables {
            inserted += restore_table_with_shadow(&mut conn, table)?;
        }
        Ok(inserted)
    }

    pub fn run_import(
        connection: &DatabaseConnection,
        artifact: &DatabaseBackupArtifact,
        plan: &DatabaseImportPlan,
    ) -> Result<u64> {
        let mut conn = Self::connect(connection)?;
        let mut inserted = 0;

        for table_plan in &plan.tables {
            let source_table = artifact
                .tables
                .iter()
                .find(|table| table.name == table_plan.source_table)
                .ok_or_else(|| {
                    anyhow!(
                        "source table {} not found in backup",
                        table_plan.source_table
                    )
                })?;

            let mapped_columns = table_plan
                .columns
                .iter()
                .filter_map(|mapping| {
                    mapping
                        .target_column
                        .as_ref()
                        .filter(|target| !target.trim().is_empty())
                        .map(|target| (mapping.source_column.clone(), target.clone()))
                })
                .collect::<Vec<_>>();

            if mapped_columns.is_empty() {
                continue;
            }

            if plan.mode == "new_table" {
                let table = import_table_definition(&table_plan.target_table, table_plan);
                conn.query_drop(crate::database::backup::create_table_sql(&table, "mysql"))?;
            }

            for chunk in source_table.rows.chunks(500) {
                let sql = import_insert_sql(&table_plan.target_table, &mapped_columns, chunk);
                conn.query_drop(sql).map_err(|e| {
                    anyhow!(
                        "failed importing table {} batch starting at row {}: {}",
                        table_plan.target_table,
                        inserted,
                        e
                    )
                })?;
                inserted += chunk.len() as u64;
            }
        }

        Ok(inserted)
    }

    fn connect(connection: &DatabaseConnection) -> Result<mysql::Conn> {
        let mut builder = OptsBuilder::new()
            .ip_or_hostname(Some(connection.host.clone()))
            .tcp_port(connection.port)
            .user(if connection.username.is_empty() {
                None
            } else {
                Some(connection.username.clone())
            })
            .pass(if connection.password.is_empty() {
                None
            } else {
                Some(connection.password.clone())
            });
        if !connection.database_name.is_empty() {
            builder = builder.db_name(Some(connection.database_name.clone()));
        }
        mysql::Conn::new(builder).map_err(Into::into)
    }
}

fn list_schema_with_conn(
    conn: &mut mysql::Conn,
    connection: &DatabaseConnection,
) -> Result<Vec<DatabaseTableSchema>> {
    let rows: Vec<(String, String, String, String, Option<String>, u64, String)> = conn.exec(
        "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY = 'PRI' AS IS_PRIMARY, EXTRA
         FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = ?
         ORDER BY TABLE_NAME, ORDINAL_POSITION",
        (connection.database_name.as_str(),),
    )?;
    Ok(rows_to_schema(rows))
}

fn backup_rows_with_conn(
    conn: &mut mysql::Conn,
    table: &DatabaseTableSchema,
) -> Result<Vec<HashMap<String, Option<String>>>> {
    let sql = format!("SELECT * FROM {}", quote_ident(&table.name, "mysql"));
    let result = conn.query_iter(sql)?;
    result
        .map(|row| {
            let values = row?.unwrap();
            table
                .columns
                .iter()
                .zip(values)
                .map(|(column, value)| {
                    if is_mysql_binary_type(&column.db_type) && !matches!(value, Value::NULL) {
                        return Err(anyhow!(
                            "unsupported MySQL binary column {}.{}; binary backup is not supported yet",
                            table.name,
                            column.name
                        ));
                    }
                    Ok((column.name.clone(), mysql_value_to_string(value)?))
                })
                .collect::<Result<HashMap<_, _>>>()
        })
        .collect()
}

fn rows_to_schema(
    rows: Vec<(String, String, String, String, Option<String>, u64, String)>,
) -> Vec<DatabaseTableSchema> {
    let mut tables: Vec<DatabaseTableSchema> = Vec::new();
    for (table_name, column_name, db_type, nullable, default_value, primary_key, extra) in rows {
        let auto_generated = mysql_extra_is_auto_generated(&extra);
        if let Some(table) = tables.iter_mut().find(|table| table.name == table_name) {
            table.columns.push(DatabaseColumnSchema {
                name: column_name,
                db_type,
                nullable: nullable == "YES",
                primary_key: primary_key != 0,
                default_value,
                auto_generated,
            });
        } else {
            tables.push(DatabaseTableSchema {
                name: table_name,
                columns: vec![DatabaseColumnSchema {
                    name: column_name,
                    db_type,
                    nullable: nullable == "YES",
                    primary_key: primary_key != 0,
                    default_value,
                    auto_generated,
                }],
            });
        }
    }
    tables
}

fn mysql_value_to_string(value: Value) -> Result<Option<String>> {
    match value {
        Value::NULL => Ok(None),
        Value::Bytes(bytes) => String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| anyhow!("unsupported non-UTF-8 MySQL bytes value")),
        Value::Int(value) => Ok(Some(value.to_string())),
        Value::UInt(value) => Ok(Some(value.to_string())),
        Value::Float(value) => Ok(Some(value.to_string())),
        Value::Double(value) => Ok(Some(value.to_string())),
        Value::Date(year, month, day, hour, minute, second, micros) => Ok(Some(format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:06}",
            year, month, day, hour, minute, second, micros
        ))),
        Value::Time(negative, days, hours, minutes, seconds, micros) => {
            let sign = if negative { "-" } else { "" };
            Ok(Some(format!(
                "{}{} {:02}:{:02}:{:02}.{:06}",
                sign, days, hours, minutes, seconds, micros
            )))
        }
    }
}

fn mysql_extra_is_auto_generated(extra: &str) -> bool {
    let normalized = extra.to_ascii_lowercase();
    normalized.contains("auto_increment") || normalized.contains("generated")
}

fn is_mysql_binary_type(db_type: &str) -> bool {
    let normalized = db_type.to_ascii_lowercase();
    normalized.contains("blob")
        || normalized.contains("binary")
        || normalized.contains("varbinary")
        || normalized.contains("bit")
}

fn insert_table_rows(conn: &mut mysql::Conn, table: &DatabaseBackupTable) -> Result<u64> {
    let mut inserted = 0;
    for indexes in (0..table.rows.len())
        .collect::<Vec<_>>()
        .chunks(500)
        .map(|chunk| chunk.to_vec())
    {
        if let Some(sql) = insert_rows_sql(table, "mysql", &indexes) {
            conn.query_drop(sql)?;
            inserted += indexes.len() as u64;
        }
    }
    Ok(inserted)
}

fn restore_table_with_shadow(conn: &mut mysql::Conn, table: &DatabaseBackupTable) -> Result<u64> {
    let suffix = chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default();
    let restore_name = restore_shadow_name("__orbit_restore", &table.name, suffix);
    let backup_name = restore_shadow_name("__orbit_backup", &table.name, suffix);
    let restore_table = backup_table_with_name(table, &restore_name);

    conn.query_drop(crate::database::backup::create_table_sql(
        &restore_table,
        "mysql",
    ))?;
    let inserted = match insert_table_rows(conn, &restore_table) {
        Ok(inserted) => inserted,
        Err(error) => {
            let _ = conn.query_drop(drop_table_sql(&restore_name, "mysql"));
            return Err(error);
        }
    };

    let original_exists = mysql_table_exists(conn, &table.name)?;
    let rename_sql = restore_rename_sql(&table.name, &restore_name, &backup_name, original_exists);
    if let Err(error) = conn.query_drop(rename_sql) {
        let _ = conn.query_drop(drop_table_sql(&restore_name, "mysql"));
        return Err(error.into());
    }
    if original_exists {
        conn.query_drop(drop_table_sql(&backup_name, "mysql"))?;
    }
    Ok(inserted)
}

fn mysql_table_exists(conn: &mut mysql::Conn, table_name: &str) -> Result<bool> {
    let count: Option<u64> = conn.exec_first(
        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?",
        (table_name,),
    )?;
    Ok(count.unwrap_or(0) > 0)
}

fn restore_rename_sql(
    table_name: &str,
    restore_name: &str,
    backup_name: &str,
    original_exists: bool,
) -> String {
    if original_exists {
        return format!(
            "RENAME TABLE {} TO {}, {} TO {}",
            quote_ident(table_name, "mysql"),
            quote_ident(backup_name, "mysql"),
            quote_ident(restore_name, "mysql"),
            quote_ident(table_name, "mysql")
        );
    }
    format!(
        "RENAME TABLE {} TO {}",
        quote_ident(restore_name, "mysql"),
        quote_ident(table_name, "mysql")
    )
}

fn backup_table_with_name(table: &DatabaseBackupTable, name: &str) -> DatabaseBackupTable {
    let mut renamed = table.clone();
    renamed.name = name.into();
    renamed
}

fn restore_shadow_name(prefix: &str, table_name: &str, suffix: i64) -> String {
    let safe = table_name
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>();
    format!("{}_{}_{}", prefix, safe, suffix)
}

fn import_table_definition(
    table_name: &str,
    table_plan: &crate::database::models::DatabaseImportTablePlan,
) -> DatabaseBackupTable {
    DatabaseBackupTable {
        name: table_name.into(),
        columns: table_plan
            .columns
            .iter()
            .filter_map(|mapping| {
                mapping
                    .target_column
                    .as_ref()
                    .map(|target| DatabaseColumnSchema {
                        name: target.clone(),
                        db_type: mapping.target_type.clone(),
                        nullable: !mapping.required_without_default,
                        primary_key: false,
                        default_value: None,
                        auto_generated: false,
                    })
            })
            .collect(),
        rows: Vec::new(),
    }
}

fn import_insert_sql(
    table_name: &str,
    mapped_columns: &[(String, String)],
    rows: &[HashMap<String, Option<String>>],
) -> String {
    let columns = mapped_columns
        .iter()
        .map(|(_, target)| quote_ident(target, "mysql"))
        .collect::<Vec<_>>()
        .join(", ");
    let values = rows
        .iter()
        .map(|row| {
            let values = mapped_columns
                .iter()
                .map(|(source, _)| sql_literal(row.get(source).and_then(|value| value.as_deref())))
                .collect::<Vec<_>>()
                .join(", ");
            format!("({})", values)
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "INSERT INTO {} ({}) VALUES {}",
        quote_ident(table_name, "mysql"),
        columns,
        values
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mysql_auto_increment_columns_are_marked_auto_generated() {
        let schema = rows_to_schema(vec![(
            "users".into(),
            "id".into(),
            "bigint unsigned".into(),
            "NO".into(),
            None,
            1,
            "auto_increment".into(),
        )]);

        assert!(schema[0].columns[0].auto_generated);
    }

    #[test]
    fn mysql_invalid_utf8_bytes_fail_instead_of_lossy_backup_value() {
        let err =
            mysql_value_to_string(Value::Bytes(vec![0xff, 0xfe])).expect_err("invalid utf8 bytes");

        assert!(err.to_string().contains("non-UTF-8 MySQL bytes"));
    }

    #[test]
    fn restore_rename_sql_handles_missing_original_table() {
        let sql = restore_rename_sql(
            "users",
            "__orbit_restore_users_1",
            "__orbit_backup_users_1",
            false,
        );

        assert_eq!(sql, "RENAME TABLE `__orbit_restore_users_1` TO `users`");
        assert!(!sql.contains("__orbit_backup"));
    }

    #[test]
    fn restore_rename_sql_swaps_existing_original_table() {
        let sql = restore_rename_sql(
            "users",
            "__orbit_restore_users_1",
            "__orbit_backup_users_1",
            true,
        );

        assert_eq!(
            sql,
            "RENAME TABLE `users` TO `__orbit_backup_users_1`, `__orbit_restore_users_1` TO `users`"
        );
    }
}
