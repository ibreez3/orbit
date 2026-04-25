use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
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
    pub created_at: String,
    pub updated_at: String,
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
                    let _ = std::fs::set_permissions(&tmp_key, std::fs::Permissions::from_mode(0o600));
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
