use std::sync::Arc;
use anyhow::Result;
use serde::Serialize;
use serde_json::{json, Value};
use crate::database::{DatabaseManager, DatabaseStore};
use crate::{service, sftp::SftpManager, ssh, OrbitApp};

pub use crate::models::{FileEntry, ServerInput, TemporaryConnectionInput};
pub use crate::sftp_transfer::TransferRequest;

#[derive(Serialize)]
pub struct ServerSummary {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: String,
    pub jump_server_id: String,
    pub group_name: String,
    pub key_source: String,
    pub key_file_path: String,
    pub credential_group_id: String,
    pub folder_id: Option<String>,
    pub is_pinned: bool,
    pub pin_order: Option<i64>,
    pub last_connected_at: Option<String>,
    pub last_connection_result: Option<String>,
    pub last_connection_error: Option<String>,
}

pub struct DesktopCore {
    app: OrbitApp,
}

impl DesktopCore {
    pub fn new(path: &str) -> Result<Self> {
        let app = OrbitApp::new(path)?;
        app.db.conn.lock().map_err(|_| anyhow::anyhow!("数据库锁定失败"))?.execute_batch("CREATE TABLE IF NOT EXISTS desktop_private_settings (name TEXT PRIMARY KEY, value TEXT NOT NULL)")?;
        Ok(Self { app })
    }

    pub fn start_job(&self, server_id: &str, command: String, timeout_ms: u32, max_bytes: usize) -> Result<Arc<crate::agent::AgentJob>> {
        if command.trim().is_empty() || command.len() > 64 * 1024 { anyhow::bail!("命令为空或过长"); }
        let server = self.app.db.get_server(server_id)?;
        let (_, job) = crate::agent::start_agent_job(server, self.app.db_path.clone(), command, timeout_ms.clamp(1, 300_000), max_bytes.clamp(1024, 1_048_576));
        Ok(job)
    }

    pub fn private_setting(&self, name: &str) -> Result<Option<String>> {
        use rusqlite::OptionalExtension;
        let value: Option<String> = self.app.db.conn.lock().map_err(|_| anyhow::anyhow!("数据库锁定失败"))?.query_row("SELECT value FROM desktop_private_settings WHERE name=?1", [name], |row| row.get(0)).optional()?;
        value.map(|value| self.app.db.cipher.decrypt(&value).map_err(Into::into)).transpose()
    }

    pub fn save_private_setting(&self, name: &str, value: &str) -> Result<()> {
        let encrypted = self.app.db.cipher.encrypt(value)?;
        self.app.db.conn.lock().map_err(|_| anyhow::anyhow!("数据库锁定失败"))?.execute("INSERT INTO desktop_private_settings(name,value) VALUES(?1,?2) ON CONFLICT(name) DO UPDATE SET value=excluded.value", [name, &encrypted])?;
        Ok(())
    }

    pub fn servers(&self) -> Result<Vec<ServerSummary>> {
        Ok(self.app.db.list_servers()?.into_iter().map(|server| ServerSummary {
            id: server.id, name: server.name, host: server.host, port: server.port,
            username: server.username, auth_type: server.auth_type, jump_server_id: server.jump_server_id,
            group_name: server.group_name, key_source: server.key_source, key_file_path: server.key_file_path,
            credential_group_id: server.credential_group_id, folder_id: server.folder_id,
            is_pinned: server.is_pinned, pin_order: server.pin_order,
            last_connected_at: server.last_connected_at, last_connection_result: server.last_connection_result,
            last_connection_error: server.last_connection_error,
        }).collect())
    }

    pub fn add_server(&self, input: &ServerInput) -> Result<String> {
        if input.name.trim().is_empty() || input.host.trim().is_empty() || input.username.trim().is_empty() || input.port == Some(0) {
            anyhow::bail!("请填写名称、主机、用户名和有效端口");
        }
        Ok(self.app.db.add_server(input)?.id)
    }

    pub fn delete_server(&self, id: &str) -> Result<()> {
        self.app.db.delete_server(id)
    }

    pub fn on_host_key(&self, handler: Arc<dyn Fn(String) + Send + Sync>) -> Result<()> {
        self.app.db.host_keys.set_handler(Some(handler))
    }

    pub fn resolve_host_key(&self, id: &str, trust: bool) -> Result<()> {
        self.app.db.host_keys.resolve(&self.app.db, id, trust)
    }

    pub fn connect(&self, server_id: &str, data: ssh::DataCallback, closed: ssh::ClosedCallback) -> Result<String> {
        self.app.db.mark_connection_attempt(server_id)?;
        let server = self.app.db.get_server(server_id)?;
        let result = service::connect_server_session(&self.app, server, Some(server_id.to_string()), None, data, closed);
        match &result {
            Ok(_) => { let _ = self.app.db.mark_connection_success(server_id); }
            Err(error) => { let _ = self.app.db.mark_connection_failure(server_id, &crate::db::sanitize_connection_error(&error.to_string())); }
        }
        result
    }

    pub fn connect_temporary(&self, input: TemporaryConnectionInput, data: ssh::DataCallback, closed: ssh::ClosedCallback) -> Result<String> {
        self.app.db.validate_temporary_connection(&input)?;
        let descriptor = ssh::TemporarySessionDescriptor::from_input(&input);
        let server = input.to_temporary_server(format!("temporary:{}", uuid::Uuid::new_v4()));
        service::connect_server_session(&self.app, server, None, Some(descriptor), data, closed)
    }

    pub fn write(&self, id: &str, data: &[u8]) -> Result<()> {
        self.app.ssh.lock().map_err(|_| anyhow::anyhow!("会话锁定失败"))?.write(id, data)
    }

    pub fn resize(&self, id: &str, cols: u32, rows: u32) -> Result<()> {
        self.app.ssh.lock().map_err(|_| anyhow::anyhow!("会话锁定失败"))?.resize(id, cols, rows)
    }

    pub fn disconnect(&self, id: &str) -> Result<()> {
        self.app.ssh.lock().map_err(|_| anyhow::anyhow!("会话锁定失败"))?.disconnect(id)
    }

    pub fn files(&self, server_id: &str, path: &str) -> Result<Vec<FileEntry>> {
        let server = self.app.db.get_server(server_id)?;
        SftpManager::list_dir_full(&self.app.pool, &server, &self.app.db, path)
    }

    pub fn reserve_transfer(&self) -> Result<String> {
        self.app.transfers.reserve()
    }

    pub fn remove_file(&self, server_id: &str, path: &str) -> Result<()> {
        let server = self.app.db.get_server(server_id)?;
        SftpManager::remove(&self.app.pool, &server, &self.app.db, path, false)
    }

    pub fn cancel_transfer(&self, id: &str) -> Result<()> {
        self.app.transfers.cancel(id)
    }

    pub fn transfer(&self, request: &TransferRequest, progress: crate::sftp::ProgressCallback) -> Result<()> {
        let server = self.app.db.get_server(&request.server_id)?;
        let control = self.app.transfers.start(&request.id)?;
        let result = crate::sftp_transfer::transfer(&self.app.db, &server, request, &control, Some(&progress));
        self.app.transfers.finish(&request.id);
        result
    }

    pub fn request(&self, action: &str, args: Value) -> Result<Value> {
        let text = |key: &str| -> Result<&str> { args.get(key).and_then(Value::as_str).ok_or_else(|| anyhow::anyhow!("缺少参数: {}", key)) };
        let id = || text("id");
        let input = || args.get("input").cloned().ok_or_else(|| anyhow::anyhow!("缺少 input"));
        match action {
            "settings.connection" => {
                let timeout = args["timeout"].as_u64().filter(|value| (1..=300).contains(value)).ok_or_else(|| anyhow::anyhow!("连接超时无效"))?;
                let keepalive = args["keepalive"].as_u64().filter(|value| *value <= 300).ok_or_else(|| anyhow::anyhow!("保活间隔无效"))?;
                let settings = crate::transport::set_connection_settings(timeout as u32, keepalive as u32);
                self.app.pool.set_keepalive(settings.keepalive_seconds);
            }
            "config.export" => crate::desktop_config::export(&self.app, text("path")?, args["include_secrets"].as_bool().unwrap_or(false))?,
            "config.import" => return Ok(json!(crate::desktop_config::import(&self.app, text("path")?, args["overwrite"].as_bool().unwrap_or(false))?)),
            "forward.start" => {
                let local_port: u16 = serde_json::from_value(args["local_port"].clone())?;
                let remote_port: u16 = serde_json::from_value(args["remote_port"].clone())?;
                return Ok(json!(service::start_port_forward(&self.app, id()?, text("server_id")?, local_port, text("remote_host")?, remote_port)?));
            }
            "forward.stop" => self.app.ssh.lock().map_err(|_| anyhow::anyhow!("会话锁定失败"))?.stop_port_forward(id()?),
            "server.promote" => {
                let descriptor = self.app.ssh.lock().map_err(|_| anyhow::anyhow!("会话锁定失败"))?.temporary_descriptor(id()?)?;
                let server = self.app.db.promote_temporary_server(&descriptor, &serde_json::from_value(input()?)?)?;
                return Ok(json!(server.id));
            }
            "server.update" => {
                let input: ServerInput = serde_json::from_value(input()?)?;
                if input.name.trim().is_empty() || input.host.trim().is_empty() || input.username.trim().is_empty() || input.port == Some(0) { anyhow::bail!("连接字段无效"); }
                self.app.db.update_server(id()?, &input)?;
            }
            "server.duplicate" => {
                let server = self.app.db.get_server(id()?)?;
                let mut value = serde_json::to_value(server)?;
                value["name"] = json!(text("name")?);
                let server = self.app.db.add_server(&serde_json::from_value(value)?)?;
                return Ok(json!(server.id));
            }
            "server.test" => {
                let server = self.app.db.get_server(id()?)?;
                crate::transport::create_session(&server, &self.app.db)?;
            }
            "organization.list" => return Ok(serde_json::to_value(self.app.db.server_organization()?)?),
            "folder.create" => return Ok(serde_json::to_value(self.app.db.create_server_folder(&serde_json::from_value(input()?)?)?)?),
            "folder.rename" => { self.app.db.rename_server_folder(id()?, &serde_json::from_value(input()?)?)?; }
            "folder.move" => { let input: crate::server_organization::FolderMoveInput = serde_json::from_value(input()?)?; self.app.db.move_server_folder(id()?, input.parent_id.as_deref(), input.sort_order)?; }
            "folder.delete" => { let input: crate::server_organization::FolderDeleteInput = serde_json::from_value(input()?)?; self.app.db.delete_server_folder(id()?, input.destination_folder_id.as_deref(), input.delete_servers)?; }
            "tag.create" => return Ok(serde_json::to_value(self.app.db.create_server_tag(text("name")?)?)?),
            "tag.delete" => self.app.db.delete_server_tag(id()?)?,
            "server.tags" => self.app.db.set_server_tags(id()?, &serde_json::from_value::<Vec<String>>(args["tag_ids"].clone())?)?,
            "server.move" => self.app.db.move_server(id()?, args["folder_id"].as_str())?,
            "server.pin" => { self.app.db.set_server_pin(id()?, args["is_pinned"].as_bool().ok_or_else(|| anyhow::anyhow!("缺少 is_pinned"))?, args["pin_order"].as_i64())?; }
            "credentials.list" => {
                return Ok(Value::Array(self.app.db.list_credential_groups()?.into_iter().map(|group| redact(serde_json::to_value(group).unwrap_or(Value::Null))).collect()));
            }
            "credentials.save" => {
                let mut input: crate::models::CredentialGroupInput = serde_json::from_value(input()?)?;
                if input.name.trim().is_empty() || input.username.trim().is_empty() { anyhow::bail!("名称和用户名不能为空"); }
                let group = if let Some(id) = args["id"].as_str() {
                    let existing = self.app.db.get_credential_group(id)?;
                    if input.password.is_none() { input.password = Some(existing.password); }
                    if input.private_key.is_none() { input.private_key = Some(existing.private_key); }
                    if input.key_passphrase.is_none() { input.key_passphrase = Some(existing.key_passphrase); }
                    self.app.db.update_credential_group(id, &input)?
                } else { self.app.db.add_credential_group(&input)? };
                return Ok(redact(serde_json::to_value(group)?));
            }
            "credentials.delete" => self.app.db.delete_credential_group(id()?)?,
            "sftp.mkdir" | "sftp.remove" | "sftp.rename" | "sftp.read" | "sftp.write" => {
                let server = self.app.db.get_server(text("server_id")?)?;
                let path = text("path")?;
                match action {
                    "sftp.mkdir" => SftpManager::mkdir(&self.app.pool, &server, &self.app.db, path)?,
                    "sftp.remove" => SftpManager::remove(&self.app.pool, &server, &self.app.db, path, args["is_dir"].as_bool().unwrap_or(false))?,
                    "sftp.rename" => SftpManager::rename(&self.app.pool, &server, &self.app.db, path, text("new_path")?)?,
                    "sftp.read" => return Ok(json!(SftpManager::read_text_file(&self.app.pool, &server, &self.app.db, path, 2 * 1024 * 1024)?)),
                    "sftp.write" => SftpManager::write_text_file(&self.app.pool, &server, &self.app.db, path, text("content")?)?,
                    _ => unreachable!(),
                }
            }
            "monitor.stats" | "monitor.processes" | "exec" => {
                let server = self.app.db.get_server(text("server_id")?)?;
                let pool = &self.app.pool;
                let db = &self.app.db;
                return match action {
                    "monitor.stats" => Ok(serde_json::to_value(crate::monitor::collect_stats(&ssh::SshManager::exec_command(pool, &server, db, crate::monitor::get_monitor_script())?)?)?),
                    "monitor.processes" => Ok(serde_json::to_value(crate::monitor::parse_processes(&ssh::SshManager::exec_command(pool, &server, db, crate::monitor::get_process_script())?))?),
                    "exec" => Ok(json!(ssh::SshManager::exec_command_checked(pool, &server, db, text("command")?, "执行命令")?)),
                    _ => unreachable!(),
                };
            }
            "database.list" => return Ok(Value::Array(DatabaseStore::list_connections(&self.app.db)?.into_iter().map(|connection| redact(serde_json::to_value(connection).unwrap_or(Value::Null))).collect())),
            "database.save" => {
                let input = serde_json::from_value(input()?)?;
                let connection = if let Some(id) = args["id"].as_str() { DatabaseStore::update_connection(&self.app.db, id, &input)? } else { DatabaseStore::add_connection(&self.app.db, &input)? };
                return Ok(redact(serde_json::to_value(connection)?));
            }
            "database.delete" => DatabaseStore::delete_connection(&self.app.db, id()?)?,
            "database.test" => return Ok(serde_json::to_value(DatabaseManager::test_connection(&self.app.db, &self.app.pool, id()?, args["install_sqlite"].as_bool().unwrap_or(false))?)?),
            "database.catalogs" | "database.schema" | "database.query" | "database.backup" | "database.restore" | "database.prepare_import" | "database.import" => return DatabaseManager::request(&self.app.db, &self.app.pool, action, &args),
            "database.history" => return Ok(serde_json::to_value(DatabaseStore::list_backup_records(&self.app.db)?)?),
            _ => anyhow::bail!("不支持的操作: {}", action),
        }
        Ok(Value::Null)
    }

    pub fn shutdown(&self) {
        if let Ok(mut ssh) = self.app.ssh.lock() {
            ssh.shutdown();
        }
    }
}

fn redact(mut value: Value) -> Value {
    if let Some(object) = value.as_object_mut() {
        for key in ["password", "private_key", "key_passphrase"] { object.remove(key); }
    }
    value
}

impl Drop for DesktopCore {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inventory_does_not_expose_credentials() {
        let core = DesktopCore::new(":memory:").unwrap();
        let input = serde_json::from_value(serde_json::json!({
            "name": "test", "host": "example.test", "username": "test",
            "password": "private-password", "private_key": "private-key", "key_passphrase": "private-passphrase"
        })).unwrap();
        let id = core.add_server(&input).unwrap();
        let list = core.servers().unwrap();
        assert_eq!(list[0].id, id);
        let json = serde_json::to_value(&list).unwrap();
        for field in ["password", "private_key", "key_passphrase"] {
            assert!(json[0].get(field).is_none());
        }
        core.delete_server(&id).unwrap();
        assert!(core.servers().unwrap().is_empty());
    }

    #[test]
    fn editing_and_duplicating_preserve_secrets_without_returning_them() {
        let core = DesktopCore::new(":memory:").unwrap();
        let input = json!({"name":"original", "host":"host", "username":"user", "password":"secret"});
        let id = core.add_server(&serde_json::from_value(input).unwrap()).unwrap();
        core.request("server.update", json!({"id":id, "input":{"name":"edited", "host":"host", "username":"user"}})).unwrap();
        assert_eq!(core.app.db.get_server(&id).unwrap().password, "secret");
        let duplicate = core.request("server.duplicate", json!({"id":id, "name":"copy"})).unwrap();
        assert_eq!(core.app.db.get_server(duplicate.as_str().unwrap()).unwrap().password, "secret");
        assert!(!serde_json::to_string(&core.servers().unwrap()).unwrap().contains("secret"));
        let group = core.request("credentials.save", json!({"input":{"name":"group", "username":"user", "password":"group-secret", "private_key":"private", "key_passphrase":"phrase"}})).unwrap();
        assert!(group.get("password").is_none());
        core.request("credentials.save", json!({"id":group["id"], "input":{"name":"renamed", "username":"user"}})).unwrap();
        let stored = core.app.db.get_credential_group(group["id"].as_str().unwrap()).unwrap();
        assert_eq!(stored.password, "group-secret");
        assert_eq!(stored.private_key, "private");
        assert_eq!(stored.key_passphrase, "phrase");
        let list = core.request("credentials.list", json!({})).unwrap();
        assert!(list[0].get("private_key").is_none());
        assert!(list[0].get("key_passphrase").is_none());
    }

    #[test]
    fn desktop_organization_and_database_roundtrip() {
        let core = DesktopCore::new(":memory:").unwrap();
        let id = core.add_server(&serde_json::from_value(json!({"name":"test", "host":"host", "username":"user"})).unwrap()).unwrap();
        let folder = core.request("folder.create", json!({"input":{"name":"Production"}})).unwrap();
        let tag = core.request("tag.create", json!({"name":"critical"})).unwrap();
        core.request("server.move", json!({"id":id, "folder_id":folder["id"]})).unwrap();
        core.request("server.tags", json!({"id":id, "tag_ids":[tag["id"]]})).unwrap();
        core.request("server.pin", json!({"id":id, "is_pinned":true})).unwrap();
        assert_eq!(core.servers().unwrap()[0].folder_id.as_deref(), folder["id"].as_str());
        assert!(core.servers().unwrap()[0].is_pinned);
        assert_eq!(core.request("organization.list", json!({})).unwrap()["tag_links"][0]["server_id"], id);
        assert!(core.request("folder.delete", json!({"id":folder["id"], "input":{"delete_servers":false}})).is_err());
        let destination = core.request("folder.create", json!({"input":{"name":"Archive"}})).unwrap();
        core.request("folder.delete", json!({"id":folder["id"], "input":{"delete_servers":false, "destination_folder_id":destination["id"]}})).unwrap();
        assert_eq!(core.servers().unwrap()[0].folder_id.as_deref(), destination["id"].as_str());
        let input = json!({"name":"database", "engine":"mysql", "host":"localhost", "username":"user", "password":"db-secret"});
        let connection = core.request("database.save", json!({"input":input})).unwrap();
        assert!(connection.get("password").is_none());
        core.request("database.save", json!({"id":connection["id"], "input":{"name":"updated", "engine":"mysql"}})).unwrap();
        assert_eq!(DatabaseStore::get_connection(&core.app.db, connection["id"].as_str().unwrap()).unwrap().password, "db-secret");
        assert!(core.request("database.list", json!({})).unwrap()[0].get("password").is_none());
        assert!(core.request("not.an.operation", json!({})).is_err());
        assert!(core.request("server.update", json!({})).is_err());
    }

    #[test]
    fn desktop_private_settings_are_encrypted_at_rest() {
        let core = DesktopCore::new(":memory:").unwrap();
        core.save_private_setting("ai.config", "api-key-secret").unwrap();
        let stored: String = core.app.db.conn.lock().unwrap().query_row("SELECT value FROM desktop_private_settings WHERE name='ai.config'", [], |row| row.get(0)).unwrap();
        assert!(stored.starts_with("ORB2:"));
        assert!(!stored.contains("api-key-secret"));
        assert_eq!(core.private_setting("ai.config").unwrap().as_deref(), Some("api-key-secret"));
        assert!(core.private_setting("missing").unwrap().is_none());
    }

    #[test]
    fn invalid_connection_fields_are_not_persisted() {
        let core = DesktopCore::new(":memory:").unwrap();
        for input in [
            serde_json::json!({"name":"test", "host":"", "username":"test"}),
            serde_json::json!({"name":"test", "host":"host", "username":"test", "port":0}),
        ] {
            assert!(core.add_server(&serde_json::from_value(input).unwrap()).is_err());
        }
        assert!(core.servers().unwrap().is_empty());
    }
}
