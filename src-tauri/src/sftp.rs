use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;

use anyhow::{anyhow, Result};
use ssh2::{Session, Sftp};
use crate::models::{CredentialGroup, FileEntry, ResolvedAuth, Server};

pub struct SftpManager {
    sessions: HashMap<String, (Session, Sftp)>,
}

impl SftpManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
        }
    }

    fn get_or_connect(&mut self, server: &Server, group: Option<&CredentialGroup>) -> Result<()> {
        if self.sessions.contains_key(&server.id) {
            return Ok(());
        }
        let auth = ResolvedAuth::resolve(server, group)?;
        let tcp = TcpStream::connect((server.host.as_str(), server.port))?;
        let mut session = Session::new()?;
        session.set_tcp_stream(tcp);
        session.handshake()?;
        auth.authenticate(&mut session)?;
        if !session.authenticated() {
            return Err(anyhow!("认证失败"));
        }
        let sftp = session.sftp()?;
        self.sessions.insert(server.id.clone(), (session, sftp));
        Ok(())
    }

    pub fn list_dir(&mut self, server: &Server, group: Option<&CredentialGroup>, path: &str) -> Result<Vec<FileEntry>> {
        self.get_or_connect(server, group)?;
        let (_, sftp) = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        let mut entries = Vec::new();
        let dir = sftp.readdir(std::path::Path::new(path))?;
        for (pathbuf, stat) in dir {
            let name = pathbuf.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            if name == "." || name == ".." { continue; }
            let full_path = pathbuf.to_string_lossy().to_string();
            let is_dir = stat.is_dir();
            let size = stat.size.unwrap_or(0);
            let mtime = stat.mtime.map(|t| {
                chrono::DateTime::from_timestamp(t as i64, 0)
                    .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                    .unwrap_or_default()
            }).unwrap_or_default();
            let perm = stat.perm.map(|p| format!("{:o}", p)).unwrap_or_default();
            entries.push(FileEntry { name, path: full_path, is_dir, size, modified: mtime, permissions: perm });
        }
        entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name)));
        Ok(entries)
    }

    pub fn download_file(&mut self, server: &Server, group: Option<&CredentialGroup>, remote_path: &str, local_path: &str) -> Result<()> {
        self.get_or_connect(server, group)?;
        let (_, sftp) = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        let mut remote_file = sftp.open(std::path::Path::new(remote_path))?;
        let mut buf = Vec::new();
        remote_file.read_to_end(&mut buf)?;
        let expanded = expand_tilde(local_path);
        let mut local_file = std::fs::File::create(&expanded)?;
        local_file.write_all(&buf)?;
        Ok(())
    }

    pub fn upload_file(&mut self, server: &Server, group: Option<&CredentialGroup>, local_path: &str, remote_path: &str) -> Result<()> {
        self.get_or_connect(server, group)?;
        let (_, sftp) = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        let expanded = expand_tilde(local_path);
        let mut local_file = std::fs::File::open(&expanded)?;
        let mut buf = Vec::new();
        local_file.read_to_end(&mut buf)?;
        let mut remote_file = sftp.create(std::path::Path::new(remote_path))?;
        remote_file.write_all(&buf)?;
        Ok(())
    }

    pub fn mkdir(&mut self, server: &Server, group: Option<&CredentialGroup>, path: &str) -> Result<()> {
        self.get_or_connect(server, group)?;
        let (_, sftp) = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        sftp.mkdir(std::path::Path::new(path), 0o755)?;
        Ok(())
    }

    pub fn remove(&mut self, server: &Server, group: Option<&CredentialGroup>, path: &str, is_dir: bool) -> Result<()> {
        self.get_or_connect(server, group)?;
        let (_, sftp) = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        if is_dir { sftp.rmdir(std::path::Path::new(path))?; } else { sftp.unlink(std::path::Path::new(path))?; }
        Ok(())
    }
}

fn expand_tilde(path: &str) -> String {
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
