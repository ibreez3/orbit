pub mod backup;
pub mod import_mysql;
pub mod models;
pub mod mysql;
pub mod postgres;
pub mod sql;
pub mod sqlite_remote;
pub mod store;

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{anyhow, Result};

use crate::database::backup::{
    artifact_from_tables, backup_path_for, create_backup_record, drop_table_sql, read_artifact,
    table_to_backup_rows, write_artifact,
};
use crate::database::import_mysql::{
    prepare_existing_table_import_plan, prepare_new_table_import_plan, validate_mysql_import_plan,
    validate_mysql_import_sources,
};
use crate::database::models::{
    DatabaseBackupTable as BackupTable, DatabaseImportPlan as ImportPlan,
    DatabaseOperationResult as OpResult, DatabaseQueryRequest as QueryRequest,
    DatabaseQueryResult as QueryResult, DatabaseRestoreRequest as RestoreRequest,
    DatabaseSchema as Schema,
};
use crate::database::mysql::MysqlEngine;
use crate::database::postgres::PostgresEngine;
use crate::database::sqlite_remote::SqliteRemote;
use crate::db::Database;
use crate::transport;

pub use models::*;
pub use store::DatabaseStore;

pub struct DatabaseManager;

impl DatabaseManager {
    pub fn test_connection(
        db: &Database,
        pool: &transport::SessionPool,
        connection_id: &str,
        install_sqlite: bool,
    ) -> Result<DatabaseOperationResult> {
        let connection = DatabaseStore::get_connection(db, connection_id)?;
        match connection.engine.as_str() {
            "remote_sqlite" => {
                let server = db.get_server(&connection.ssh_server_id)?;
                SqliteRemote::test_connection(pool, &server, db, install_sqlite)
            }
            "mysql" => with_driver_connection(db, &connection, MysqlEngine::test_connection),
            "postgres" => with_driver_connection(db, &connection, PostgresEngine::test_connection),
            engine => Err(anyhow!("unsupported database engine: {}", engine)),
        }
    }

    pub fn list_schema(
        db: &Database,
        pool: &transport::SessionPool,
        connection_id: &str,
    ) -> Result<Schema> {
        let connection = DatabaseStore::get_connection(db, connection_id)?;
        let tables = match connection.engine.as_str() {
            "remote_sqlite" => {
                let server = db.get_server(&connection.ssh_server_id)?;
                SqliteRemote::list_schema(pool, &server, db, &connection.sqlite_path)?
            }
            "mysql" => with_driver_connection(db, &connection, MysqlEngine::list_schema)?,
            "postgres" => with_driver_connection(db, &connection, PostgresEngine::list_schema)?,
            engine => return Err(anyhow!("unsupported database engine: {}", engine)),
        };

        Ok(Schema {
            connection_id: connection.id,
            engine: connection.engine,
            tables,
        })
    }

    pub fn execute(
        db: &Database,
        pool: &transport::SessionPool,
        connection_id: &str,
        request: &QueryRequest,
    ) -> Result<QueryResult> {
        let connection = DatabaseStore::get_connection(db, connection_id)?;
        match connection.engine.as_str() {
            "remote_sqlite" => {
                if request.read_only && crate::database::sql::is_write_statement(&request.sql) {
                    return Err(anyhow!("read-only database query rejected write statement"));
                }
                let server = db.get_server(&connection.ssh_server_id)?;
                SqliteRemote::execute(pool, &server, db, &connection.sqlite_path, &request.sql)
            }
            "mysql" => with_driver_connection(db, &connection, |connection| {
                MysqlEngine::execute(connection, &request.sql, request.read_only)
            }),
            "postgres" => with_driver_connection(db, &connection, |connection| {
                PostgresEngine::execute(connection, &request.sql, request.read_only)
            }),
            engine => Err(anyhow!("unsupported database engine: {}", engine)),
        }
    }

    pub fn backup(
        db: &Database,
        pool: &transport::SessionPool,
        connection_id: &str,
    ) -> Result<OpResult> {
        let connection = DatabaseStore::get_connection(db, connection_id)?;
        let tables = match connection.engine.as_str() {
            "remote_sqlite" => {
                let server = db.get_server(&connection.ssh_server_id)?;
                let schema = SqliteRemote::list_schema(pool, &server, db, &connection.sqlite_path)?;
                let mut tables = Vec::new();
                for table in schema {
                    let sql = format!(
                        "SELECT {} FROM {}",
                        table
                            .columns
                            .iter()
                            .map(|column| sqlite_ident(&column.name))
                            .collect::<Vec<_>>()
                            .join(", "),
                        sqlite_ident(&table.name)
                    );
                    let rows =
                        SqliteRemote::execute(pool, &server, db, &connection.sqlite_path, &sql)?;
                    tables.push(table_to_backup_rows(&table, rows.rows));
                }
                tables
            }
            "mysql" => with_driver_connection(db, &connection, MysqlEngine::backup_tables)?,
            "postgres" => with_driver_connection(db, &connection, PostgresEngine::backup_tables)?,
            engine => return Err(anyhow!("unsupported database engine: {}", engine)),
        };

        let artifact = artifact_from_tables(&connection, tables);
        let path = backup_path_for(&connection)?;
        write_artifact(&path, &artifact)?;
        create_backup_record(
            db,
            &connection,
            "backup",
            &path.to_string_lossy(),
            &artifact,
        )
    }

    pub fn restore(
        db: &Database,
        pool: &transport::SessionPool,
        request: &RestoreRequest,
    ) -> Result<OpResult> {
        validate_restore_mode(&request.mode)?;
        let connection = DatabaseStore::get_connection(db, &request.target_connection_id)?;
        let artifact = read_artifact(&request.backup_path)?;
        if artifact.source.engine != connection.engine {
            return Err(anyhow!(
                "restore requires matching engine: backup is {}, target is {}",
                artifact.source.engine,
                connection.engine
            ));
        }

        let affected_rows = match connection.engine.as_str() {
            "remote_sqlite" => restore_sqlite(db, pool, &connection, &artifact.tables)?,
            "mysql" => with_driver_connection(db, &connection, |connection| {
                MysqlEngine::restore_artifact(connection, &artifact)
            })?,
            "postgres" => with_driver_connection(db, &connection, |connection| {
                PostgresEngine::restore_artifact(connection, &artifact)
            })?,
            engine => return Err(anyhow!("unsupported database engine: {}", engine)),
        };

        DatabaseStore::add_backup_record(
            db,
            &DatabaseBackupRecordInput {
                connection_id: connection.id.clone(),
                connection_name: connection.name.clone(),
                engine: connection.engine.clone(),
                artifact_path: request.backup_path.clone(),
                operation: "restore".into(),
                status: "success".into(),
                summary: format!(
                    "{} tables, {} rows restored",
                    artifact.tables.len(),
                    affected_rows
                ),
            },
        )?;

        Ok(
            DatabaseOperationResult::ok("restore", format!("{} rows restored", affected_rows))
                .with_artifact(&request.backup_path)
                .with_affected_rows(affected_rows),
        )
    }

    pub fn prepare_import(
        db: &Database,
        backup_path: &str,
        target_connection_id: &str,
        mode: &str,
    ) -> Result<ImportPlan> {
        let connection = DatabaseStore::get_connection(db, target_connection_id)?;
        if connection.engine != "mysql" {
            return Err(anyhow!("SQLite backup import target must be MySQL"));
        }
        let artifact = read_artifact(backup_path)?;
        if artifact.source.engine != "remote_sqlite" {
            return Err(anyhow!(
                "only remote SQLite backups can be imported to MySQL"
            ));
        }

        match mode {
            "new_table" => Ok(prepare_new_table_import_plan(
                &artifact,
                backup_path,
                target_connection_id,
            )),
            "existing_table" | "existing" | "append_existing" => {
                let schema = with_driver_connection(db, &connection, MysqlEngine::list_schema)?;
                Ok(prepare_existing_table_import_plan(
                    &artifact,
                    backup_path,
                    target_connection_id,
                    &schema,
                ))
            }
            other => Err(anyhow!("unsupported import mode: {}", other)),
        }
    }

    pub fn run_import(
        db: &Database,
        request: &DatabaseImportRequest,
    ) -> Result<DatabaseOperationResult> {
        validate_mysql_import_plan(&request.plan)?;
        let connection = DatabaseStore::get_connection(db, &request.plan.target_connection_id)?;
        if connection.engine != "mysql" {
            return Err(anyhow!("SQLite backup import target must be MySQL"));
        }
        let artifact = read_artifact(&request.plan.backup_path)?;
        if artifact.source.engine != "remote_sqlite" {
            return Err(anyhow!(
                "only remote SQLite backups can be imported to MySQL"
            ));
        }
        validate_mysql_import_sources(&request.plan, &artifact)?;
        let affected_rows = with_driver_connection(db, &connection, |connection| {
            MysqlEngine::run_import(connection, &artifact, &request.plan)
        })?;

        DatabaseStore::add_backup_record(
            db,
            &DatabaseBackupRecordInput {
                connection_id: connection.id,
                connection_name: connection.name,
                engine: connection.engine,
                artifact_path: request.plan.backup_path.clone(),
                operation: "import_to_mysql".into(),
                status: "success".into(),
                summary: format!("{} rows imported", affected_rows),
            },
        )?;

        Ok(DatabaseOperationResult::ok(
            "import_to_mysql",
            format!("{} rows imported", affected_rows),
        )
        .with_artifact(&request.plan.backup_path)
        .with_affected_rows(affected_rows))
    }
}

fn with_driver_connection<T>(
    db: &Database,
    connection: &DatabaseConnection,
    operation: impl FnOnce(&DatabaseConnection) -> Result<T>,
) -> Result<T> {
    if !connection.use_ssh_tunnel {
        return operation(connection);
    }

    let tunnel = DbTunnel::open(db, connection)?;
    let mut tunneled = connection.clone();
    tunneled.host = "127.0.0.1".into();
    tunneled.port = tunnel.local_port;
    operation(&tunneled)
}

fn validate_restore_mode(mode: &str) -> Result<()> {
    if mode == "overwrite" {
        return Ok(());
    }
    Err(anyhow!(
        "unsupported restore mode: {}; only overwrite is supported",
        mode
    ))
}

struct DbTunnel {
    local_port: u16,
    running: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
    _guard: transport::SessionGuard,
}

impl DbTunnel {
    fn open(db: &Database, connection: &DatabaseConnection) -> Result<Self> {
        if connection.ssh_server_id.is_empty() {
            return Err(anyhow!("SSH tunnel requested but ssh_server_id is empty"));
        }
        let server = db.get_server(&connection.ssh_server_id)?;
        let guard = transport::create_session(&server, db)?;
        guard.session.set_blocking(false);
        let channel =
            guard
                .session
                .channel_direct_tcpip(connection.host.as_str(), connection.port, None)?;
        let (local_port, handle, running) = start_single_connection_proxy(channel)?;
        Ok(Self {
            local_port,
            running,
            handle: Some(handle),
            _guard: guard,
        })
    }
}

impl Drop for DbTunnel {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        let _ = TcpStream::connect(("127.0.0.1", self.local_port));
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

fn start_single_connection_proxy(
    mut channel: ssh2::Channel,
) -> Result<(u16, std::thread::JoinHandle<()>, Arc<AtomicBool>)> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let local_port = listener.local_addr()?.port();
    let running = Arc::new(AtomicBool::new(true));
    let run = running.clone();
    let handle = std::thread::spawn(move || {
        let Ok((mut local, _)) = listener.accept() else {
            return;
        };
        let _ = local.set_nonblocking(true);
        let mut up = [0u8; 32768];
        let mut down = [0u8; 32768];

        while run.load(Ordering::Relaxed) {
            let mut did_work = false;
            match local.read(&mut up) {
                Ok(0) => break,
                Ok(n) => {
                    did_work = true;
                    if channel.write_all(&up[..n]).is_err() {
                        break;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => break,
            }
            match channel.read(&mut down) {
                Ok(0) => break,
                Ok(n) => {
                    did_work = true;
                    if local.write_all(&down[..n]).is_err() {
                        break;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => break,
            }
            if !did_work {
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
        }
    });
    Ok((local_port, handle, running))
}

fn restore_sqlite(
    db: &Database,
    pool: &transport::SessionPool,
    connection: &DatabaseConnection,
    tables: &[BackupTable],
) -> Result<u64> {
    let server = db.get_server(&connection.ssh_server_id)?;
    let mut affected = 0;
    for table in tables {
        SqliteRemote::execute_raw(
            pool,
            &server,
            db,
            &connection.sqlite_path,
            &drop_table_sql(&table.name, "sqlite"),
        )?;
        SqliteRemote::execute_raw(
            pool,
            &server,
            db,
            &connection.sqlite_path,
            &crate::database::backup::create_table_sql(table, "sqlite"),
        )?;
        for indexes in (0..table.rows.len())
            .collect::<Vec<_>>()
            .chunks(500)
            .map(|chunk| chunk.to_vec())
        {
            if let Some(sql) = crate::database::backup::insert_rows_sql(table, "sqlite", &indexes) {
                SqliteRemote::execute_raw(pool, &server, db, &connection.sqlite_path, &sql)?;
                affected += indexes.len() as u64;
            }
        }
    }
    Ok(affected)
}

fn sqlite_ident(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_restore_modes_other_than_overwrite() {
        let err = validate_restore_mode("merge").expect_err("unsupported restore mode");

        assert!(err.to_string().contains("unsupported restore mode"));
        assert!(err.to_string().contains("merge"));
    }
}
