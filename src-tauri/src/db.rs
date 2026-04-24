use anyhow::Result;
use rusqlite::Connection;
use std::sync::Mutex;
use crate::models::*;

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
                key_passphrase TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );"
        )?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn list_servers(&self) -> Result<Vec<Server>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, name, host, port, group_name, auth_type, username, password, private_key, key_passphrase, created_at, updated_at FROM servers ORDER BY group_name, name"
        )?;
        let servers = stmt.query_map([], |row| {
            Ok(Server {
                id: row.get(0)?,
                name: row.get(1)?,
                host: row.get(2)?,
                port: row.get(3)?,
                group_name: row.get(4)?,
                auth_type: row.get(5)?,
                username: row.get(6)?,
                password: row.get(7)?,
                private_key: row.get(8)?,
                key_passphrase: row.get(9)?,
                created_at: row.get(10)?,
                updated_at: row.get(11)?,
            })
        })?.collect::<Result<Vec<_>, _>>()?;
        Ok(servers)
    }

    pub fn get_server(&self, id: &str) -> Result<Server> {
        let conn = self.conn.lock().unwrap();
        let server = conn.query_row(
            "SELECT id, name, host, port, group_name, auth_type, username, password, private_key, key_passphrase, created_at, updated_at FROM servers WHERE id = ?1",
            [id],
            |row| {
                Ok(Server {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    host: row.get(2)?,
                    port: row.get(3)?,
                    group_name: row.get(4)?,
                    auth_type: row.get(5)?,
                    username: row.get(6)?,
                    password: row.get(7)?,
                    private_key: row.get(8)?,
                    key_passphrase: row.get(9)?,
                    created_at: row.get(10)?,
                    updated_at: row.get(11)?,
                })
            },
        )?;
        Ok(server)
    }

    pub fn add_server(&self, input: &ServerInput) -> Result<Server> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let server = Server {
            id,
            name: input.name.clone(),
            host: input.host.clone(),
            port: input.port.unwrap_or(22),
            group_name: input.group_name.clone().unwrap_or_default(),
            auth_type: input.auth_type.clone().unwrap_or_else(|| "password".into()),
            username: input.username.clone(),
            password: input.password.clone().unwrap_or_default(),
            private_key: input.private_key.clone().unwrap_or_default(),
            key_passphrase: input.key_passphrase.clone().unwrap_or_default(),
            created_at: now.clone(),
            updated_at: now,
        };
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO servers (id, name, host, port, group_name, auth_type, username, password, private_key, key_passphrase, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            (
                &server.id, &server.name, &server.host, server.port,
                &server.group_name, &server.auth_type, &server.username,
                &server.password, &server.private_key, &server.key_passphrase,
                &server.created_at, &server.updated_at,
            ),
        )?;
        Ok(server)
    }

    pub fn update_server(&self, id: &str, input: &ServerInput) -> Result<Server> {
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE servers SET name=?1, host=?2, port=?3, group_name=?4, auth_type=?5, username=?6, password=?7, private_key=?8, key_passphrase=?9, updated_at=?10 WHERE id=?11",
            (
                &input.name, &input.host, input.port.unwrap_or(22),
                input.group_name.as_deref().unwrap_or(""),
                input.auth_type.as_deref().unwrap_or("password"),
                &input.username,
                input.password.as_deref().unwrap_or(""),
                input.private_key.as_deref().unwrap_or(""),
                input.key_passphrase.as_deref().unwrap_or(""),
                &now, id,
            ),
        )?;
        drop(conn);
        self.get_server(id)
    }

    pub fn delete_server(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM servers WHERE id = ?1", [id])?;
        Ok(())
    }
}
