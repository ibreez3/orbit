use std::collections::HashMap;
use std::io::{Read, Write};

use anyhow::{anyhow, Result};
use ssh2::Sftp;
use crate::models::{FileEntry, Server};
use crate::db::Database;
use crate::transport;

struct SftpSession {
    guard: transport::SessionGuard,
    sftp: Sftp,
}

pub struct SftpManager {
    sessions: HashMap<String, SftpSession>,
}

impl SftpManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
        }
    }

    fn get_or_connect(&mut self, server: &Server, db: &Database) -> Result<()> {
        if self.sessions.contains_key(&server.id) {
            return Ok(());
        }
        let guard = transport::create_session(server, db)?;
        let sftp = guard.session.sftp()?;
        self.sessions.insert(server.id.clone(), SftpSession { guard, sftp });
        Ok(())
    }

    pub fn list_dir(&mut self, server: &Server, db: &Database, path: &str) -> Result<Vec<FileEntry>> {
        self.get_or_connect(server, db)?;
        let s = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        let mut entries = Vec::new();
        let dir = s.sftp.readdir(std::path::Path::new(path))?;
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

    pub fn download_file(&mut self, server: &Server, db: &Database, remote_path: &str, local_path: &str) -> Result<()> {
        self.get_or_connect(server, db)?;
        let s = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        let mut remote_file = s.sftp.open(std::path::Path::new(remote_path))?;
        let mut buf = Vec::new();
        remote_file.read_to_end(&mut buf)?;
        let expanded = expand_tilde(local_path);
        let mut local_file = std::fs::File::create(&expanded)?;
        local_file.write_all(&buf)?;
        Ok(())
    }

    pub fn upload_file(&mut self, server: &Server, db: &Database, local_path: &str, remote_path: &str) -> Result<()> {
        self.get_or_connect(server, db)?;
        let s = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        let expanded = expand_tilde(local_path);
        let mut local_file = std::fs::File::open(&expanded)?;
        let mut buf = Vec::new();
        local_file.read_to_end(&mut buf)?;
        let mut remote_file = s.sftp.create(std::path::Path::new(remote_path))?;
        remote_file.write_all(&buf)?;
        Ok(())
    }

    pub fn mkdir(&mut self, server: &Server, db: &Database, path: &str) -> Result<()> {
        self.get_or_connect(server, db)?;
        let s = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        s.sftp.mkdir(std::path::Path::new(path), 0o755)?;
        Ok(())
    }

    pub fn remove(&mut self, server: &Server, db: &Database, path: &str, is_dir: bool) -> Result<()> {
        self.get_or_connect(server, db)?;
        let s = self.sessions.get(&server.id).ok_or_else(|| anyhow!("SFTP 会话不存在"))?;
        if is_dir { s.sftp.rmdir(std::path::Path::new(path))?; } else { s.sftp.unlink(std::path::Path::new(path))?; }
        Ok(())
    }

    pub fn disconnect(&mut self, server_id: &str) -> Result<()> {
        if let Some(s) = self.sessions.remove(server_id) {
            let _ = s.guard.session.disconnect(None, "bye", None);
        }
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
