use crate::crypto;
use crate::models::*;
use crate::server_organization::{
    normalize_name, ServerFolder, ServerOrganizationSnapshot, ServerTag, ServerTagLink,
};
use anyhow::Result;
use rusqlite::{Connection, OptionalExtension};
use std::sync::Mutex;
use tracing::{debug, info};

pub struct Database {
    pub conn: Mutex<Connection>,
}

impl Database {
    pub fn new(path: &str) -> Result<Self> {
        let mut conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS servers (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 22,
                group_name TEXT NOT NULL DEFAULT '',
                auth_type TEXT NOT NULL DEFAULT 'password',
                username TEXT NOT NULL,
                password TEXT NOT NULL DEFAULT '',
                private_key TEXT NOT NULL DEFAULT '',
                key_source TEXT NOT NULL DEFAULT 'content',
                key_file_path TEXT NOT NULL DEFAULT '',
                key_passphrase TEXT NOT NULL DEFAULT '',
                credential_group_id TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS credential_groups (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                auth_type TEXT NOT NULL DEFAULT 'password',
                username TEXT NOT NULL,
                password TEXT NOT NULL DEFAULT '',
                private_key TEXT NOT NULL DEFAULT '',
                key_source TEXT NOT NULL DEFAULT 'content',
                key_file_path TEXT NOT NULL DEFAULT '',
                key_passphrase TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS database_connections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                group_name TEXT NOT NULL DEFAULT '',
                engine TEXT NOT NULL,
                ssh_server_id TEXT NOT NULL DEFAULT '',
                use_ssh_tunnel INTEGER NOT NULL DEFAULT 0,
                host TEXT NOT NULL DEFAULT '',
                port INTEGER NOT NULL DEFAULT 0,
                database_name TEXT NOT NULL DEFAULT '',
                username TEXT NOT NULL DEFAULT '',
                password TEXT NOT NULL DEFAULT '',
                sqlite_path TEXT NOT NULL DEFAULT '',
                ssl_mode TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS database_backup_records (
                id TEXT PRIMARY KEY,
                connection_id TEXT NOT NULL,
                connection_name TEXT NOT NULL,
                engine TEXT NOT NULL,
                artifact_path TEXT NOT NULL,
                operation TEXT NOT NULL,
                status TEXT NOT NULL,
                summary TEXT NOT NULL,
                created_at TEXT NOT NULL
            );",
        )?;

        let migrations = [
            "ALTER TABLE servers ADD COLUMN key_source TEXT NOT NULL DEFAULT 'content'",
            "ALTER TABLE servers ADD COLUMN key_file_path TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE servers ADD COLUMN credential_group_id TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE servers ADD COLUMN jump_server_id TEXT NOT NULL DEFAULT ''",
        ];
        for sql in &migrations {
            let _ = conn.execute_batch(sql);
        }

        Self::migrate_server_organization(&mut conn)?;

        let db = Self {
            conn: Mutex::new(conn),
        };
        db.migrate_encrypt()?;
        info!("数据库初始化完成: {}", path);
        Ok(db)
    }

    fn migrate_server_organization(conn: &mut Connection) -> Result<()> {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS server_folders (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                normalized_name TEXT NOT NULL,
                parent_id TEXT REFERENCES server_folders(id) ON DELETE CASCADE,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS server_tags (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                normalized_name TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS server_tag_links (
                server_id TEXT NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
                tag_id TEXT NOT NULL REFERENCES server_tags(id) ON DELETE CASCADE,
                PRIMARY KEY (server_id, tag_id)
            );",
        )?;

        for sql in [
            "ALTER TABLE servers ADD COLUMN folder_id TEXT REFERENCES server_folders(id) ON DELETE SET NULL",
            "ALTER TABLE servers ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE servers ADD COLUMN pin_order INTEGER",
            "ALTER TABLE servers ADD COLUMN last_connected_at TEXT",
            "ALTER TABLE servers ADD COLUMN last_attempted_at TEXT",
            "ALTER TABLE servers ADD COLUMN last_connection_result TEXT CHECK (last_connection_result IN ('success', 'failed'))",
            "ALTER TABLE servers ADD COLUMN last_connection_error TEXT",
        ] {
            if let Err(error) = tx.execute_batch(sql) {
                if !error.to_string().contains("duplicate column name") {
                    return Err(error.into());
                }
            }
        }

        tx.execute_batch(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_server_folders_parent_normalized_name
             ON server_folders (COALESCE(parent_id, ''), normalized_name);",
        )?;

        let legacy_groups: Vec<(String, String)> = {
            let mut stmt =
                tx.prepare("SELECT id, group_name FROM servers WHERE TRIM(group_name) <> ''")?;
            let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };

        for (server_id, group_name) in legacy_groups {
            let name = group_name.trim();
            let normalized_name = normalize_name(name)?;
            let folder_id = tx
                .query_row(
                    "SELECT id FROM server_folders WHERE parent_id IS NULL AND normalized_name = ?1",
                    [&normalized_name],
                    |row| row.get::<_, String>(0),
                )
                .optional()?;
            let folder_id = match folder_id {
                Some(id) => id,
                None => {
                    let id = uuid::Uuid::new_v4().to_string();
                    let now = chrono::Utc::now().to_rfc3339();
                    tx.execute(
                        "INSERT INTO server_folders (id, name, normalized_name, parent_id, sort_order, created_at, updated_at)
                         VALUES (?1, ?2, ?3, NULL, 0, ?4, ?5)",
                        rusqlite::params![id, name, normalized_name, now, now],
                    )?;
                    id
                }
            };
            tx.execute(
                "UPDATE servers SET folder_id = ?1 WHERE id = ?2 AND folder_id IS NULL",
                rusqlite::params![folder_id, server_id],
            )?;
        }

        tx.commit()?;
        Ok(())
    }

    fn migrate_encrypt(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let mut encrypted_count = 0;

        let servers: Vec<(String, String, String, String)> = {
            let mut stmt =
                conn.prepare("SELECT id, password, private_key, key_passphrase FROM servers")?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        for (id, password, private_key, key_passphrase) in &servers {
            let needs_update = !crypto::is_encrypted(password)
                || !crypto::is_encrypted(private_key)
                || !crypto::is_encrypted(key_passphrase);
            if !needs_update {
                continue;
            }
            let enc_pw = if crypto::is_encrypted(password) {
                password.clone()
            } else {
                crypto::encrypt(password)
            };
            let enc_key = if crypto::is_encrypted(private_key) {
                private_key.clone()
            } else {
                crypto::encrypt(private_key)
            };
            let enc_pp = if crypto::is_encrypted(key_passphrase) {
                key_passphrase.clone()
            } else {
                crypto::encrypt(key_passphrase)
            };
            conn.execute(
                "UPDATE servers SET password=?1, private_key=?2, key_passphrase=?3 WHERE id=?4",
                rusqlite::params![enc_pw, enc_key, enc_pp, id],
            )?;
            encrypted_count += 1;
        }

        if encrypted_count > 0 {
            info!(count = encrypted_count, "已加密 servers 表中的明文凭据");
        }

        let groups: Vec<(String, String, String, String)> = {
            let mut stmt = conn.prepare(
                "SELECT id, password, private_key, key_passphrase FROM credential_groups",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        for (id, password, private_key, key_passphrase) in &groups {
            let needs_update = !crypto::is_encrypted(password)
                || !crypto::is_encrypted(private_key)
                || !crypto::is_encrypted(key_passphrase);
            if !needs_update {
                continue;
            }
            let enc_pw = if crypto::is_encrypted(password) {
                password.clone()
            } else {
                crypto::encrypt(password)
            };
            let enc_key = if crypto::is_encrypted(private_key) {
                private_key.clone()
            } else {
                crypto::encrypt(private_key)
            };
            let enc_pp = if crypto::is_encrypted(key_passphrase) {
                key_passphrase.clone()
            } else {
                crypto::encrypt(key_passphrase)
            };
            conn.execute(
                "UPDATE credential_groups SET password=?1, private_key=?2, key_passphrase=?3 WHERE id=?4",
                rusqlite::params![enc_pw, enc_key, enc_pp, id],
            )?;
        }

        if encrypted_count > 0 {
            debug!("凭据加密迁移完成");
        } else {
            debug!("所有凭据已是加密状态");
        }

        let database_connections: Vec<(String, String)> = {
            let mut stmt = conn.prepare("SELECT id, password FROM database_connections")?;
            let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let mut database_password_count = 0;
        for (id, password) in &database_connections {
            if password.is_empty() || crypto::is_encrypted(password) {
                continue;
            }
            let enc_password = crypto::encrypt(password);
            conn.execute(
                "UPDATE database_connections SET password=?1 WHERE id=?2",
                rusqlite::params![enc_password, id],
            )?;
            database_password_count += 1;
        }

        if database_password_count > 0 {
            info!(
                count = database_password_count,
                "已加密 database_connections 表中的明文密码"
            );
        }

        drop(conn);
        Ok(())
    }

    fn row_to_server(row: &rusqlite::Row) -> rusqlite::Result<Server> {
        Ok(Server {
            id: row.get(0)?,
            name: row.get(1)?,
            host: row.get(2)?,
            port: row.get(3)?,
            group_name: row.get(4)?,
            auth_type: row.get(5)?,
            username: row.get(6)?,
            password: crypto::decrypt(&row.get::<_, String>(7)?),
            private_key: crypto::decrypt(&row.get::<_, String>(8)?),
            key_source: row.get(9)?,
            key_file_path: row.get(10)?,
            key_passphrase: crypto::decrypt(&row.get::<_, String>(11)?),
            credential_group_id: row.get(12)?,
            jump_server_id: row.get(13)?,
            folder_id: row.get(14)?,
            is_pinned: row.get(15)?,
            pin_order: row.get(16)?,
            last_connected_at: row.get(17)?,
            last_attempted_at: row.get(18)?,
            last_connection_result: row.get(19)?,
            last_connection_error: row.get(20)?,
            created_at: row.get(21)?,
            updated_at: row.get(22)?,
        })
    }

    const SERVER_COLUMNS: &'static str = "id, name, host, port, group_name, auth_type, username, password, private_key, key_source, key_file_path, key_passphrase, credential_group_id, jump_server_id, folder_id, is_pinned, pin_order, last_connected_at, last_attempted_at, last_connection_result, last_connection_error, created_at, updated_at";

    pub fn list_servers(&self) -> Result<Vec<Server>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM servers ORDER BY group_name, name",
            Self::SERVER_COLUMNS
        ))?;
        let servers = stmt
            .query_map([], |row| Self::row_to_server(row))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(servers)
    }

    pub fn get_server(&self, id: &str) -> Result<Server> {
        let conn = self.conn.lock().unwrap();
        let server = conn.query_row(
            &format!("SELECT {} FROM servers WHERE id = ?1", Self::SERVER_COLUMNS),
            [id],
            |row| Self::row_to_server(row),
        )?;
        Ok(server)
    }

    pub fn add_server(&self, input: &ServerInput) -> Result<Server> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let enc_password = crypto::encrypt(&input.password.clone().unwrap_or_default());
        let enc_private_key = crypto::encrypt(&input.private_key.clone().unwrap_or_default());
        let enc_key_passphrase = crypto::encrypt(&input.key_passphrase.clone().unwrap_or_default());
        let server = Server {
            id: id.clone(),
            name: input.name.clone(),
            host: input.host.clone(),
            port: input.port.unwrap_or(22),
            group_name: input.group_name.clone().unwrap_or_default(),
            auth_type: input.auth_type.clone().unwrap_or_else(|| "password".into()),
            username: input.username.clone(),
            password: input.password.clone().unwrap_or_default(),
            private_key: input.private_key.clone().unwrap_or_default(),
            key_source: input.key_source.clone().unwrap_or_else(|| "content".into()),
            key_file_path: input.key_file_path.clone().unwrap_or_default(),
            key_passphrase: input.key_passphrase.clone().unwrap_or_default(),
            credential_group_id: input.credential_group_id.clone().unwrap_or_default(),
            jump_server_id: input.jump_server_id.clone().unwrap_or_default(),
            folder_id: input.folder_id.clone(),
            is_pinned: false,
            pin_order: None,
            last_connected_at: None,
            last_attempted_at: None,
            last_connection_result: None,
            last_connection_error: None,
            created_at: now.clone(),
            updated_at: now,
        };
        let conn = self.conn.lock().unwrap();
        conn.execute(
            &format!(
                "INSERT INTO servers ({}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                Self::SERVER_COLUMNS
            ),
            rusqlite::params![
                server.id,
                server.name,
                server.host,
                server.port,
                server.group_name,
                server.auth_type,
                server.username,
                enc_password,
                enc_private_key,
                server.key_source,
                server.key_file_path,
                enc_key_passphrase,
                server.credential_group_id,
                server.jump_server_id,
                server.folder_id,
                server.is_pinned,
                server.pin_order,
                server.last_connected_at,
                server.last_attempted_at,
                server.last_connection_result,
                server.last_connection_error,
                server.created_at,
                server.updated_at,
            ],
        )?;
        Ok(server)
    }

    pub fn update_server(&self, id: &str, input: &ServerInput) -> Result<Server> {
        let now = chrono::Utc::now().to_rfc3339();
        let enc_password = crypto::encrypt(&input.password.as_deref().unwrap_or(""));
        let enc_private_key = crypto::encrypt(&input.private_key.as_deref().unwrap_or(""));
        let enc_key_passphrase = crypto::encrypt(&input.key_passphrase.as_deref().unwrap_or(""));
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE servers SET name=?1,host=?2,port=?3,group_name=?4,auth_type=?5,username=?6,password=?7,private_key=?8,key_source=?9,key_file_path=?10,key_passphrase=?11,credential_group_id=?12,jump_server_id=?13,folder_id=?14,updated_at=?15 WHERE id=?16",
            rusqlite::params![
                input.name, input.host, input.port.unwrap_or(22),
                input.group_name.as_deref().unwrap_or(""),
                input.auth_type.as_deref().unwrap_or("password"),
                input.username,
                enc_password, enc_private_key,
                input.key_source.as_deref().unwrap_or("content"),
                input.key_file_path.as_deref().unwrap_or(""),
                enc_key_passphrase,
                input.credential_group_id.as_deref().unwrap_or(""),
                input.jump_server_id.as_deref().unwrap_or(""),
                input.folder_id,
                now, id,
            ],
        )?;
        drop(conn);
        self.get_server(id)
    }

    pub fn delete_server(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM servers WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn server_organization(&self) -> Result<ServerOrganizationSnapshot> {
        let conn = self.conn.lock().unwrap();
        let folders = {
            let mut stmt = conn.prepare(
                "SELECT id, name, normalized_name, parent_id, sort_order, created_at, updated_at
                 FROM server_folders ORDER BY parent_id, sort_order, name",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok(ServerFolder {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    normalized_name: row.get(2)?,
                    parent_id: row.get(3)?,
                    sort_order: row.get(4)?,
                    created_at: row.get(5)?,
                    updated_at: row.get(6)?,
                })
            })?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        let tags = {
            let mut stmt = conn.prepare(
                "SELECT id, name, normalized_name, created_at, updated_at
                 FROM server_tags ORDER BY name",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok(ServerTag {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    normalized_name: row.get(2)?,
                    created_at: row.get(3)?,
                    updated_at: row.get(4)?,
                })
            })?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        let tag_links = {
            let mut stmt = conn.prepare(
                "SELECT server_id, tag_id FROM server_tag_links ORDER BY server_id, tag_id",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok(ServerTagLink {
                    server_id: row.get(0)?,
                    tag_id: row.get(1)?,
                })
            })?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        Ok(ServerOrganizationSnapshot {
            folders,
            tags,
            tag_links,
        })
    }

    fn row_to_credential_group(row: &rusqlite::Row) -> rusqlite::Result<CredentialGroup> {
        Ok(CredentialGroup {
            id: row.get(0)?,
            name: row.get(1)?,
            auth_type: row.get(2)?,
            username: row.get(3)?,
            password: crypto::decrypt(&row.get::<_, String>(4)?),
            private_key: crypto::decrypt(&row.get::<_, String>(5)?),
            key_source: row.get(6)?,
            key_file_path: row.get(7)?,
            key_passphrase: crypto::decrypt(&row.get::<_, String>(8)?),
            created_at: row.get(9)?,
            updated_at: row.get(10)?,
        })
    }

    const CG_COLUMNS: &'static str = "id, name, auth_type, username, password, private_key, key_source, key_file_path, key_passphrase, created_at, updated_at";

    pub fn list_credential_groups(&self) -> Result<Vec<CredentialGroup>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM credential_groups ORDER BY name",
            Self::CG_COLUMNS
        ))?;
        let groups = stmt
            .query_map([], |row| Self::row_to_credential_group(row))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(groups)
    }

    pub fn get_credential_group(&self, id: &str) -> Result<CredentialGroup> {
        let conn = self.conn.lock().unwrap();
        let group = conn.query_row(
            &format!(
                "SELECT {} FROM credential_groups WHERE id = ?1",
                Self::CG_COLUMNS
            ),
            [id],
            |row| Self::row_to_credential_group(row),
        )?;
        Ok(group)
    }

    pub fn add_credential_group(&self, input: &CredentialGroupInput) -> Result<CredentialGroup> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let enc_password = crypto::encrypt(&input.password.clone().unwrap_or_default());
        let enc_private_key = crypto::encrypt(&input.private_key.clone().unwrap_or_default());
        let enc_key_passphrase = crypto::encrypt(&input.key_passphrase.clone().unwrap_or_default());
        let group = CredentialGroup {
            id,
            name: input.name.clone(),
            auth_type: input.auth_type.clone().unwrap_or_else(|| "password".into()),
            username: input.username.clone(),
            password: input.password.clone().unwrap_or_default(),
            private_key: input.private_key.clone().unwrap_or_default(),
            key_source: input.key_source.clone().unwrap_or_else(|| "content".into()),
            key_file_path: input.key_file_path.clone().unwrap_or_default(),
            key_passphrase: input.key_passphrase.clone().unwrap_or_default(),
            created_at: now,
            updated_at: chrono::Utc::now().to_rfc3339(),
        };
        let conn = self.conn.lock().unwrap();
        conn.execute(
            &format!(
                "INSERT INTO credential_groups ({}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                Self::CG_COLUMNS
            ),
            rusqlite::params![
                &group.id,
                &group.name,
                &group.auth_type,
                &group.username,
                enc_password,
                enc_private_key,
                &group.key_source,
                &group.key_file_path,
                enc_key_passphrase,
                &group.created_at,
                &group.updated_at,
            ],
        )?;
        Ok(group)
    }

    pub fn update_credential_group(
        &self,
        id: &str,
        input: &CredentialGroupInput,
    ) -> Result<CredentialGroup> {
        let now = chrono::Utc::now().to_rfc3339();
        let enc_password = crypto::encrypt(&input.password.as_deref().unwrap_or(""));
        let enc_private_key = crypto::encrypt(&input.private_key.as_deref().unwrap_or(""));
        let enc_key_passphrase = crypto::encrypt(&input.key_passphrase.as_deref().unwrap_or(""));
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE credential_groups SET name=?1,auth_type=?2,username=?3,password=?4,private_key=?5,key_source=?6,key_file_path=?7,key_passphrase=?8,updated_at=?9 WHERE id=?10",
            rusqlite::params![
                &input.name,
                input.auth_type.as_deref().unwrap_or("password"),
                &input.username,
                enc_password, enc_private_key,
                input.key_source.as_deref().unwrap_or("content"),
                input.key_file_path.as_deref().unwrap_or(""),
                enc_key_passphrase,
                &now, id,
            ],
        )?;
        drop(conn);
        self.get_credential_group(id)
    }

    pub fn delete_credential_group(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM credential_groups WHERE id = ?1", [id])?;
        conn.execute(
            "UPDATE servers SET credential_group_id = '' WHERE credential_group_id = ?1",
            [id],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod server_organization_tests {
    use super::Database;
    use crate::crypto;
    use rusqlite::{params, Connection};

    fn create_legacy_database(
        path: &std::path::Path,
        id: &str,
        group_name: &str,
        host: &str,
        jump_server_id: &str,
    ) {
        let conn = Connection::open(path).unwrap();
        conn.execute_batch(
            "CREATE TABLE servers (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 22,
                group_name TEXT NOT NULL DEFAULT '',
                auth_type TEXT NOT NULL DEFAULT 'password',
                username TEXT NOT NULL,
                password TEXT NOT NULL DEFAULT '',
                private_key TEXT NOT NULL DEFAULT '',
                key_source TEXT NOT NULL DEFAULT 'content',
                key_file_path TEXT NOT NULL DEFAULT '',
                key_passphrase TEXT NOT NULL DEFAULT '',
                credential_group_id TEXT NOT NULL DEFAULT '',
                jump_server_id TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO servers (id, name, host, port, group_name, auth_type, username, password, private_key, key_source, key_file_path, key_passphrase, credential_group_id, jump_server_id, created_at, updated_at)
             VALUES (?1, 'legacy', ?2, 22, ?3, 'password', 'root', ?4, ?5, 'content', '', ?6, '', ?7, '2026-08-07T00:00:00Z', '2026-08-07T00:00:00Z')",
            params![
                id,
                host,
                group_name,
                crypto::encrypt(""),
                crypto::encrypt(""),
                crypto::encrypt(""),
                jump_server_id,
            ],
        )
        .unwrap();
    }

    #[test]
    fn legacy_groups_migrate_once_without_touching_connection_fields() {
        let path =
            std::env::temp_dir().join(format!("orbit-migration-{}.db", uuid::Uuid::new_v4()));
        create_legacy_database(&path, "s1", "Prod", "10.0.0.1", "jump-1");
        let db = Database::new(path.to_str().unwrap()).unwrap();
        let snapshot = db.server_organization().unwrap();
        let server = db.get_server("s1").unwrap();
        assert_eq!(snapshot.folders.len(), 1);
        assert_eq!(server.host, "10.0.0.1");
        assert_eq!(server.jump_server_id, "jump-1");
        assert_eq!(
            server.folder_id.as_deref(),
            Some(snapshot.folders[0].id.as_str())
        );
        drop(db);
        let reopened = Database::new(path.to_str().unwrap()).unwrap();
        assert_eq!(reopened.server_organization().unwrap().folders.len(), 1);
        drop(reopened);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn server_organization_migration_rolls_back_when_schema_creation_fails() {
        let path = std::env::temp_dir().join(format!(
            "orbit-migration-rollback-{}.db",
            uuid::Uuid::new_v4()
        ));
        create_legacy_database(&path, "s1", "Prod", "10.0.0.1", "jump-1");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch("CREATE TABLE server_folders (id TEXT PRIMARY KEY);")
            .unwrap();
        drop(conn);

        assert!(Database::new(path.to_str().unwrap()).is_err());

        let conn = Connection::open(&path).unwrap();
        let columns = {
            let mut stmt = conn.prepare("PRAGMA table_info(servers)").unwrap();
            let rows = stmt.query_map([], |row| row.get::<_, String>(1)).unwrap();
            rows.collect::<std::result::Result<Vec<_>, _>>().unwrap()
        };
        assert!(!columns.iter().any(|column| column == "folder_id"));
        let tables = {
            let mut stmt = conn
                .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .unwrap();
            let rows = stmt.query_map([], |row| row.get::<_, String>(0)).unwrap();
            rows.collect::<std::result::Result<Vec<_>, _>>().unwrap()
        };
        assert!(!tables.iter().any(|table| table == "server_tags"));
        assert!(!tables.iter().any(|table| table == "server_tag_links"));
        drop(conn);
        std::fs::remove_file(path).unwrap();
    }
}
