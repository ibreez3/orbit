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
        let rows: Vec<(String, String, String, String, Option<String>, u64)> = conn.exec(
            "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY = 'PRI' AS IS_PRIMARY
             FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = ?
             ORDER BY TABLE_NAME, ORDINAL_POSITION",
            (connection.database_name.as_str(),),
        )?;
        Ok(rows_to_schema(rows))
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
                Ok(row
                    .unwrap()
                    .into_iter()
                    .map(mysql_value_to_string)
                    .collect::<Vec<_>>())
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
        let schema = Self::list_schema(connection)?;
        let mut tables = Vec::new();
        for table in schema {
            let sql = format!("SELECT * FROM {}", quote_ident(&table.name, "mysql"));
            let result = Self::execute(connection, &sql, true)?;
            let rows = result
                .rows
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
            conn.query_drop(drop_table_sql(&table.name, "mysql"))?;
            conn.query_drop(crate::database::backup::create_table_sql(table, "mysql"))?;
            inserted += insert_table_rows(&mut conn, table)?;
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

fn rows_to_schema(
    rows: Vec<(String, String, String, String, Option<String>, u64)>,
) -> Vec<DatabaseTableSchema> {
    let mut tables: Vec<DatabaseTableSchema> = Vec::new();
    for (table_name, column_name, db_type, nullable, default_value, primary_key) in rows {
        if let Some(table) = tables.iter_mut().find(|table| table.name == table_name) {
            table.columns.push(DatabaseColumnSchema {
                name: column_name,
                db_type,
                nullable: nullable == "YES",
                primary_key: primary_key != 0,
                default_value,
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
                }],
            });
        }
    }
    tables
}

fn mysql_value_to_string(value: Value) -> Option<String> {
    match value {
        Value::NULL => None,
        Value::Bytes(bytes) => Some(String::from_utf8_lossy(&bytes).to_string()),
        Value::Int(value) => Some(value.to_string()),
        Value::UInt(value) => Some(value.to_string()),
        Value::Float(value) => Some(value.to_string()),
        Value::Double(value) => Some(value.to_string()),
        Value::Date(year, month, day, hour, minute, second, micros) => Some(format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:06}",
            year, month, day, hour, minute, second, micros
        )),
        Value::Time(negative, days, hours, minutes, seconds, micros) => {
            let sign = if negative { "-" } else { "" };
            Some(format!(
                "{}{} {:02}:{:02}:{:02}.{:06}",
                sign, days, hours, minutes, seconds, micros
            ))
        }
    }
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
