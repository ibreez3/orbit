use crate::db::Database;
use crate::models::{FileEntry, Server};
use crate::ssh;
use crate::transport;
use anyhow::Result;
use ssh2::Sftp;
use tracing::{error, info};

pub type ProgressCallback = Box<dyn Fn(u64, u64) + Send + Sync>;

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
        let _lease = pool.acquire_scoped(server, db)?;
        let result = pool.with_session_mut(&server.id, |session| {
            let sftp = session.sftp()?;
            f(&sftp)
        });
        result
    }

    pub fn list_dir_full(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        path: &str,
    ) -> Result<Vec<FileEntry>> {
        Self::with_sftp(pool, server, db, |sftp| {
            let mut entries = Vec::new();
            for (entry_path, stat) in sftp.readdir(std::path::Path::new(path))? {
                let name = entry_path.file_name().unwrap_or_default().to_string_lossy().into_owned();
                if name == "." || name == ".." { continue; }
                let modified = stat.mtime.and_then(|time| chrono::DateTime::from_timestamp(time as i64, 0))
                    .map(|time| time.format("%Y-%m-%d %H:%M:%S").to_string()).unwrap_or_default();
                entries.push(FileEntry {
                    name, path: entry_path.to_string_lossy().into_owned(), is_dir: stat.is_dir(),
                    size: stat.size.unwrap_or(0), modified,
                    permissions: stat.perm.map(|mode| format!("{:03o}", mode & 0o777)).unwrap_or_default(),
                });
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
        let _ = pool;
        crate::sftp_transfer::transfer(db, server, &crate::sftp_transfer::TransferRequest {
            id: String::new(), server_id: server.id.clone(), local_path: local_path.to_string(), remote_path: remote_path.to_string(), upload: false, overwrite: false,
        }, &crate::sftp_transfer::TransferControl::default(), progress_cb)
    }

    pub fn upload_file(
        pool: &transport::SessionPool, server: &Server, db: &Database,
        local_path: &str, remote_path: &str, progress_cb: Option<&ProgressCallback>,
    ) -> Result<()> {
        let _ = pool;
        crate::sftp_transfer::transfer(db, server, &crate::sftp_transfer::TransferRequest {
            id: String::new(), server_id: server.id.clone(), local_path: local_path.to_string(), remote_path: remote_path.to_string(), upload: true, overwrite: false,
        }, &crate::sftp_transfer::TransferControl::default(), progress_cb)
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
    s.replace('\'', "'\\''")
}

#[cfg(test)]
mod tests {
    use super::shell_encode;

    #[test]
    fn shell_encode_preserves_percent_in_content() {
        assert_eq!(shell_encode("100% done"), "100% done");
        assert_eq!(shell_encode("it's"), "it'\\''s");
    }
}
