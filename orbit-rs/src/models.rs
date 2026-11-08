use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone)]
pub struct Server {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub group_name: String,
    pub auth_type: String,
    pub username: String,
    pub password: String,
    pub private_key: String,
    pub key_source: String,
    pub key_file_path: String,
    pub key_passphrase: String,
    pub credential_group_id: String,
    pub jump_server_id: String,
    pub folder_id: Option<String>,
    pub is_pinned: bool,
    pub pin_order: Option<i64>,
    pub last_connected_at: Option<String>,
    pub last_attempted_at: Option<String>,
    pub last_connection_result: Option<String>,
    pub last_connection_error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl std::fmt::Debug for Server {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Server")
            .field("id", &self.id)
            .field("name", &self.name)
            .field("host", &self.host)
            .field("port", &self.port)
            .field("group_name", &self.group_name)
            .field("auth_type", &self.auth_type)
            .field("username", &self.username)
            .field("key_source", &self.key_source)
            .field("key_file_path", &self.key_file_path)
            .field("credential_group_id", &self.credential_group_id)
            .field("jump_server_id", &self.jump_server_id)
            .field("folder_id", &self.folder_id)
            .field("is_pinned", &self.is_pinned)
            .field("pin_order", &self.pin_order)
            .field("last_connected_at", &self.last_connected_at)
            .field("last_attempted_at", &self.last_attempted_at)
            .field("last_connection_result", &self.last_connection_result)
            .field("last_connection_error", &self.last_connection_error)
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Deserialize)]
pub struct ServerInput {
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub group_name: Option<String>,
    pub auth_type: Option<String>,
    pub username: String,
    pub password: Option<String>,
    pub private_key: Option<String>,
    pub key_source: Option<String>,
    pub key_file_path: Option<String>,
    pub key_passphrase: Option<String>,
    pub credential_group_id: Option<String>,
    pub jump_server_id: Option<String>,
    pub folder_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemporaryConnectionInput {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: String,
    pub password: Option<String>,
    pub private_key: Option<String>,
    pub key_source: Option<String>,
    pub key_file_path: Option<String>,
    pub key_passphrase: Option<String>,
    pub credential_group_id: Option<String>,
    pub jump_server_id: Option<String>,
}

impl TemporaryConnectionInput {
    pub fn validate(&self) -> anyhow::Result<()> {
        if self.host.trim().is_empty() {
            anyhow::bail!("主机地址不能为空");
        }
        if self.port == 0 {
            anyhow::bail!("端口必须在 1 到 65535 之间");
        }
        if self.username.trim().is_empty() {
            anyhow::bail!("用户名不能为空");
        }
        if !matches!(self.auth_type.as_str(), "password" | "key") {
            anyhow::bail!("不支持的认证类型");
        }

        let has_password = nonempty(&self.password).is_some();
        let has_private_key = nonempty(&self.private_key).is_some();
        let has_key_file = nonempty(&self.key_file_path).is_some();
        let has_key_passphrase = nonempty(&self.key_passphrase).is_some();
        if self.credential_group_id().is_some() {
            if has_password || has_private_key || has_key_file || has_key_passphrase {
                anyhow::bail!("凭据组不能与直接认证字段同时使用");
            }
            return Ok(());
        }

        match self.auth_type.as_str() {
            "password" => {
                if !has_password {
                    anyhow::bail!("密码认证缺少密码");
                }
                if has_private_key || has_key_file || has_key_passphrase {
                    anyhow::bail!("密码认证不能包含密钥认证字段");
                }
            }
            "key" => {
                if has_password {
                    anyhow::bail!("密钥认证不能包含密码");
                }
                match self.key_source.as_deref().unwrap_or("content") {
                    "content" if has_private_key && !has_key_file => {}
                    "file" if has_key_file && !has_private_key => {}
                    "content" => anyhow::bail!("密钥内容认证需要且只能包含私钥内容"),
                    "file" => anyhow::bail!("密钥文件认证需要且只能包含密钥文件路径"),
                    _ => anyhow::bail!("不支持的密钥来源"),
                }
            }
            _ => unreachable!(),
        }
        Ok(())
    }

    pub fn credential_group_id(&self) -> Option<&str> {
        nonempty(&self.credential_group_id)
    }

    pub fn jump_server_id(&self) -> Option<&str> {
        nonempty(&self.jump_server_id)
    }

    pub fn to_temporary_server(&self, id: String) -> Server {
        let now = chrono::Utc::now().to_rfc3339();
        Server {
            id,
            name: self.host.trim().into(),
            host: self.host.trim().into(),
            port: self.port,
            group_name: String::new(),
            auth_type: self.auth_type.clone(),
            username: self.username.trim().into(),
            password: self.password.clone().unwrap_or_default(),
            private_key: self.private_key.clone().unwrap_or_default(),
            key_source: self.key_source.clone().unwrap_or_else(|| "content".into()),
            key_file_path: self.key_file_path.clone().unwrap_or_default(),
            key_passphrase: self.key_passphrase.clone().unwrap_or_default(),
            credential_group_id: self.credential_group_id().unwrap_or_default().into(),
            jump_server_id: self.jump_server_id().unwrap_or_default().into(),
            folder_id: None,
            is_pinned: false,
            pin_order: None,
            last_connected_at: None,
            last_attempted_at: None,
            last_connection_result: None,
            last_connection_error: None,
            created_at: now.clone(),
            updated_at: now,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromoteTemporaryServerInput {
    pub connection: TemporaryConnectionInput,
    pub name: String,
    pub folder_id: Option<String>,
    pub tag_ids: Vec<String>,
}

impl PromoteTemporaryServerInput {
    pub fn validate(&self) -> anyhow::Result<()> {
        self.connection.validate()?;
        if self.name.trim().is_empty() {
            anyhow::bail!("服务器名称不能为空");
        }
        Ok(())
    }
}

fn nonempty(value: &Option<String>) -> Option<&str> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CredentialGroup {
    pub id: String,
    pub name: String,
    pub auth_type: String,
    pub username: String,
    pub password: String,
    pub private_key: String,
    pub key_source: String,
    pub key_file_path: String,
    pub key_passphrase: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
pub struct CredentialGroupInput {
    pub name: String,
    pub auth_type: Option<String>,
    pub username: String,
    pub password: Option<String>,
    pub private_key: Option<String>,
    pub key_source: Option<String>,
    pub key_file_path: Option<String>,
    pub key_passphrase: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ServerStats {
    pub cpu_usage: f64,
    pub mem_total_mb: u64,
    pub mem_used_mb: u64,
    pub mem_percent: f64,
    pub disk_total: String,
    pub disk_used: String,
    pub disk_percent: f64,
    pub net_rx_kbps: Option<f64>,
    pub net_tx_kbps: Option<f64>,
    pub net_rx_bytes: Option<u64>,
    pub net_tx_bytes: Option<u64>,
    pub net_interface: String,
    pub uptime: String,
    pub load_avg: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: String,
    pub permissions: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProcessInfo {
    pub pid: u32,
    pub user: String,
    pub cpu: f64,
    pub mem: f64,
    pub vsz: u64,
    pub rss: u64,
    pub stat: String,
    pub command: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DockerContainer {
    pub id: String,
    pub name: String,
    pub image: String,
    pub command: String,
    pub status: String,
    pub state: String,
    pub ports: String,
    pub created: String,
    pub running_for: String,
    pub size: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DockerContainerStats {
    pub id: String,
    pub name: String,
    pub cpu_percent: String,
    pub memory_usage: String,
    pub memory_percent: String,
    pub network_io: String,
    pub block_io: String,
    pub pids: String,
}

pub struct ResolvedAuth {
    pub auth_type: String,
    pub username: String,
    pub password: String,
    pub private_key_content: String,
    pub key_passphrase: String,
}

impl ResolvedAuth {
    pub fn resolve(server: &Server, group: Option<&CredentialGroup>) -> anyhow::Result<Self> {
        let (auth_type, username, password, key_source, key_file_path, private_key, key_passphrase) =
            if let Some(g) = group {
                (
                    &g.auth_type,
                    &g.username,
                    &g.password,
                    &g.key_source,
                    &g.key_file_path,
                    &g.private_key,
                    &g.key_passphrase,
                )
            } else {
                (
                    &server.auth_type,
                    &server.username,
                    &server.password,
                    &server.key_source,
                    &server.key_file_path,
                    &server.private_key,
                    &server.key_passphrase,
                )
            };

        let private_key_content = if auth_type != "key" {
            String::new()
        } else {
            match key_source.as_str() {
                "file" => {
                    if key_file_path.is_empty() {
                        return Err(anyhow::anyhow!("密钥文件路径为空"));
                    }
                    let expanded = expand_tilde(key_file_path);
                    std::fs::read_to_string(&expanded)
                        .map_err(|e| anyhow::anyhow!("读取密钥文件失败: {} ({})", e, expanded))?
                }
                _ => private_key.clone(),
            }
        };

        Ok(Self {
            auth_type: auth_type.clone(),
            username: username.clone(),
            password: password.clone(),
            private_key_content,
            key_passphrase: key_passphrase.clone(),
        })
    }

    pub fn authenticate(&self, session: &mut ssh2::Session) -> anyhow::Result<()> {
        match self.auth_type.as_str() {
            "password" => {
                session
                    .userauth_password(&self.username, &self.password)
                    .map_err(|_| anyhow::anyhow!("密码认证失败"))?;
            }
            "key" => {
                if self.private_key_content.is_empty() {
                    return Err(anyhow::anyhow!("私钥内容为空"));
                }
                let passphrase = if self.key_passphrase.is_empty() {
                    None
                } else {
                    Some(self.key_passphrase.as_str())
                };
                let tmp_dir = std::env::temp_dir();
                let tmp_key = tmp_dir.join(format!("orbit_key_{}", uuid::Uuid::new_v4()));
                std::fs::write(&tmp_key, &self.private_key_content)
                    .map_err(|e| anyhow::anyhow!("写入临时密钥文件失败: {}", e))?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ =
                        std::fs::set_permissions(&tmp_key, std::fs::Permissions::from_mode(0o600));
                }
                let result = session.userauth_pubkey_file(
                    &self.username,
                    None,
                    std::path::Path::new(&tmp_key),
                    passphrase,
                );
                let _ = std::fs::remove_file(&tmp_key);
                result.map_err(|e| anyhow::anyhow!("密钥认证失败: {}", e))?;
            }
            _ => return Err(anyhow::anyhow!("不支持的认证类型: {}", self.auth_type)),
        }
        Ok(())
    }
}

pub fn expand_tilde(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return format!("{}/{}", home.display(), rest);
        }
    }
    if path == "~" {
        if let Some(home) = dirs::home_dir() {
            return format!("{}", home.display());
        }
    }
    path.to_string()
}

#[cfg(test)]
mod temporary_input_tests {
    use super::TemporaryConnectionInput;

    fn temporary_input(host: &str, port: u16, username: &str) -> TemporaryConnectionInput {
        TemporaryConnectionInput {
            host: host.into(),
            port,
            username: username.into(),
            auth_type: "password".into(),
            password: Some("secret".into()),
            private_key: None,
            key_source: None,
            key_file_path: None,
            key_passphrase: None,
            credential_group_id: None,
            jump_server_id: None,
        }
    }

    #[test]
    fn temporary_input_rejects_invalid_or_ambiguous_auth() {
        assert!(temporary_input("", 22, "alice").validate().is_err());
        assert!(temporary_input("host", 0, "alice").validate().is_err());
        assert!(temporary_input("host", 22, "").validate().is_err());

        let mut unsupported = temporary_input("host", 22, "alice");
        unsupported.auth_type = "agent".into();
        assert!(unsupported.validate().is_err());

        let mut ambiguous = temporary_input("host", 22, "alice");
        ambiguous.credential_group_id = Some("cg-1".into());
        assert!(ambiguous.validate().is_err());
    }

    #[test]
    fn temporary_input_requires_complete_direct_auth_fields() {
        let mut password = temporary_input("host", 22, "alice");
        password.password = None;
        assert!(password.validate().is_err());

        let mut key = temporary_input("host", 22, "alice");
        key.auth_type = "key".into();
        key.password = None;
        key.key_source = Some("content".into());
        assert!(key.validate().is_err());
        key.private_key = Some("PRIVATE KEY".into());
        assert!(key.validate().is_ok());

        key.key_source = Some("file".into());
        assert!(key.validate().is_err());
        key.private_key = None;
        key.key_file_path = Some("/tmp/id_ed25519".into());
        assert!(key.validate().is_ok());
    }

    #[test]
    fn temporary_server_debug_redacts_direct_secrets() {
        let mut input = temporary_input("host", 22, "alice");
        input.password = Some("PASSWORD_SECRET".into());
        input.private_key = Some("PRIVATE_KEY_SECRET".into());
        input.key_passphrase = Some("PASSPHRASE_SECRET".into());

        let debug = format!("{:?}", input.to_temporary_server("temporary:test".into()));

        assert!(!debug.contains("PASSWORD_SECRET"));
        assert!(!debug.contains("PRIVATE_KEY_SECRET"));
        assert!(!debug.contains("PASSPHRASE_SECRET"));
    }
}
