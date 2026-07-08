use std::collections::HashMap;
use std::time::Instant;

use anyhow::{anyhow, Result};
use postgres::{Client, NoTls, Row};

use crate::database::backup::{drop_table_sql, insert_rows_sql, quote_ident};
use crate::database::models::{
    DatabaseBackupArtifact, DatabaseBackupTable, DatabaseColumnSchema, DatabaseConnection,
    DatabaseOperationResult, DatabaseQueryResult, DatabaseTableSchema,
};
use crate::database::sql::is_write_statement;

pub struct PostgresEngine;

impl PostgresEngine {
    pub fn test_connection(connection: &DatabaseConnection) -> Result<DatabaseOperationResult> {
        let mut client = Self::connect(connection)?;
        client.simple_query("SELECT 1")?;
        Ok(DatabaseOperationResult::ok(
            "ok",
            "PostgreSQL connection succeeded",
        ))
    }

    pub fn list_schema(connection: &DatabaseConnection) -> Result<Vec<DatabaseTableSchema>> {
        let mut client = Self::connect(connection)?;
        list_schema_with_client(&mut client)
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
        let mut client = Self::connect(connection)?;
        if is_write_statement(sql) {
            let affected = client.execute(sql, &[])?;
            return Ok(DatabaseQueryResult::empty_message(
                "Query executed",
                affected,
                started.elapsed().as_millis() as u64,
            ));
        }

        let rows = client.query(sql, &[])?;
        let columns = rows
            .first()
            .map(|row| {
                row.columns()
                    .iter()
                    .map(|column| column.name().to_string())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let result_rows = rows
            .iter()
            .map(|row| {
                (0..columns.len())
                    .map(|index| postgres_cell_to_string(row, index))
                    .collect()
            })
            .collect();

        Ok(DatabaseQueryResult {
            columns,
            rows: result_rows,
            affected_rows: 0,
            elapsed_ms: started.elapsed().as_millis() as u64,
            message: String::new(),
        })
    }

    pub fn backup_tables(connection: &DatabaseConnection) -> Result<Vec<DatabaseBackupTable>> {
        let mut client = Self::connect(connection)?;
        let schema = list_schema_with_client(&mut client)?;
        let mut tables = Vec::new();
        for table in schema {
            let rows = backup_rows_with_client(&mut client, &table)?;
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
        let mut client = Self::connect(connection)?;
        let mut inserted = 0;
        for table in &artifact.tables {
            client.batch_execute(&drop_table_sql(&table.name, "postgres"))?;
            client.batch_execute(&crate::database::backup::create_table_sql(
                table, "postgres",
            ))?;
            for indexes in (0..table.rows.len())
                .collect::<Vec<_>>()
                .chunks(500)
                .map(|chunk| chunk.to_vec())
            {
                if let Some(sql) = insert_rows_sql(table, "postgres", &indexes) {
                    client.batch_execute(&sql)?;
                    inserted += indexes.len() as u64;
                }
            }
        }
        Ok(inserted)
    }

    fn connect(connection: &DatabaseConnection) -> Result<Client> {
        let mut config = postgres::Config::new();
        config
            .host(&connection.host)
            .port(connection.port)
            .user(&connection.username);
        if !connection.password.is_empty() {
            config.password(&connection.password);
        }
        if !connection.database_name.is_empty() {
            config.dbname(&connection.database_name);
        }
        config.connect(NoTls).map_err(Into::into)
    }
}

fn list_schema_with_client(client: &mut Client) -> Result<Vec<DatabaseTableSchema>> {
    let rows = client.query(
        "SELECT c.table_name, c.column_name, c.data_type, c.is_nullable, c.column_default,
                COALESCE(tc.constraint_type = 'PRIMARY KEY', false) AS is_primary
         FROM information_schema.columns c
         LEFT JOIN information_schema.key_column_usage kcu
           ON c.table_schema = kcu.table_schema
          AND c.table_name = kcu.table_name
          AND c.column_name = kcu.column_name
         LEFT JOIN information_schema.table_constraints tc
           ON kcu.constraint_schema = tc.constraint_schema
          AND kcu.constraint_name = tc.constraint_name
          AND tc.constraint_type = 'PRIMARY KEY'
         WHERE c.table_schema = 'public'
         ORDER BY c.table_name, c.ordinal_position",
        &[],
    )?;
    Ok(rows_to_schema(rows))
}

fn backup_rows_with_client(
    client: &mut Client,
    table: &DatabaseTableSchema,
) -> Result<Vec<HashMap<String, Option<String>>>> {
    let sql = format!("SELECT * FROM {}", quote_ident(&table.name, "postgres"));
    let rows = client.query(&sql, &[])?;
    Ok(rows
        .iter()
        .map(|row| {
            table
                .columns
                .iter()
                .enumerate()
                .map(|(index, column)| (column.name.clone(), postgres_cell_to_string(row, index)))
                .collect::<HashMap<_, _>>()
        })
        .collect())
}

fn rows_to_schema(rows: Vec<Row>) -> Vec<DatabaseTableSchema> {
    let mut tables: Vec<DatabaseTableSchema> = Vec::new();
    for row in rows {
        let table_name: String = row.get(0);
        let column = DatabaseColumnSchema {
            name: row.get(1),
            db_type: row.get(2),
            nullable: row.get::<_, String>(3) == "YES",
            primary_key: row.get(5),
            default_value: row.get(4),
        };

        if let Some(table) = tables.iter_mut().find(|table| table.name == table_name) {
            table.columns.push(column);
        } else {
            tables.push(DatabaseTableSchema {
                name: table_name,
                columns: vec![column],
            });
        }
    }
    tables
}

fn postgres_cell_to_string(row: &Row, index: usize) -> Option<String> {
    if let Ok(value) = row.try_get::<_, Option<String>>(index) {
        return value;
    }
    if let Ok(value) = row.try_get::<_, Option<i64>>(index) {
        return value.map(|value| value.to_string());
    }
    if let Ok(value) = row.try_get::<_, Option<i32>>(index) {
        return value.map(|value| value.to_string());
    }
    if let Ok(value) = row.try_get::<_, Option<f64>>(index) {
        return value.map(|value| value.to_string());
    }
    if let Ok(value) = row.try_get::<_, Option<f32>>(index) {
        return value.map(|value| value.to_string());
    }
    if let Ok(value) = row.try_get::<_, Option<bool>>(index) {
        return value.map(|value| value.to_string());
    }
    Some("<unsupported>".into())
}
