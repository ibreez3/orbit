use crate::crypto;
use crate::models::*;
use crate::server_organization::{
    normalize_name, FolderInput, ServerFolder, ServerOrganizationSnapshot, ServerTag, ServerTagLink,
};
use anyhow::{anyhow, bail, Result};
use rusqlite::{params_from_iter, Connection, OptionalExtension, ToSql, Transaction};
use std::collections::HashSet;
use std::sync::Mutex;
use tracing::info;

pub struct Database {
    pub conn: Mutex<Connection>,
    pub cipher: crypto::CredentialCipher,
    pub host_keys: crate::host_key::HostKeyVerifier,
}

impl Database {
    pub fn new(path: &str) -> Result<Self> {
        let mut conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS credential_vault (id INTEGER PRIMARY KEY CHECK(id = 1), verification TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS ssh_known_hosts (
                host TEXT NOT NULL,
                port INTEGER NOT NULL,
                public_key BLOB NOT NULL,
                PRIMARY KEY (host, port)
            );
            CREATE TABLE IF NOT EXISTS servers (
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

        let required: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM servers WHERE password LIKE 'ORB2:%' OR private_key LIKE 'ORB2:%' OR key_passphrase LIKE 'ORB2:%' UNION ALL SELECT 1 FROM credential_groups WHERE password LIKE 'ORB2:%' OR private_key LIKE 'ORB2:%' OR key_passphrase LIKE 'ORB2:%' UNION ALL SELECT 1 FROM database_connections WHERE password LIKE 'ORB2:%' UNION ALL SELECT 1 FROM credential_vault)", [], |row| row.get(0))?;
        #[cfg(test)]
        let key = { let _ = required; [42u8; 32] };
        #[cfg(not(test))]
        let key = crypto::load_key(&crypto::MacKeychain { account: "master-key".to_string() }, required)?;
        let db = Self {
            cipher: crypto::CredentialCipher::new(key),
            conn: Mutex::new(conn),
            host_keys: crate::host_key::HostKeyVerifier::default(),
        };
        db.migrate_encrypt()?;
        info!("数据库初始化完成: {}", path);
        Ok(db)
    }

    fn migrate_server_organization(conn: &mut Connection) -> Result<()> {
        let needs_legacy_group_migration = {
            let mut stmt = conn.prepare("PRAGMA table_info(servers)")?;
            let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
            let columns = rows.collect::<std::result::Result<Vec<_>, _>>()?;
            !columns.iter().any(|column| column == "folder_id")
        };
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

        if needs_legacy_group_migration {
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
        }

        tx.commit()?;
        Ok(())
    }

    pub(crate) fn migrate_encrypt(&self) -> Result<()> {
        let conn = self.conn.lock().map_err(|_| anyhow!("数据库锁定失败"))?;
        let tx = conn.unchecked_transaction()?;
        let verification: Option<String> = tx.query_row("SELECT verification FROM credential_vault WHERE id = 1", [], |row| row.get(0)).optional()?;
        if let Some(verification) = verification {
            if self.cipher.decrypt(&verification)? != "orbit-vault-v2" { bail!("凭据密钥校验失败"); }
        }
        for (table, fields) in [
            ("servers", &["password", "private_key", "key_passphrase"][..]),
            ("credential_groups", &["password", "private_key", "key_passphrase"][..]),
            ("database_connections", &["password"][..]),
        ] {
            for field in fields {
                let entries: Vec<(String, String)> = {
                    let mut statement = tx.prepare(&format!("SELECT id, {field} FROM {table}"))?;
                    let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
                    rows.collect::<rusqlite::Result<_>>()?
                };
                for (id, original) in entries {
                    let migrated = self.cipher.migrate(&original)?;
                    if migrated != original {
                        tx.execute(&format!("UPDATE {table} SET {field} = ?1 WHERE id = ?2"), rusqlite::params![migrated, id])?;
                    }
                }
            }
        }
        tx.execute("INSERT OR IGNORE INTO credential_vault (id, verification) VALUES (1, ?1)", [self.cipher.encrypt("orbit-vault-v2")?])?;
        tx.commit()?;
        Ok(())
    }

    fn row_to_server(&self, row: &rusqlite::Row) -> rusqlite::Result<Server> {
        Ok(Server {
            id: row.get(0)?,
            name: row.get(1)?,
            host: row.get(2)?,
            port: row.get(3)?,
            group_name: row.get(4)?,
            auth_type: row.get(5)?,
            username: row.get(6)?,
            password: self.cipher.decrypt(&row.get::<_, String>(7)?)?,
            private_key: self.cipher.decrypt(&row.get::<_, String>(8)?)?,
            key_source: row.get(9)?,
            key_file_path: row.get(10)?,
            key_passphrase: self.cipher.decrypt(&row.get::<_, String>(11)?)?,
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
            .query_map([], |row| self.row_to_server(row))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(servers)
    }

    pub fn get_server(&self, id: &str) -> Result<Server> {
        let conn = self.conn.lock().unwrap();
        let server = conn.query_row(
            &format!("SELECT {} FROM servers WHERE id = ?1", Self::SERVER_COLUMNS),
            [id],
            |row| self.row_to_server(row),
        )?;
        Ok(server)
    }

    pub fn mark_connection_attempt(&self, id: &str) -> Result<()> {
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self
            .conn
            .lock()
            .map_err(|_| anyhow!("数据库连接锁已损坏"))?;
        if conn.execute(
            "UPDATE servers SET last_attempted_at = ?1, updated_at = ?1 WHERE id = ?2",
            rusqlite::params![now, id],
        )? == 0
        {
            bail!("服务器不存在");
        }
        Ok(())
    }

    pub fn mark_connection_success(&self, id: &str) -> Result<()> {
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self
            .conn
            .lock()
            .map_err(|_| anyhow!("数据库连接锁已损坏"))?;
        if conn.execute(
            "UPDATE servers
             SET last_connected_at = ?1, last_connection_result = 'success',
                 last_connection_error = NULL, updated_at = ?1
             WHERE id = ?2",
            rusqlite::params![now, id],
        )? == 0
        {
            bail!("服务器不存在");
        }
        Ok(())
    }

    pub fn mark_connection_failure(&self, id: &str, error: &str) -> Result<()> {
        let now = chrono::Utc::now().to_rfc3339();
        let error = sanitize_connection_error(error);
        let conn = self
            .conn
            .lock()
            .map_err(|_| anyhow!("数据库连接锁已损坏"))?;
        if conn.execute(
            "UPDATE servers
             SET last_connection_result = 'failed', last_connection_error = ?1,
                 updated_at = ?2
             WHERE id = ?3",
            rusqlite::params![error, now, id],
        )? == 0
        {
            bail!("服务器不存在");
        }
        Ok(())
    }

    pub fn add_server(&self, input: &ServerInput) -> Result<Server> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let enc_password = self.cipher.encrypt(&input.password.clone().unwrap_or_default())?;
        let enc_private_key = self.cipher.encrypt(&input.private_key.clone().unwrap_or_default())?;
        let enc_key_passphrase = self.cipher.encrypt(&input.key_passphrase.clone().unwrap_or_default())?;
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

    pub fn validate_temporary_connection(&self, input: &TemporaryConnectionInput) -> Result<()> {
        input.validate()?;
        let conn = self
            .conn
            .lock()
            .map_err(|_| anyhow!("数据库连接锁已损坏"))?;
        validate_temporary_references(&conn, input)
    }

    pub fn promote_temporary_server(
        &self,
        descriptor: &crate::ssh::TemporarySessionDescriptor,
        input: &PromoteTemporaryServerInput,
    ) -> Result<Server> {
        input.validate()?;
        if !descriptor.matches(&input.connection) {
            bail!("保存请求与当前临时会话不匹配");
        }

        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let enc_password = self.cipher.encrypt(&input.connection.password.clone().unwrap_or_default())?;
        let enc_private_key =
            self.cipher.encrypt(&input.connection.private_key.clone().unwrap_or_default())?;
        let enc_key_passphrase =
            self.cipher.encrypt(&input.connection.key_passphrase.clone().unwrap_or_default())?;
        let mut server = input.connection.to_temporary_server(id);
        server.name = input.name.trim().into();
        server.folder_id = input
            .folder_id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_owned);
        server.last_connected_at = Some(now.clone());
        server.last_attempted_at = Some(now.clone());
        server.last_connection_result = Some("success".into());
        server.updated_at = now;

        let mut conn = self
            .conn
            .lock()
            .map_err(|_| anyhow!("数据库连接锁已损坏"))?;
        let tx = conn.transaction()?;
        validate_temporary_references(&tx, &input.connection)?;
        if let Some(folder_id) = server.folder_id.as_deref() {
            folder_by_id(&tx, folder_id)?;
        }
        let mut seen = HashSet::new();
        for tag_id in &input.tag_ids {
            if !seen.insert(tag_id) {
                bail!("标签不能重复");
            }
            tag_by_id(&tx, tag_id)?;
        }

        tx.execute(
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
        for tag_id in &input.tag_ids {
            tx.execute(
                "INSERT INTO server_tag_links (server_id, tag_id) VALUES (?1, ?2)",
                rusqlite::params![server.id, tag_id],
            )?;
        }
        tx.commit()?;
        Ok(server)
    }

    pub fn update_server(&self, id: &str, input: &ServerInput) -> Result<Server> {
        let now = chrono::Utc::now().to_rfc3339();
        let enc_password = input.password.as_deref().map(|value| self.cipher.encrypt(value)).transpose()?;
        let enc_private_key = input.private_key.as_deref().map(|value| self.cipher.encrypt(value)).transpose()?;
        let enc_key_passphrase = input.key_passphrase.as_deref().map(|value| self.cipher.encrypt(value)).transpose()?;
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE servers SET name=?1,host=?2,port=?3,group_name=COALESCE(?4, group_name),auth_type=?5,username=?6,password=COALESCE(?7, password),private_key=COALESCE(?8, private_key),key_source=?9,key_file_path=?10,key_passphrase=COALESCE(?11, key_passphrase),credential_group_id=?12,jump_server_id=?13,folder_id=COALESCE(?14, folder_id),updated_at=?15 WHERE id=?16",
            rusqlite::params![
                input.name, input.host, input.port.unwrap_or(22),
                input.group_name.as_deref(),
                input.auth_type.as_deref().unwrap_or("password"),
                input.username,
                enc_password, enc_private_key,
                input.key_source.as_deref().unwrap_or("content"),
                input.key_file_path.as_deref().unwrap_or(""),
                enc_key_passphrase,
                input.credential_group_id.as_deref().unwrap_or(""),
                input.jump_server_id.as_deref().unwrap_or(""),
                input.folder_id.as_deref(),
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

    pub fn create_server_folder(&self, input: &FolderInput) -> Result<ServerFolder> {
        let normalized_name = normalize_name(&input.name)?;
        let name = input.name.trim();
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let parent_depth = folder_ancestors(&tx, input.parent_id.as_deref())?.len();
        if parent_depth + 1 > 3 {
            bail!("文件夹最多支持三层");
        }
        ensure_folder_name_available(&tx, input.parent_id.as_deref(), &normalized_name, None)?;
        let sort_order = input.sort_order.unwrap_or(0);
        tx.execute(
            "INSERT INTO server_folders (id, name, normalized_name, parent_id, sort_order, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                id,
                name,
                normalized_name,
                input.parent_id,
                sort_order,
                now,
                now,
            ],
        )?;
        let folder = folder_by_id(&tx, &id)?;
        tx.commit()?;
        Ok(folder)
    }

    pub fn rename_server_folder(&self, id: &str, input: &FolderInput) -> Result<ServerFolder> {
        let normalized_name = normalize_name(&input.name)?;
        let name = input.name.trim();
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let folder = folder_by_id(&tx, id)?;
        ensure_folder_name_available(&tx, folder.parent_id.as_deref(), &normalized_name, Some(id))?;
        tx.execute(
            "UPDATE server_folders SET name = ?1, normalized_name = ?2, updated_at = ?3 WHERE id = ?4",
            rusqlite::params![name, normalized_name, now, id],
        )?;
        let folder = folder_by_id(&tx, id)?;
        tx.commit()?;
        Ok(folder)
    }

    pub fn move_server_folder(
        &self,
        id: &str,
        parent_id: Option<&str>,
        sort_order: i64,
    ) -> Result<ServerFolder> {
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let folder = folder_by_id(&tx, id)?;
        let descendants = folder_subtree(&tx, id)?;
        let descendant_max_depth = descendants
            .iter()
            .map(|(_, depth)| *depth)
            .max()
            .unwrap_or(0);
        let parent_depth = folder_ancestors(&tx, parent_id)?;
        if parent_depth.iter().any(|ancestor| ancestor.id == id) {
            bail!("不能将文件夹移动到自身或其子文件夹");
        }
        if parent_depth.len() + 1 + descendant_max_depth > 3 {
            bail!("移动后文件夹层级不能超过三层");
        }
        ensure_folder_name_available(&tx, parent_id, &folder.normalized_name, Some(id))?;
        tx.execute(
            "UPDATE server_folders SET parent_id = ?1, sort_order = ?2, updated_at = ?3 WHERE id = ?4",
            rusqlite::params![parent_id, sort_order, now, id],
        )?;
        let folder = folder_by_id(&tx, id)?;
        tx.commit()?;
        Ok(folder)
    }

    pub fn delete_server_folder(
        &self,
        id: &str,
        destination_folder_id: Option<&str>,
        delete_servers: bool,
    ) -> Result<()> {
        if destination_folder_id.is_some() && delete_servers {
            bail!("删除文件夹时只能选择移动服务器或删除服务器");
        }
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        folder_by_id(&tx, id)?;
        let subtree = folder_subtree(&tx, id)?;
        let folder_ids: Vec<String> = subtree
            .into_iter()
            .map(|(folder_id, _)| folder_id)
            .collect();
        if let Some(destination) = destination_folder_id {
            if folder_ids.iter().any(|folder_id| folder_id == destination) {
                bail!("不能将服务器移动到正在删除的文件夹中");
            }
            folder_by_id(&tx, destination)?;
        }

        let placeholders = placeholders(folder_ids.len());
        let server_count: i64 = tx.query_row(
            &format!(
                "SELECT COUNT(*) FROM servers WHERE folder_id IN ({})",
                placeholders
            ),
            params_from_iter(folder_ids.iter()),
            |row| row.get(0),
        )?;
        if (server_count > 0 || folder_ids.len() > 1)
            && destination_folder_id.is_none()
            && !delete_servers
        {
            bail!("非空文件夹必须选择移动服务器或删除服务器");
        }

        if let Some(destination) = destination_folder_id {
            let mut values: Vec<&dyn ToSql> = vec![&destination];
            values.extend(folder_ids.iter().map(|folder_id| folder_id as &dyn ToSql));
            tx.execute(
                &format!(
                    "UPDATE servers SET folder_id = ?1 WHERE folder_id IN ({})",
                    placeholders
                ),
                params_from_iter(values),
            )?;
        } else if delete_servers {
            tx.execute(
                &format!(
                    "DELETE FROM server_tag_links WHERE server_id IN (SELECT id FROM servers WHERE folder_id IN ({}))",
                    placeholders
                ),
                params_from_iter(folder_ids.iter()),
            )?;
            tx.execute(
                &format!("DELETE FROM servers WHERE folder_id IN ({})", placeholders),
                params_from_iter(folder_ids.iter()),
            )?;
        }

        for folder_id in folder_ids.iter().rev() {
            tx.execute("DELETE FROM server_folders WHERE id = ?1", [folder_id])?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn create_server_tag(&self, name: &str) -> Result<ServerTag> {
        let normalized_name = normalize_name(name)?;
        let name = name.trim();
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let existing: Option<String> = tx
            .query_row(
                "SELECT id FROM server_tags WHERE normalized_name = ?1",
                [&normalized_name],
                |row| row.get(0),
            )
            .optional()?;
        if existing.is_some() {
            bail!("标签名称已存在");
        }
        tx.execute(
            "INSERT INTO server_tags (id, name, normalized_name, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![id, name, normalized_name, now, now],
        )?;
        let tag = tag_by_id(&tx, &id)?;
        tx.commit()?;
        Ok(tag)
    }

    pub fn delete_server_tag(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        if conn.execute("DELETE FROM server_tags WHERE id = ?1", [id])? == 0 {
            bail!("标签不存在");
        }
        Ok(())
    }

    pub fn set_server_tags(&self, server_id: &str, tag_ids: &[String]) -> Result<()> {
        let mut seen = HashSet::new();
        if tag_ids.iter().any(|tag_id| !seen.insert(tag_id)) {
            bail!("标签不能重复");
        }
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        server_exists(&tx, server_id)?;
        for tag_id in tag_ids {
            tag_by_id(&tx, tag_id)?;
        }
        tx.execute(
            "DELETE FROM server_tag_links WHERE server_id = ?1",
            [server_id],
        )?;
        for tag_id in tag_ids {
            tx.execute(
                "INSERT INTO server_tag_links (server_id, tag_id) VALUES (?1, ?2)",
                rusqlite::params![server_id, tag_id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn server_tag_ids(&self, server_id: &str) -> Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT tag_id FROM server_tag_links WHERE server_id = ?1 ORDER BY tag_id")?;
        let rows = stmt.query_map([server_id], |row| row.get(0))?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn move_server(&self, server_id: &str, folder_id: Option<&str>) -> Result<()> {
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        if let Some(folder_id) = folder_id {
            let exists: Option<String> = conn
                .query_row(
                    "SELECT id FROM server_folders WHERE id = ?1",
                    [folder_id],
                    |row| row.get(0),
                )
                .optional()?;
            if exists.is_none() {
                bail!("文件夹不存在");
            }
        }
        if conn.execute(
            "UPDATE servers SET folder_id = ?1, updated_at = ?2 WHERE id = ?3",
            rusqlite::params![folder_id, now, server_id],
        )? == 0
        {
            bail!("服务器不存在");
        }
        Ok(())
    }

    pub fn set_server_pin(
        &self,
        server_id: &str,
        is_pinned: bool,
        pin_order: Option<i64>,
    ) -> Result<Server> {
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        server_exists(&tx, server_id)?;
        let pin_order = if is_pinned {
            match pin_order {
                Some(pin_order) => Some(pin_order),
                None => Some(tx.query_row(
                    "SELECT COALESCE(MAX(pin_order), 0) + 1 FROM servers WHERE is_pinned = 1",
                    [],
                    |row| row.get(0),
                )?),
            }
        } else {
            None
        };
        tx.execute(
            "UPDATE servers SET is_pinned = ?1, pin_order = ?2, updated_at = ?3 WHERE id = ?4",
            rusqlite::params![is_pinned, pin_order, now, server_id],
        )?;
        let server = tx.query_row(
            &format!("SELECT {} FROM servers WHERE id = ?1", Self::SERVER_COLUMNS),
            [server_id],
            |row| self.row_to_server(row),
        )?;
        tx.commit()?;
        Ok(server)
    }

    fn row_to_credential_group(&self, row: &rusqlite::Row) -> rusqlite::Result<CredentialGroup> {
        Ok(CredentialGroup {
            id: row.get(0)?,
            name: row.get(1)?,
            auth_type: row.get(2)?,
            username: row.get(3)?,
            password: self.cipher.decrypt(&row.get::<_, String>(4)?)?,
            private_key: self.cipher.decrypt(&row.get::<_, String>(5)?)?,
            key_source: row.get(6)?,
            key_file_path: row.get(7)?,
            key_passphrase: self.cipher.decrypt(&row.get::<_, String>(8)?)?,
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
            .query_map([], |row| self.row_to_credential_group(row))?
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
            |row| self.row_to_credential_group(row),
        )?;
        Ok(group)
    }

    pub fn add_credential_group(&self, input: &CredentialGroupInput) -> Result<CredentialGroup> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let enc_password = self.cipher.encrypt(&input.password.clone().unwrap_or_default())?;
        let enc_private_key = self.cipher.encrypt(&input.private_key.clone().unwrap_or_default())?;
        let enc_key_passphrase = self.cipher.encrypt(&input.key_passphrase.clone().unwrap_or_default())?;
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
        let enc_password = self.cipher.encrypt(&input.password.as_deref().unwrap_or(""))?;
        let enc_private_key = self.cipher.encrypt(&input.private_key.as_deref().unwrap_or(""))?;
        let enc_key_passphrase = self.cipher.encrypt(&input.key_passphrase.as_deref().unwrap_or(""))?;
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

fn validate_temporary_references(
    conn: &Connection,
    input: &TemporaryConnectionInput,
) -> Result<()> {
    if let Some(credential_group_id) = input.credential_group_id() {
        let exists: Option<String> = conn
            .query_row(
                "SELECT id FROM credential_groups WHERE id = ?1",
                [credential_group_id],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_none() {
            bail!("凭据组不存在");
        }
    }
    if let Some(jump_server_id) = input.jump_server_id() {
        let exists: Option<String> = conn
            .query_row(
                "SELECT id FROM servers WHERE id = ?1",
                [jump_server_id],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_none() {
            bail!("跳板机服务器不存在");
        }
    }
    Ok(())
}

pub(crate) fn sanitize_connection_error(error: &str) -> String {
    let normalized = error.to_ascii_lowercase();
    if normalized.contains("password")
        || normalized.contains("private key")
        || normalized.contains("privatekey")
        || normalized.contains("private_key")
        || normalized.contains("private-key")
        || normalized.contains("passphrase")
        || error.contains('{')
        || error.contains('}')
    {
        return "SSH 连接失败（敏感详情已隐藏）".into();
    }

    let mut summary = error.chars().take(512).collect::<String>();
    if summary.is_empty() {
        summary = "SSH 连接失败".into();
    }
    summary
}

fn folder_by_id(tx: &Transaction<'_>, id: &str) -> Result<ServerFolder> {
    tx.query_row(
        "SELECT id, name, normalized_name, parent_id, sort_order, created_at, updated_at
         FROM server_folders WHERE id = ?1",
        [id],
        |row| {
            Ok(ServerFolder {
                id: row.get(0)?,
                name: row.get(1)?,
                normalized_name: row.get(2)?,
                parent_id: row.get(3)?,
                sort_order: row.get(4)?,
                created_at: row.get(5)?,
                updated_at: row.get(6)?,
            })
        },
    )
    .optional()?
    .ok_or_else(|| anyhow!("文件夹不存在"))
}

fn tag_by_id(tx: &Transaction<'_>, id: &str) -> Result<ServerTag> {
    tx.query_row(
        "SELECT id, name, normalized_name, created_at, updated_at FROM server_tags WHERE id = ?1",
        [id],
        |row| {
            Ok(ServerTag {
                id: row.get(0)?,
                name: row.get(1)?,
                normalized_name: row.get(2)?,
                created_at: row.get(3)?,
                updated_at: row.get(4)?,
            })
        },
    )
    .optional()?
    .ok_or_else(|| anyhow!("标签不存在"))
}

fn server_exists(tx: &Transaction<'_>, id: &str) -> Result<()> {
    let server_id: Option<String> = tx
        .query_row("SELECT id FROM servers WHERE id = ?1", [id], |row| {
            row.get(0)
        })
        .optional()?;
    if server_id.is_none() {
        bail!("服务器不存在");
    }
    Ok(())
}

fn folder_ancestors(tx: &Transaction<'_>, parent_id: Option<&str>) -> Result<Vec<ServerFolder>> {
    let mut ancestors = Vec::new();
    let mut seen = HashSet::new();
    let mut current_id = parent_id.map(str::to_owned);
    while let Some(id) = current_id {
        if !seen.insert(id.clone()) {
            bail!("文件夹层级存在循环");
        }
        let folder = folder_by_id(tx, &id)?;
        current_id = folder.parent_id.clone();
        ancestors.push(folder);
    }
    Ok(ancestors)
}

fn folder_subtree(tx: &Transaction<'_>, root_id: &str) -> Result<Vec<(String, usize)>> {
    let mut folders = Vec::new();
    let mut pending = vec![(root_id.to_owned(), 0)];
    let mut seen = HashSet::new();
    while let Some((folder_id, depth)) = pending.pop() {
        if !seen.insert(folder_id.clone()) {
            bail!("文件夹层级存在循环");
        }
        let children = {
            let mut stmt = tx.prepare("SELECT id FROM server_folders WHERE parent_id = ?1")?;
            let rows = stmt.query_map([&folder_id], |row| row.get::<_, String>(0))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        folders.push((folder_id, depth));
        pending.extend(children.into_iter().map(|child_id| (child_id, depth + 1)));
    }
    Ok(folders)
}

fn ensure_folder_name_available(
    tx: &Transaction<'_>,
    parent_id: Option<&str>,
    normalized_name: &str,
    exclude_id: Option<&str>,
) -> Result<()> {
    let existing: Option<String> = tx
        .query_row(
            "SELECT id FROM server_folders
             WHERE COALESCE(parent_id, '') = COALESCE(?1, '') AND normalized_name = ?2",
            rusqlite::params![parent_id, normalized_name],
            |row| row.get(0),
        )
        .optional()?;
    if existing.as_deref().is_some_and(|id| Some(id) != exclude_id) {
        bail!("同级文件夹名称已存在");
    }
    Ok(())
}

fn placeholders(count: usize) -> String {
    std::iter::repeat("?")
        .take(count)
        .collect::<Vec<_>>()
        .join(",")
}

#[cfg(test)]
mod server_organization_tests {
    use super::Database;
    use crate::models::ServerInput;
    use rusqlite::{params, Connection};
    use std::panic::{catch_unwind, AssertUnwindSafe};

    fn seeded_server_db() -> (Database, String) {
        let db = Database::new(":memory:").unwrap();
        let server = db
            .add_server(&ServerInput {
                name: "server".into(),
                host: "127.0.0.1".into(),
                port: Some(22),
                group_name: None,
                auth_type: Some("password".into()),
                username: "root".into(),
                password: Some("hunter2".into()),
                private_key: Some("PRIVATE_KEY_SECRET".into()),
                key_source: Some("content".into()),
                key_file_path: None,
                key_passphrase: Some("PASSPHRASE_SECRET".into()),
                credential_group_id: None,
                jump_server_id: None,
                folder_id: None,
            })
            .unwrap();
        (db, server.id)
    }

    #[test]
    fn partial_update_preserves_omitted_credentials() {
        let (db, server_id) = seeded_server_db();
        let current = db.get_server(&server_id).unwrap();

        db.update_server(
            &server_id,
            &ServerInput {
                name: "renamed".into(),
                host: current.host.clone(),
                port: Some(current.port),
                group_name: None,
                auth_type: Some(current.auth_type.clone()),
                username: current.username.clone(),
                password: None,
                private_key: None,
                key_source: Some(current.key_source.clone()),
                key_file_path: None,
                key_passphrase: None,
                credential_group_id: None,
                jump_server_id: None,
                folder_id: None,
            },
        )
        .unwrap();

        let updated = db.get_server(&server_id).unwrap();
        assert_eq!(updated.name, "renamed");
        assert_eq!(updated.password, "hunter2");
        assert_eq!(updated.private_key, "PRIVATE_KEY_SECRET");
        assert_eq!(updated.key_passphrase, "PASSPHRASE_SECRET");
    }

    #[test]
    fn connection_failure_is_sanitized_and_success_clears_it() {
        let (db, server_id) = seeded_server_db();

        db.mark_connection_attempt(&server_id).unwrap();
        db.mark_connection_failure(
            &server_id,
            "password=hunter2 private_key=PRIVATE_KEY_SECRET passphrase=PASSPHRASE_SECRET {\"password\":\"hunter2\"}",
        )
        .unwrap();

        let failed = db.get_server(&server_id).unwrap();
        assert!(failed.last_attempted_at.is_some());
        assert_eq!(failed.last_connection_result.as_deref(), Some("failed"));
        let failure = failed.last_connection_error.unwrap();
        let normalized_failure = failure.to_ascii_lowercase();
        assert!(!failure.contains("hunter2"));
        assert!(!failure.contains("PRIVATE_KEY_SECRET"));
        assert!(!failure.contains("PASSPHRASE_SECRET"));
        assert!(!failure.contains("{\"password\""));
        assert!(!normalized_failure.contains("password"));
        assert!(!normalized_failure.contains("private key"));
        assert!(!normalized_failure.contains("passphrase"));

        db.mark_connection_success(&server_id).unwrap();

        let success = db.get_server(&server_id).unwrap();
        assert_eq!(success.last_connection_result.as_deref(), Some("success"));
        assert!(success.last_connected_at.is_some());
        assert_eq!(success.last_connection_error, None);
    }

    fn poison_connection_lock(db: &Database) {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let _guard = db.conn.lock().unwrap();
            panic!("poison database connection lock");
        }));
    }

    #[test]
    fn connection_metadata_writes_return_errors_for_poisoned_locks() {
        let (db, server_id) = seeded_server_db();
        poison_connection_lock(&db);
        let attempt = catch_unwind(AssertUnwindSafe(|| db.mark_connection_attempt(&server_id)));
        assert!(attempt.is_ok());
        assert!(attempt.unwrap().is_err());

        let (db, server_id) = seeded_server_db();
        poison_connection_lock(&db);
        let success = catch_unwind(AssertUnwindSafe(|| db.mark_connection_success(&server_id)));
        assert!(success.is_ok());
        assert!(success.unwrap().is_err());

        let (db, server_id) = seeded_server_db();
        poison_connection_lock(&db);
        let failure = catch_unwind(AssertUnwindSafe(|| {
            db.mark_connection_failure(&server_id, "failed")
        }));
        assert!(failure.is_ok());
        assert!(failure.unwrap().is_err());
    }

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
                String::new(),
                String::new(),
                String::new(),
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
        {
            let conn = db.conn.lock().unwrap();
            conn.execute(
                "DELETE FROM server_folders WHERE id = ?1",
                [&snapshot.folders[0].id],
            )
            .unwrap();
        }
        assert_eq!(db.get_server("s1").unwrap().folder_id, None);
        drop(db);
        let reopened = Database::new(path.to_str().unwrap()).unwrap();
        assert!(reopened.server_organization().unwrap().folders.is_empty());
        assert_eq!(reopened.get_server("s1").unwrap().folder_id, None);
        drop(reopened);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn server_organization_update_preserves_folder_when_input_omits_it() {
        let path = std::env::temp_dir().join(format!(
            "orbit-migration-update-{}.db",
            uuid::Uuid::new_v4()
        ));
        create_legacy_database(&path, "s1", "Prod", "10.0.0.1", "jump-1");
        let db = Database::new(path.to_str().unwrap()).unwrap();
        let folder_id = db.get_server("s1").unwrap().folder_id;

        db.update_server(
            "s1",
            &ServerInput {
                name: "renamed".into(),
                host: "10.0.0.2".into(),
                port: Some(2222),
                group_name: Some("Prod".into()),
                auth_type: Some("password".into()),
                username: "root".into(),
                password: Some("".into()),
                private_key: Some("".into()),
                key_source: Some("content".into()),
                key_file_path: Some("".into()),
                key_passphrase: Some("".into()),
                credential_group_id: Some("".into()),
                jump_server_id: Some("jump-1".into()),
                folder_id: None,
            },
        )
        .unwrap();

        assert_eq!(db.get_server("s1").unwrap().folder_id, folder_id);
        drop(db);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn server_update_preserves_legacy_group_when_input_omits_it() {
        let path = std::env::temp_dir().join(format!(
            "orbit-migration-group-update-{}.db",
            uuid::Uuid::new_v4()
        ));
        create_legacy_database(&path, "s1", "Prod", "10.0.0.1", "jump-1");
        let db = Database::new(path.to_str().unwrap()).unwrap();

        db.update_server(
            "s1",
            &ServerInput {
                name: "renamed".into(),
                host: "10.0.0.2".into(),
                port: Some(2222),
                group_name: None,
                auth_type: Some("password".into()),
                username: "root".into(),
                password: Some("".into()),
                private_key: Some("".into()),
                key_source: Some("content".into()),
                key_file_path: Some("".into()),
                key_passphrase: Some("".into()),
                credential_group_id: Some("".into()),
                jump_server_id: Some("jump-1".into()),
                folder_id: None,
            },
        )
        .unwrap();

        assert_eq!(db.get_server("s1").unwrap().group_name, "Prod");
        drop(db);
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

#[cfg(test)]
mod temporary_connection_tests {
    use super::Database;
    use crate::models::{
        CredentialGroupInput, PromoteTemporaryServerInput, ServerInput, TemporaryConnectionInput,
    };
    use crate::server_organization::FolderInput;
    use crate::ssh::TemporarySessionDescriptor;

    fn direct_connection(host: &str) -> TemporaryConnectionInput {
        TemporaryConnectionInput {
            host: host.into(),
            port: 22,
            username: "alice".into(),
            auth_type: "password".into(),
            password: Some("PROMOTION_SECRET".into()),
            private_key: None,
            key_source: None,
            key_file_path: None,
            key_passphrase: None,
            credential_group_id: None,
            jump_server_id: None,
        }
    }

    fn promotion(host: &str) -> PromoteTemporaryServerInput {
        PromoteTemporaryServerInput {
            connection: direct_connection(host),
            name: "Promoted".into(),
            folder_id: None,
            tag_ids: Vec::new(),
        }
    }

    fn descriptor(host: &str) -> TemporarySessionDescriptor {
        TemporarySessionDescriptor::new(host, 22, "alice", "password", None, None)
    }

    #[test]
    fn temporary_references_must_exist() {
        let db = Database::new(":memory:").unwrap();
        let mut input = direct_connection("host");
        input.password = None;
        input.credential_group_id = Some("missing-group".into());
        assert!(db.validate_temporary_connection(&input).is_err());

        let group = db
            .add_credential_group(&CredentialGroupInput {
                name: "credential".into(),
                auth_type: Some("password".into()),
                username: "alice".into(),
                password: Some("secret".into()),
                private_key: None,
                key_source: None,
                key_file_path: None,
                key_passphrase: None,
            })
            .unwrap();
        input.credential_group_id = Some(group.id);
        input.jump_server_id = Some("missing-jump".into());
        assert!(db.validate_temporary_connection(&input).is_err());

        let jump = db
            .add_server(&ServerInput {
                name: "jump".into(),
                host: "jump.example".into(),
                port: Some(22),
                group_name: None,
                auth_type: Some("password".into()),
                username: "jump".into(),
                password: Some("secret".into()),
                private_key: None,
                key_source: None,
                key_file_path: None,
                key_passphrase: None,
                credential_group_id: None,
                jump_server_id: None,
                folder_id: None,
            })
            .unwrap();
        input.jump_server_id = Some(jump.id);
        assert!(db.validate_temporary_connection(&input).is_ok());
    }

    #[test]
    fn temporary_promotion_requires_matching_descriptor_without_leaking_secrets() {
        let db = Database::new(":memory:").unwrap();
        let error = db
            .promote_temporary_server(&descriptor("host"), &promotion("other-host"))
            .expect_err("mismatched descriptor");

        assert_eq!(db.list_servers().unwrap().len(), 0);
        assert!(!error.to_string().contains("PROMOTION_SECRET"));
    }

    #[test]
    fn temporary_promotion_atomically_saves_encrypted_server_links_and_success_metadata() {
        let db = Database::new(":memory:").unwrap();
        let folder = db
            .create_server_folder(&FolderInput {
                name: "Production".into(),
                parent_id: None,
                sort_order: None,
            })
            .unwrap();
        let tag = db.create_server_tag("Linux").unwrap();
        let mut input = promotion("host");
        input.folder_id = Some(folder.id.clone());
        input.tag_ids = vec![tag.id.clone()];

        let server = db
            .promote_temporary_server(&descriptor("host"), &input)
            .unwrap();

        assert_eq!(server.folder_id.as_deref(), Some(folder.id.as_str()));
        assert_eq!(db.server_tag_ids(&server.id).unwrap(), vec![tag.id]);
        assert_eq!(server.last_connection_result.as_deref(), Some("success"));
        assert!(server.last_attempted_at.is_some());
        assert!(server.last_connected_at.is_some());
        let stored_password: String = db
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT password FROM servers WHERE id = ?1",
                [&server.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_ne!(stored_password, "PROMOTION_SECRET");
        assert!(!stored_password.contains("PROMOTION_SECRET"));
    }

    #[test]
    fn temporary_promotion_rolls_back_when_a_link_write_fails() {
        let db = Database::new(":memory:").unwrap();
        let tag = db.create_server_tag("Linux").unwrap();
        db.conn
            .lock()
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER fail_temporary_tag_link
                 BEFORE INSERT ON server_tag_links
                 BEGIN SELECT RAISE(ABORT, 'forced link failure'); END;",
            )
            .unwrap();
        let mut input = promotion("host");
        input.tag_ids = vec![tag.id];

        assert!(db
            .promote_temporary_server(&descriptor("host"), &input)
            .is_err());

        assert_eq!(db.list_servers().unwrap().len(), 0);
        assert!(db.server_organization().unwrap().tag_links.is_empty());
    }
}
