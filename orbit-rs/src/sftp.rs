use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use crate::db::Database;
use crate::models::{expand_tilde, FileEntry, Server};
use crate::ssh;
use crate::transport;
use anyhow::Result;
use serde::Serialize;
use ssh2::Sftp;
use tracing::{error, info};

pub type ProgressCallback = Box<dyn Fn(u64, u64) + Send + Sync>;

#[derive(Serialize, Clone)]
pub struct TransferProgress {
    pub transferred: u64,
    pub total: u64,
}

pub struct SftpManager;

impl SftpManager {
    fn with_sftp<F, T>(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        f: F,
    ) -> Result<T>
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

    pub fn list_dir_full(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        path: &str,
    ) -> Result<Vec<FileEntry>> {
        let escaped = path.replace("'", "'\\''");
        let cmd = format!(
            "find '{}' -maxdepth 1 -mindepth 1 -printf '%y\\t%f\\t%s\\t%T@\\t%m\\n' 2>/dev/null",
            escaped
        );
        let output = ssh::SshManager::exec_command(pool, server, db, &cmd)?;
        let mut entries = Vec::new();
        for line in output.lines() {
            let parts: Vec<&str> = line.splitn(5, '\t').collect();
            if parts.len() < 5 {
                continue;
            }
            let type_char = parts[0];
            let name = parts[1].to_string();
            if name.is_empty() || name == "." || name == ".." {
                continue;
            }
            let is_dir = type_char == "d";
            let size: u64 = parts[2].parse().unwrap_or(0);
            let mtime_str = parts[3];
            let mtime_epoch: i64 = mtime_str
                .split('.')
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let permissions = parts[4].to_string();
            let full_path = if path == "/" {
                format!("/{}", name)
            } else {
                format!("{}/{}", path, name)
            };
            let modified = chrono::DateTime::from_timestamp(mtime_epoch, 0)
                .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                .unwrap_or_default();
            entries.push(FileEntry {
                name,
                path: full_path,
                is_dir,
                size,
                modified,
                permissions,
            });
        }
        entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name)));
        Ok(entries)
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
                if n == 0 {
                    break;
                }
                local_file.write_all(&buf[..n])?;
                transferred += n as u64;
                if let Some(cb) = progress_cb {
                    let now = Instant::now();
                    let elapsed = now.duration_since(last_time).as_millis() as u64;
                    if (elapsed >= 300 || transferred == total)
                        && Self::should_report(&last_reported, transferred, total)
                    {
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
                if n == 0 {
                    break;
                }
                remote_file.write_all(&buf[..n])?;
                transferred += n as u64;
                if let Some(cb) = progress_cb {
                    let now = Instant::now();
                    let elapsed = now.duration_since(last_time).as_millis() as u64;
                    if (elapsed >= 300 || transferred == total)
                        && Self::should_report(&last_reported, transferred, total)
                    {
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

    pub fn mkdir(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        path: &str,
    ) -> Result<()> {
        Self::with_sftp(pool, server, db, |sftp| {
            sftp.mkdir(std::path::Path::new(path), 0o755)?;
            Ok(())
        })
    }

    pub fn remove(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        path: &str,
        is_dir: bool,
    ) -> Result<()> {
        Self::with_sftp(pool, server, db, |sftp| {
            if is_dir {
                sftp.rmdir(std::path::Path::new(path))?;
            } else {
                sftp.unlink(std::path::Path::new(path))?;
            }
            Ok(())
        })
    }

    pub fn read_text_file(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        path: &str,
        max_size: u64,
    ) -> Result<String> {
        info!(target: "orbit::sftp", server = %server.name, path, max_size, "🔵 read_text_file 开始");
        let escaped = path.replace("'", "'\\''");
        let size_cmd = format!("stat -c%s '{}' 2>/dev/null || echo 0", escaped);
        let size_output = ssh::SshManager::exec_command(pool, server, db, &size_cmd)
            .map_err(|e| {
                error!(target: "orbit::sftp", server = %server.name, path, error = %e, "stat 命令执行失败");
                e
            })?;
        let size: u64 = size_output.trim().parse().unwrap_or(0);
        info!(target: "orbit::sftp", server = %server.name, path, size, "stat 结果");
        if size > max_size {
            error!(target: "orbit::sftp", server = %server.name, path, size, max_size, "文件过大");
            return Err(anyhow::anyhow!(
                "文件过大 ({} 字节)，超过限制 ({} 字节)",
                size,
                max_size
            ));
        }
        let read_cmd = format!("head -c {} '{}' 2>/dev/null", max_size, escaped);
        info!(target: "orbit::sftp", server = %server.name, path, cmd = %read_cmd, "执行 head 命令");
        let content = ssh::SshManager::exec_command(pool, server, db, &read_cmd)
            .map_err(|e| {
                error!(target: "orbit::sftp", server = %server.name, path, error = %e, "head 命令执行失败");
                e
            })?;
        info!(target: "orbit::sftp", server = %server.name, path, size, content_len = content.len(), "✅ read_text_file 完成");
        Ok(content)
    }

    pub fn write_text_file(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        path: &str,
        content: &str,
    ) -> Result<()> {
        info!(target: "orbit::sftp", server = %server.name, path, content_len = content.len(), "🔵 write_text_file 开始");
        let escaped = path.replace("'", "'\\''");
        let encoded = shell_encode(content);
        let cmd = format!("printf '%s' '{}' > '{}'", encoded, escaped);
        ssh::SshManager::exec_command(pool, server, db, &cmd)
            .map_err(|e| {
                error!(target: "orbit::sftp", server = %server.name, path, error = %e, "printf 写入失败");
                e
            })?;
        info!(target: "orbit::sftp", server = %server.name, path, "✅ write_text_file 完成");
        Ok(())
    }

    pub fn rename(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        old_path: &str,
        new_path: &str,
    ) -> Result<()> {
        info!(target: "orbit::sftp", server = %server.name, old_path, new_path, "🔵 rename 开始");
        let escaped_old = old_path.replace("'", "'\\''");
        let escaped_new = new_path.replace("'", "'\\''");
        let cmd = format!("mv '{}' '{}'", escaped_old, escaped_new);
        ssh::SshManager::exec_command(pool, server, db, &cmd)
            .map_err(|e| {
                error!(target: "orbit::sftp", server = %server.name, old_path, new_path, error = %e, "mv 重命名失败");
                e
            })?;
        info!(target: "orbit::sftp", server = %server.name, old_path, new_path, "✅ rename 完成");
        Ok(())
    }
}

fn shell_encode(s: &str) -> String {
    s.replace('\'', "'\\''").replace('%', "%%")
}
