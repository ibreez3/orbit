use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use anyhow::Result;
use serde::Serialize;
use ssh2::Sftp;
use tracing::{info, error};
use crate::models::{FileEntry, FileEntryStat, Server, expand_tilde};
use crate::db::Database;
use crate::transport;
use crate::ssh;

pub type ProgressCallback = Box<dyn Fn(u64, u64) + Send + Sync>;

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

    fn should_report(last: &AtomicU64, transferred: u64, total: u64) -> bool {
        if total == 0 {
            return false;
        }
        let prev = last.load(Ordering::Relaxed);
        let old_pct = prev * 100 / total;
        let new_pct = transferred * 100 / total;
        new_pct > old_pct
    }

    pub fn list_dir_fast(pool: &transport::SessionPool, server: &Server, db: &Database, path: &str) -> Result<Vec<FileEntry>> {
        let escaped = path.replace("'", "'\\''");
        let cmd = format!("ls -1Ap '{}'", escaped);
        let output = ssh::SshManager::exec_command(pool, server, db, &cmd)?;
        let mut entries = Vec::new();
        for line in output.lines() {
            if line.is_empty() { continue; }
            let is_dir = line.ends_with('/');
            let name = line.trim_end_matches('/').to_string();
            if name.is_empty() { continue; }
            let full_path = if path == "/" {
                format!("/{}", name)
            } else {
                format!("{}/{}", path, name)
            };
            entries.push(FileEntry {
                name,
                path: full_path,
                is_dir,
                size: 0,
                modified: String::new(),
                permissions: String::new(),
            });
        }
        entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name)));
        Ok(entries)
    }

    pub fn stat_dir_entries(pool: &transport::SessionPool, server: &Server, db: &Database, path: &str) -> Result<Vec<FileEntryStat>> {
        let escaped = path.replace("'", "'\\''");
        let cmd = format!(
            "find '{}' -maxdepth 1 -mindepth 1 -print0 2>/dev/null | xargs -0 stat -c '%n\\t%s\\t%Y\\t%a' 2>/dev/null",
            escaped
        );
        let output = ssh::SshManager::exec_command(pool, server, db, &cmd)?;
        let mut stats = Vec::new();
        for line in output.lines() {
            let parts: Vec<&str> = line.splitn(4, '\t').collect();
            if parts.len() < 4 { continue; }
            let file_path = parts[0].to_string();
            let size: u64 = parts[1].parse().unwrap_or(0);
            let mtime_epoch: i64 = parts[2].parse().unwrap_or(0);
            let permissions = parts[3].to_string();
            let modified = chrono::DateTime::from_timestamp(mtime_epoch, 0)
                .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                .unwrap_or_default();
            stats.push(FileEntryStat {
                path: file_path,
                size,
                modified,
                permissions,
            });
        }
        Ok(stats)
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
        progress_cb: Option<&ProgressCallback>,
    ) -> Result<()> {
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
            let last_reported = Arc::new(AtomicU64::new(0));
            let mut last_time = Instant::now();
            loop {
                let n = remote_file.read(&mut buf)?;
                if n == 0 { break; }
                local_file.write_all(&buf[..n])?;
                transferred += n as u64;
                if let Some(cb) = progress_cb {
                    let now = Instant::now();
                    let elapsed = now.duration_since(last_time).as_millis() as u64;
                    if (elapsed >= 300 || transferred == total) && Self::should_report(&last_reported, transferred, total) {
                        last_reported.store(transferred, Ordering::Relaxed);
                        last_time = now;
                        cb(transferred, total);
                    }
                }
            }
            if let Some(cb) = progress_cb {
                cb(transferred, total);
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
        progress_cb: Option<&ProgressCallback>,
    ) -> Result<()> {
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
            let last_reported = Arc::new(AtomicU64::new(0));
            let mut last_time = Instant::now();
            loop {
                let n = local_file.read(&mut buf)?;
                if n == 0 { break; }
                remote_file.write_all(&buf[..n])?;
                transferred += n as u64;
                if let Some(cb) = progress_cb {
                    let now = Instant::now();
                    let elapsed = now.duration_since(last_time).as_millis() as u64;
                    if (elapsed >= 300 || transferred == total) && Self::should_report(&last_reported, transferred, total) {
                        last_reported.store(transferred, Ordering::Relaxed);
                        last_time = now;
                        cb(transferred, total);
                    }
                }
            }
            if let Some(cb) = progress_cb {
                cb(transferred, total);
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
