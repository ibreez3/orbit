use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;

use anyhow::{anyhow, Result};
use ssh2::{Session, Sftp};
use crate::models::{CredentialGroup, FileEntry, ResolvedAuth, Server};

pub struct SftpSession {
    _session: Session,
    _sftp: Sftp,
}

pub struct SftpManager {
    _sessions: HashMap<String, SftpSession>,
}

impl SftpManager {
    pub fn new() -> Self {
        Self {
            _sessions: HashMap::new(),
        }
    }

    fn connect_sftp(server: &Server, group: Option<&CredentialGroup>) -> Result<Session> {
        let auth = ResolvedAuth::resolve(server, group)?;
        let tcp = TcpStream::connect((server.host.as_str(), server.port))?;
        let mut session = Session::new()?;
        session.set_tcp_stream(tcp);
        session.handshake()?;
        auth.authenticate(&mut session)?;
        if !session.authenticated() {
            return Err(anyhow!("认证失败"));
        }
        Ok(session)
    }

    pub fn list_dir(&mut self, server: &Server, group: Option<&CredentialGroup>, path: &str) -> Result<Vec<FileEntry>> {
        let session = Self::connect_sftp(server, group)?;
        let sftp = session.sftp()?;
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

    pub fn download_file(&self, server: &Server, group: Option<&CredentialGroup>, remote_path: &str, local_path: &str) -> Result<()> {
        let session = Self::connect_sftp(server, group)?;
        let sftp = session.sftp()?;
        let mut remote_file = sftp.open(std::path::Path::new(remote_path))?;
        let mut buf = Vec::new();
        remote_file.read_to_end(&mut buf)?;
        let mut local_file = std::fs::File::create(local_path)?;
        local_file.write_all(&buf)?;
        Ok(())
    }

    pub fn upload_file(&self, server: &Server, group: Option<&CredentialGroup>, local_path: &str, remote_path: &str) -> Result<()> {
        let session = Self::connect_sftp(server, group)?;
        let sftp = session.sftp()?;
        let mut local_file = std::fs::File::open(local_path)?;
        let mut buf = Vec::new();
        local_file.read_to_end(&mut buf)?;
        let mut remote_file = sftp.create(std::path::Path::new(remote_path))?;
        remote_file.write_all(&buf)?;
        Ok(())
    }

    pub fn mkdir(&self, server: &Server, group: Option<&CredentialGroup>, path: &str) -> Result<()> {
        let session = Self::connect_sftp(server, group)?;
        let sftp = session.sftp()?;
        sftp.mkdir(std::path::Path::new(path), 0o755)?;
        Ok(())
    }

    pub fn remove(&self, server: &Server, group: Option<&CredentialGroup>, path: &str, is_dir: bool) -> Result<()> {
        let session = Self::connect_sftp(server, group)?;
        let sftp = session.sftp()?;
        if is_dir { sftp.rmdir(std::path::Path::new(path))?; } else { sftp.unlink(std::path::Path::new(path))?; }
        Ok(())
    }
}
