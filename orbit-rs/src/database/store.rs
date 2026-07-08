use crate::crypto;
use crate::database::models::{
    DatabaseBackupRecord, DatabaseBackupRecordInput, DatabaseConnection, DatabaseConnectionInput,
};
use crate::db::Database;
use anyhow::Result;
use rusqlite::params;

pub struct DatabaseStore;

impl DatabaseStore {
    const CONNECTION_COLUMNS: &'static str = "id, name, group_name, engine, ssh_server_id, use_ssh_tunnel, host, port, database_name, username, password, sqlite_path, ssl_mode, created_at, updated_at";
    const BACKUP_RECORD_COLUMNS: &'static str = "id, connection_id, connection_name, engine, artifact_path, operation, status, summary, created_at";

    pub fn list_connections(db: &Database) -> Result<Vec<DatabaseConnection>> {
        let conn = db.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM database_connections ORDER BY group_name, name",
            Self::CONNECTION_COLUMNS
        ))?;
        let connections = stmt
            .query_map([], Self::row_to_connection)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(connections)
    }

    pub fn get_connection(db: &Database, id: &str) -> Result<DatabaseConnection> {
        let conn = db.conn.lock().unwrap();
        let connection = conn.query_row(
            &format!(
                "SELECT {} FROM database_connections WHERE id = ?1",
                Self::CONNECTION_COLUMNS
            ),
            [id],
            Self::row_to_connection,
        )?;
        Ok(connection)
    }

    pub fn add_connection(
        db: &Database,
        input: &DatabaseConnectionInput,
    ) -> Result<DatabaseConnection> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let connection = Self::connection_from_input(id, now.clone(), now, input);
        let enc_password = crypto::encrypt(&connection.password);
        let conn = db.conn.lock().unwrap();
        conn.execute(
            &format!(
                "INSERT INTO database_connections ({}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
                Self::CONNECTION_COLUMNS
            ),
            params![
                &connection.id,
                &connection.name,
                &connection.group_name,
                &connection.engine,
                &connection.ssh_server_id,
                if connection.use_ssh_tunnel { 1 } else { 0 },
                &connection.host,
                connection.port,
                &connection.database_name,
                &connection.username,
                enc_password,
                &connection.sqlite_path,
                &connection.ssl_mode,
                &connection.created_at,
                &connection.updated_at,
            ],
        )?;
        Ok(connection)
    }

    pub fn update_connection(
        db: &Database,
        id: &str,
        input: &DatabaseConnectionInput,
    ) -> Result<DatabaseConnection> {
        let existing = Self::get_connection(db, id)?;
        let now = chrono::Utc::now().to_rfc3339();
        let connection = Self::connection_from_update(existing, now, input);
        let enc_password = crypto::encrypt(&connection.password);
        let conn = db.conn.lock().unwrap();
        conn.execute(
            "UPDATE database_connections SET name=?1, group_name=?2, engine=?3, ssh_server_id=?4, use_ssh_tunnel=?5, host=?6, port=?7, database_name=?8, username=?9, password=?10, sqlite_path=?11, ssl_mode=?12, updated_at=?13 WHERE id=?14",
            params![
                &connection.name,
                &connection.group_name,
                &connection.engine,
                &connection.ssh_server_id,
                if connection.use_ssh_tunnel { 1 } else { 0 },
                &connection.host,
                connection.port,
                &connection.database_name,
                &connection.username,
                enc_password,
                &connection.sqlite_path,
                &connection.ssl_mode,
                &connection.updated_at,
                id,
            ],
        )?;
        drop(conn);
        Self::get_connection(db, id)
    }

    pub fn delete_connection(db: &Database, id: &str) -> Result<()> {
        let conn = db.conn.lock().unwrap();
        conn.execute("DELETE FROM database_connections WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn add_backup_record(
        db: &Database,
        input: &DatabaseBackupRecordInput,
    ) -> Result<DatabaseBackupRecord> {
        let record = DatabaseBackupRecord {
            id: uuid::Uuid::new_v4().to_string(),
            connection_id: input.connection_id.clone(),
            connection_name: input.connection_name.clone(),
            engine: input.engine.clone(),
            artifact_path: input.artifact_path.clone(),
            operation: input.operation.clone(),
            status: input.status.clone(),
            summary: input.summary.clone(),
            created_at: chrono::Utc::now().to_rfc3339(),
        };
        let conn = db.conn.lock().unwrap();
        conn.execute(
            &format!(
                "INSERT INTO database_backup_records ({}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                Self::BACKUP_RECORD_COLUMNS
            ),
            params![
                &record.id,
                &record.connection_id,
                &record.connection_name,
                &record.engine,
                &record.artifact_path,
                &record.operation,
                &record.status,
                &record.summary,
                &record.created_at,
            ],
        )?;
        Ok(record)
    }

    pub fn list_backup_records(db: &Database) -> Result<Vec<DatabaseBackupRecord>> {
        let conn = db.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM database_backup_records ORDER BY created_at DESC, rowid DESC",
            Self::BACKUP_RECORD_COLUMNS
        ))?;
        let records = stmt
            .query_map([], Self::row_to_backup_record)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(records)
    }

    fn connection_from_input(
        id: String,
        created_at: String,
        updated_at: String,
        input: &DatabaseConnectionInput,
    ) -> DatabaseConnection {
        DatabaseConnection {
            id,
            name: input.name.clone(),
            group_name: input.group_name.clone().unwrap_or_default(),
            engine: input.engine.clone(),
            ssh_server_id: input.ssh_server_id.clone().unwrap_or_default(),
            use_ssh_tunnel: input.use_ssh_tunnel.unwrap_or(false),
            host: input.host.clone().unwrap_or_default(),
            port: input.port.unwrap_or(0),
            database_name: input.database_name.clone().unwrap_or_default(),
            username: input.username.clone().unwrap_or_default(),
            password: input.password.clone().unwrap_or_default(),
            sqlite_path: input.sqlite_path.clone().unwrap_or_default(),
            ssl_mode: input.ssl_mode.clone().unwrap_or_default(),
            created_at,
            updated_at,
        }
    }

    fn connection_from_update(
        existing: DatabaseConnection,
        updated_at: String,
        input: &DatabaseConnectionInput,
    ) -> DatabaseConnection {
        DatabaseConnection {
            id: existing.id,
            name: input.name.clone(),
            group_name: input
                .group_name
                .clone()
                .unwrap_or(existing.group_name),
            engine: input.engine.clone(),
            ssh_server_id: input
                .ssh_server_id
                .clone()
                .unwrap_or(existing.ssh_server_id),
            use_ssh_tunnel: input.use_ssh_tunnel.unwrap_or(existing.use_ssh_tunnel),
            host: input.host.clone().unwrap_or(existing.host),
            port: input.port.unwrap_or(existing.port),
            database_name: input
                .database_name
                .clone()
                .unwrap_or(existing.database_name),
            username: input.username.clone().unwrap_or(existing.username),
            password: input.password.clone().unwrap_or(existing.password),
            sqlite_path: input.sqlite_path.clone().unwrap_or(existing.sqlite_path),
            ssl_mode: input.ssl_mode.clone().unwrap_or(existing.ssl_mode),
            created_at: existing.created_at,
            updated_at,
        }
    }

    fn row_to_connection(row: &rusqlite::Row) -> rusqlite::Result<DatabaseConnection> {
        let port: u16 = row.get(7)?;
        let use_ssh_tunnel: i64 = row.get(5)?;
        Ok(DatabaseConnection {
            id: row.get(0)?,
            name: row.get(1)?,
            group_name: row.get(2)?,
            engine: row.get(3)?,
            ssh_server_id: row.get(4)?,
            use_ssh_tunnel: use_ssh_tunnel != 0,
            host: row.get(6)?,
            port,
            database_name: row.get(8)?,
            username: row.get(9)?,
            password: crypto::decrypt(&row.get::<_, String>(10)?),
            sqlite_path: row.get(11)?,
            ssl_mode: row.get(12)?,
            created_at: row.get(13)?,
            updated_at: row.get(14)?,
        })
    }

    fn row_to_backup_record(row: &rusqlite::Row) -> rusqlite::Result<DatabaseBackupRecord> {
        Ok(DatabaseBackupRecord {
            id: row.get(0)?,
            connection_id: row.get(1)?,
            connection_name: row.get(2)?,
            engine: row.get(3)?,
            artifact_path: row.get(4)?,
            operation: row.get(5)?,
            status: row.get(6)?,
            summary: row.get(7)?,
            created_at: row.get(8)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;

    fn test_db() -> Database {
        Database::new(":memory:").expect("in-memory db")
    }

    #[test]
    fn stores_and_decrypts_database_connection_password() {
        let db = test_db();
        let input = DatabaseConnectionInput {
            name: "prod mysql".into(),
            group_name: Some("prod".into()),
            engine: "mysql".into(),
            ssh_server_id: Some("ssh-1".into()),
            use_ssh_tunnel: Some(true),
            host: Some("mysql.internal".into()),
            port: Some(3306),
            database_name: Some("app".into()),
            username: Some("app_user".into()),
            password: Some("secret".into()),
            sqlite_path: None,
            ssl_mode: Some("prefer".into()),
        };

        let saved = DatabaseStore::add_connection(&db, &input).expect("add");
        let encrypted_password: String = {
            let conn = db.conn.lock().unwrap();
            conn.query_row(
                "SELECT password FROM database_connections WHERE id = ?1",
                [&saved.id],
                |row| row.get(0),
            )
            .expect("stored password")
        };
        let loaded = DatabaseStore::get_connection(&db, &saved.id).expect("get");

        assert_eq!(loaded.name, "prod mysql");
        assert_eq!(loaded.engine, "mysql");
        assert_ne!(encrypted_password, "secret");
        assert_eq!(loaded.password, "secret");
        assert!(loaded.use_ssh_tunnel);
    }

    #[test]
    fn backup_records_are_listed_newest_first() {
        let db = test_db();
        DatabaseStore::add_backup_record(
            &db,
            &DatabaseBackupRecordInput {
                connection_id: "c1".into(),
                connection_name: "sqlite".into(),
                engine: "remote_sqlite".into(),
                artifact_path: "/tmp/a.orbit-db-backup.json".into(),
                operation: "backup".into(),
                status: "success".into(),
                summary: "1 table, 2 rows".into(),
            },
        )
        .expect("record");
        DatabaseStore::add_backup_record(
            &db,
            &DatabaseBackupRecordInput {
                connection_id: "c2".into(),
                connection_name: "mysql".into(),
                engine: "mysql".into(),
                artifact_path: "/tmp/b.orbit-db-backup.json".into(),
                operation: "restore".into(),
                status: "failed".into(),
                summary: "permission denied".into(),
            },
        )
        .expect("record");

        let records = DatabaseStore::list_backup_records(&db).expect("records");
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].operation, "restore");
        assert_eq!(records[1].operation, "backup");
    }

    #[test]
    fn update_connection_preserves_omitted_optional_fields() {
        let db = test_db();
        let saved = DatabaseStore::add_connection(
            &db,
            &DatabaseConnectionInput {
                name: "prod mysql".into(),
                group_name: Some("prod".into()),
                engine: "mysql".into(),
                ssh_server_id: Some("ssh-1".into()),
                use_ssh_tunnel: Some(true),
                host: Some("mysql.internal".into()),
                port: Some(3306),
                database_name: Some("app".into()),
                username: Some("app_user".into()),
                password: Some("secret".into()),
                sqlite_path: Some("/tmp/prod.sqlite".into()),
                ssl_mode: Some("prefer".into()),
            },
        )
        .expect("add");

        let updated = DatabaseStore::update_connection(
            &db,
            &saved.id,
            &DatabaseConnectionInput {
                name: "renamed mysql".into(),
                group_name: None,
                engine: "mysql".into(),
                ssh_server_id: None,
                use_ssh_tunnel: None,
                host: None,
                port: None,
                database_name: None,
                username: None,
                password: None,
                sqlite_path: None,
                ssl_mode: None,
            },
        )
        .expect("update");

        assert_eq!(updated.name, "renamed mysql");
        assert_eq!(updated.group_name, "prod");
        assert_eq!(updated.ssh_server_id, "ssh-1");
        assert!(updated.use_ssh_tunnel);
        assert_eq!(updated.host, "mysql.internal");
        assert_eq!(updated.port, 3306);
        assert_eq!(updated.database_name, "app");
        assert_eq!(updated.username, "app_user");
        assert_eq!(updated.password, "secret");
        assert_eq!(updated.sqlite_path, "/tmp/prod.sqlite");
        assert_eq!(updated.ssl_mode, "prefer");
    }
}
