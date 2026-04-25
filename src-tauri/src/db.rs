use anyhow::Result;
use rusqlite::Connection;
use std::sync::Mutex;
use tracing::{info, debug};
use crate::models::*;
use crate::crypto;

pub struct Database {
    pub conn: Mutex<Connection>,
}

impl Database {
    pub fn new(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
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
            );"
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

        let db = Self {
            conn: Mutex::new(conn),
        };
        db.migrate_encrypt()?;
        info!("数据库初始化完成: {}", path);
        Ok(db)
    }

    fn migrate_encrypt(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let mut encrypted_count = 0;

        let servers: Vec<(String, String, String, String)> = {
            let mut stmt = conn.prepare("SELECT id, password, private_key, key_passphrase FROM servers")?;
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
            let enc_pw = if crypto::is_encrypted(password) { password.clone() } else { crypto::encrypt(password) };
            let enc_key = if crypto::is_encrypted(private_key) { private_key.clone() } else { crypto::encrypt(private_key) };
            let enc_pp = if crypto::is_encrypted(key_passphrase) { key_passphrase.clone() } else { crypto::encrypt(key_passphrase) };
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
            let mut stmt = conn.prepare("SELECT id, password, private_key, key_passphrase FROM credential_groups")?;
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
            let enc_pw = if crypto::is_encrypted(password) { password.clone() } else { crypto::encrypt(password) };
            let enc_key = if crypto::is_encrypted(private_key) { private_key.clone() } else { crypto::encrypt(private_key) };
            let enc_pp = if crypto::is_encrypted(key_passphrase) { key_passphrase.clone() } else { crypto::encrypt(key_passphrase) };
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
            created_at: row.get(14)?,
            updated_at: row.get(15)?,
        })
    }

    const SERVER_COLUMNS: &'static str = "id, name, host, port, group_name, auth_type, username, password, private_key, key_source, key_file_path, key_passphrase, credential_group_id, jump_server_id, created_at, updated_at";

    pub fn list_servers(&self) -> Result<Vec<Server>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM servers ORDER BY group_name, name", Self::SERVER_COLUMNS
        ))?;
        let servers = stmt.query_map([], |row| Self::row_to_server(row))?.collect::<Result<Vec<_>, _>>()?;
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
            created_at: now.clone(),
            updated_at: now,
        };
        let conn = self.conn.lock().unwrap();
        conn.execute(
            &format!("INSERT INTO servers ({}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", Self::SERVER_COLUMNS),
            rusqlite::params![
                server.id, server.name, server.host, server.port,
                server.group_name, server.auth_type, server.username,
                enc_password, enc_private_key, server.key_source,
                server.key_file_path, enc_key_passphrase,
                server.credential_group_id, server.jump_server_id,
                server.created_at, server.updated_at,
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
            "UPDATE servers SET name=?1,host=?2,port=?3,group_name=?4,auth_type=?5,username=?6,password=?7,private_key=?8,key_source=?9,key_file_path=?10,key_passphrase=?11,credential_group_id=?12,jump_server_id=?13,updated_at=?14 WHERE id=?15",
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
            "SELECT {} FROM credential_groups ORDER BY name", Self::CG_COLUMNS
        ))?;
        let groups = stmt.query_map([], |row| Self::row_to_credential_group(row))?.collect::<Result<Vec<_>, _>>()?;
        Ok(groups)
    }

    pub fn get_credential_group(&self, id: &str) -> Result<CredentialGroup> {
        let conn = self.conn.lock().unwrap();
        let group = conn.query_row(
            &format!("SELECT {} FROM credential_groups WHERE id = ?1", Self::CG_COLUMNS),
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
            created_at: now.clone(),
            updated_at: now,
        };
        let conn = self.conn.lock().unwrap();
        conn.execute(
            &format!("INSERT INTO credential_groups ({}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)", Self::CG_COLUMNS),
            rusqlite::params![
                &group.id, &group.name, &group.auth_type, &group.username,
                enc_password, enc_private_key, &group.key_source,
                &group.key_file_path, enc_key_passphrase,
                &group.created_at, &group.updated_at,
            ],
        )?;
        Ok(group)
    }

    pub fn update_credential_group(&self, id: &str, input: &CredentialGroupInput) -> Result<CredentialGroup> {
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
        conn.execute("UPDATE servers SET credential_group_id = '' WHERE credential_group_id = ?1", [id])?;
        Ok(())
    }
}
