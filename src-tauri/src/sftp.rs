use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;

use anyhow::{anyhow, Result};
use ssh2::{Session, Sftp};
use crate::models::{FileEntry, Server};

pub struct SftpSession {
    _session: Session,
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

    fn connect_to_server(server: &Server) -> Result<Session> {
        let tcp = TcpStream::connect((server.host.as_str(), server.port))?;
        let mut session = Session::new()?;
        session.set_tcp_stream(tcp);
        session.handshake()?;

        match server.auth_type.as_str() {
            "password" => {
                session.userauth_password(&server.username, &server.password)?;
            }
            "key" => {
                let passphrase = if server.key_passphrase.is_empty() {
                    None
                } else {
                    Some(server.key_passphrase.as_str())
                };
                session.userauth_pubkey_memory(
                    &server.username,
                    None,
                    &server.private_key,
                    passphrase,
                )?;
            }
            _ => return Err(anyhow!("不支持的认证类型")),
        }

        if !session.authenticated() {
            return Err(anyhow!("认证失败"));
        }

        Ok(session)
    }

    pub fn list_dir(&mut self, server: &Server, path: &str) -> Result<Vec<FileEntry>> {
        let session = Self::connect_to_server(server)?;
        let sftp = session.sftp()?;

        let mut entries = Vec::new();
        let dir = sftp.readdir(std::path::Path::new(path))?;

        for (pathbuf, stat) in dir {
            let name = pathbuf
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();

            if name == "." || name == ".." {
                continue;
            }

            let full_path = pathbuf.to_string_lossy().to_string();

            let is_dir = stat.is_dir();
            let size = stat.size.unwrap_or(0);
            let mtime = stat.mtime.map(|t| {
                chrono::DateTime::from_timestamp(t as i64, 0)
                    .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                    .unwrap_or_default()
            }).unwrap_or_default();

            let perm = stat.perm.map(|p| format!("{:o}", p)).unwrap_or_default();

            entries.push(FileEntry {
                name,
                path: full_path,
                is_dir,
                size,
                modified: mtime,
                permissions: perm,
            });
        }

        entries.sort_by(|a, b| {
            b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name))
        });

        Ok(entries)
    }

    pub fn download_file(&self, server: &Server, remote_path: &str, local_path: &str) -> Result<()> {
        let session = Self::connect_to_server(server)?;
        let sftp = session.sftp()?;

        let mut remote_file = sftp.open(std::path::Path::new(remote_path))?;
        let mut buf = Vec::new();
        remote_file.read_to_end(&mut buf)?;

        let mut local_file = std::fs::File::create(local_path)?;
        local_file.write_all(&buf)?;

        Ok(())
    }

    pub fn upload_file(&self, server: &Server, local_path: &str, remote_path: &str) -> Result<()> {
        let session = Self::connect_to_server(server)?;
        let sftp = session.sftp()?;

        let mut local_file = std::fs::File::open(local_path)?;
        let mut buf = Vec::new();
        local_file.read_to_end(&mut buf)?;

        let mut remote_file = sftp.create(std::path::Path::new(remote_path))?;
        remote_file.write_all(&buf)?;

        Ok(())
    }

    pub fn mkdir(&self, server: &Server, path: &str) -> Result<()> {
        let session = Self::connect_to_server(server)?;
        let sftp = session.sftp()?;
        sftp.mkdir(std::path::Path::new(path), 0o755)?;
        Ok(())
    }

    pub fn remove(&self, server: &Server, path: &str, is_dir: bool) -> Result<()> {
        let session = Self::connect_to_server(server)?;
        let sftp = session.sftp()?;
        if is_dir {
            sftp.rmdir(std::path::Path::new(path))?;
        } else {
            sftp.unlink(std::path::Path::new(path))?;
        }
        Ok(())
    }
}
