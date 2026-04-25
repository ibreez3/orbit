use std::io::{Read, Write};

use anyhow::Result;
use ssh2::Sftp;
use crate::models::{FileEntry, Server};
use crate::db::Database;
use crate::transport;

pub struct SftpManager;

impl SftpManager {
    #[allow(dead_code)]
    pub fn new() -> Self { Self }

    fn with_sftp<F, T>(pool: &transport::SessionPool, server: &Server, db: &Database, f: F) -> Result<T>
    where
        F: FnOnce(&Sftp) -> Result<T>,
    {
        pool.acquire(server, db)?;
        let result = pool.with_session_mut(&server.id, |session| {
            let sftp = session.sftp()?;
            f(&sftp)
        });
        pool.release(&server.id);
        result
    }

    pub fn list_dir(pool: &transport::SessionPool, server: &Server, db: &Database, path: &str) -> Result<Vec<FileEntry>> {
        Self::with_sftp(pool, server, db, |sftp| {
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
        })
    }

    pub fn download_file(pool: &transport::SessionPool, server: &Server, db: &Database, remote_path: &str, local_path: &str) -> Result<()> {
        Self::with_sftp(pool, server, db, |sftp| {
            let mut remote_file = sftp.open(std::path::Path::new(remote_path))?;
            let mut buf = Vec::new();
            remote_file.read_to_end(&mut buf)?;
            let expanded = expand_tilde(local_path);
            let mut local_file = std::fs::File::create(&expanded)?;
            local_file.write_all(&buf)?;
            Ok(())
        })
    }

    pub fn upload_file(pool: &transport::SessionPool, server: &Server, db: &Database, local_path: &str, remote_path: &str) -> Result<()> {
        Self::with_sftp(pool, server, db, |sftp| {
            let expanded = expand_tilde(local_path);
            let mut local_file = std::fs::File::open(&expanded)?;
            let mut buf = Vec::new();
            local_file.read_to_end(&mut buf)?;
            let mut remote_file = sftp.create(std::path::Path::new(remote_path))?;
            remote_file.write_all(&buf)?;
            Ok(())
        })
    }

    pub fn mkdir(pool: &transport::SessionPool, server: &Server, db: &Database, path: &str) -> Result<()> {
        Self::with_sftp(pool, server, db, |sftp| {
            sftp.mkdir(std::path::Path::new(path), 0o755)?;
            Ok(())
        })
    }

    pub fn remove(pool: &transport::SessionPool, server: &Server, db: &Database, path: &str, is_dir: bool) -> Result<()> {
        Self::with_sftp(pool, server, db, |sftp| {
            if is_dir { sftp.rmdir(std::path::Path::new(path))?; } else { sftp.unlink(std::path::Path::new(path))?; }
            Ok(())
        })
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
