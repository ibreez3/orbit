use std::io::{Read, Write};

use anyhow::Result;
use serde::Serialize;
use ssh2::Sftp;
use tauri::{AppHandle, Emitter};
use tracing::{info, error};
use crate::models::{FileEntry, Server, expand_tilde};
use crate::db::Database;
use crate::transport;

#[derive(Serialize, Clone)]
pub struct TransferProgress {
    pub transferred: u64,
    pub total: u64,
}

pub struct SftpManager;

impl SftpManager {
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

    pub fn download_file(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        remote_path: &str,
        local_path: &str,
        app_handle: &AppHandle,
    ) -> Result<()> {
        let event_name = format!("sftp-download-{}", server.id);
        info!(server = %server.name, remote_path, local_path, "开始下载文件");
        pool.acquire(server, db)?;
        let result = pool.with_session_mut(&server.id, |session| {
            let sftp = session.sftp()?;
            let mut remote_file = sftp.open(std::path::Path::new(remote_path))?;
            let stat = remote_file.stat()?;
            let total = stat.size.unwrap_or(0);
            let expanded = expand_tilde(local_path);
            let mut local_file = std::fs::File::create(&expanded)?;

            let mut buf = [0u8; 32768];
            let mut transferred: u64 = 0;
            loop {
                let n = remote_file.read(&mut buf)?;
                if n == 0 { break; }
                local_file.write_all(&buf[..n])?;
                transferred += n as u64;
                let _ = app_handle.emit(&event_name, TransferProgress { transferred, total });
            }
            info!(remote_path, transferred, total, "文件下载完成");
            Ok(())
        });
        pool.release(&server.id);
        if let Err(ref e) = result {
            error!(remote_path, error = %e, "文件下载失败");
        }
        result
    }

    pub fn upload_file(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        local_path: &str,
        remote_path: &str,
        app_handle: &AppHandle,
    ) -> Result<()> {
        let event_name = format!("sftp-upload-{}", server.id);
        let expanded = expand_tilde(local_path);
        let metadata = std::fs::metadata(&expanded)?;
        let total = metadata.len();
        info!(server = %server.name, local_path, remote_path, total, "开始上传文件");

        pool.acquire(server, db)?;
        let result = pool.with_session_mut(&server.id, |session| {
            let sftp = session.sftp()?;
            let mut local_file = std::fs::File::open(&expanded)?;
            let mut remote_file = sftp.create(std::path::Path::new(remote_path))?;

            let mut buf = [0u8; 32768];
            let mut transferred: u64 = 0;
            loop {
                let n = local_file.read(&mut buf)?;
                if n == 0 { break; }
                remote_file.write_all(&buf[..n])?;
                transferred += n as u64;
                let _ = app_handle.emit(&event_name, TransferProgress { transferred, total });
            }
            info!(remote_path, transferred, total, "文件上传完成");
            Ok(())
        });
        pool.release(&server.id);
        if let Err(ref e) = result {
            error!(remote_path, error = %e, "文件上传失败");
        }
        result
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
