use crate::{db::Database, models::Server, sftp::ProgressCallback, transport};
use anyhow::{anyhow, bail, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};

#[derive(Debug)]
pub enum TransferFailure {
    Conflict,
    Cancelled,
}
impl std::fmt::Display for TransferFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Conflict => "目标文件已存在，请确认覆盖后重试",
            Self::Cancelled => "传输已取消，目标文件未更改",
        })
    }
}
impl std::error::Error for TransferFailure {}

#[derive(Default)]
pub struct TransferControl {
    pub cancelled: AtomicBool,
    started: AtomicBool,
}
impl TransferControl {
    pub fn check(&self) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(TransferFailure::Cancelled.into());
        }
        Ok(())
    }
}
#[derive(Default)]
pub struct TransferRegistry {
    entries: Mutex<HashMap<String, Arc<TransferControl>>>,
}
impl TransferRegistry {
    pub fn reserve(&self) -> Result<String> {
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| anyhow!("传输队列锁定失败"))?;
        if entries.len() >= 256 {
            bail!("传输队列已满");
        }
        let id = uuid::Uuid::new_v4().to_string();
        entries.insert(id.clone(), Arc::new(TransferControl::default()));
        Ok(id)
    }
    pub fn start(&self, id: &str) -> Result<Arc<TransferControl>> {
        let control = self
            .entries
            .lock()
            .map_err(|_| anyhow!("传输队列锁定失败"))?
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow!("传输任务不存在"))?;
        if control.started.swap(true, Ordering::AcqRel) {
            bail!("传输任务已开始");
        }
        Ok(control)
    }
    pub fn cancel(&self, id: &str) -> Result<()> {
        let entries = self
            .entries
            .lock()
            .map_err(|_| anyhow!("传输队列锁定失败"))?;
        if let Some(control) = entries.get(id) {
            control.cancelled.store(true, Ordering::Release);
        }
        Ok(())
    }
    pub fn finish(&self, id: &str) {
        if let Ok(mut entries) = self.entries.lock() {
            entries.remove(id);
        }
    }
}

#[derive(Deserialize)]
pub struct TransferRequest {
    pub id: String,
    pub server_id: String,
    pub local_path: String,
    pub remote_path: String,
    pub upload: bool,
    pub overwrite: bool,
}

fn copy_stream(
    reader: &mut impl Read,
    writer: &mut impl Write,
    total: u64,
    control: &TransferControl,
    progress: Option<&ProgressCallback>,
) -> Result<()> {
    let mut buffer = [0u8; 65536];
    let mut transferred = 0u64;
    let mut last = std::time::Instant::now();
    loop {
        control.check()?;
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        control.check()?;
        writer.write_all(&buffer[..count])?;
        transferred += count as u64;
        if last.elapsed().as_millis() >= 100 || transferred == total {
            if let Some(progress) = progress {
                progress(transferred, total);
            }
            last = std::time::Instant::now();
        }
    }
    control.check()?;
    if transferred != total {
        bail!("源文件在传输过程中发生变化，请重试");
    }
    writer.flush()?;
    Ok(())
}

fn read_packet(channel: &mut ssh2::Channel) -> Result<Vec<u8>> {
    let mut length = [0; 4];
    channel.read_exact(&mut length)?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > 1024 * 1024 {
        bail!("无效的 SFTP 响应");
    }
    let mut packet = vec![0; length];
    channel.read_exact(&mut packet)?;
    Ok(packet)
}
fn push_string(packet: &mut Vec<u8>, value: &[u8]) {
    packet.extend((value.len() as u32).to_be_bytes());
    packet.extend(value);
}
fn atomic_remote_replace(session: &ssh2::Session, source: &str, destination: &str) -> Result<()> {
    let mut channel = session.channel_session()?;
    channel.subsystem("sftp")?;
    channel.write_all(&[0, 0, 0, 5, 1, 0, 0, 0, 3])?;
    let version = read_packet(&mut channel)?;
    if version.len() < 5 || version[0] != 2 {
        bail!("SFTP 协议协商失败");
    }
    let mut packet = vec![200];
    packet.extend(1u32.to_be_bytes());
    push_string(&mut packet, b"posix-rename@openssh.com");
    push_string(&mut packet, source.as_bytes());
    push_string(&mut packet, destination.as_bytes());
    channel.write_all(&(packet.len() as u32).to_be_bytes())?;
    channel.write_all(&packet)?;
    let response = read_packet(&mut channel)?;
    if response.len() < 9
        || response[0] != 101
        || response[1..5] != 1u32.to_be_bytes()
        || response[5..9] != [0, 0, 0, 0]
    {
        bail!("服务器无法原子替换目标文件（可能不支持 posix-rename）；原文件已保留");
    }
    let _ = channel.send_eof();
    Ok(())
}

pub fn transfer(
    db: &Database,
    server: &Server,
    request: &TransferRequest,
    control: &TransferControl,
    progress: Option<&ProgressCallback>,
) -> Result<()> {
    control.check()?;
    let guard = transport::create_session(server, db)?;
    guard.session.set_timeout(5000);
    control.check()?;
    let sftp = guard.session.sftp()?;
    let remote = Path::new(&request.remote_path);
    let local_path = crate::models::expand_tilde(&request.local_path);
    let local = Path::new(&local_path);
    if request.upload {
        let existing = match sftp.lstat(remote) {
            Ok(stat) => Some(stat),
            Err(error) if error.code() == ssh2::ErrorCode::SFTP(2) => None,
            Err(error) => return Err(error.into()),
        };
        if let Some(stat) = &existing {
            if !stat.is_file() {
                bail!("目标不是普通文件，不能覆盖");
            }
            if !request.overwrite {
                return Err(TransferFailure::Conflict.into());
            }
        }
        let mut source = std::fs::File::open(local)?;
        let metadata = source.metadata()?;
        if !metadata.is_file() {
            bail!("暂不支持文件夹传输");
        }
        let parent = remote.parent().ok_or_else(|| anyhow!("远程路径无效"))?;
        let temporary = parent.join(format!(".orbit-transfer-{}.part", uuid::Uuid::new_v4()));
        let result = (|| -> Result<()> {
            let mut destination = sftp.open_mode(
                &temporary,
                ssh2::OpenFlags::WRITE | ssh2::OpenFlags::CREATE | ssh2::OpenFlags::EXCLUSIVE,
                0o600,
                ssh2::OpenType::File,
            )?;
            copy_stream(
                &mut source,
                &mut destination,
                metadata.len(),
                control,
                progress,
            )?;
            if let Some(stat) = existing {
                destination.setstat(ssh2::FileStat {
                    size: None,
                    uid: None,
                    gid: None,
                    perm: stat.perm.map(|mode| mode & 0o777),
                    atime: None,
                    mtime: None,
                })?;
            }
            destination.close()?;
            control.check()?;
            if request.overwrite {
                atomic_remote_replace(
                    &guard.session,
                    temporary
                        .to_str()
                        .ok_or_else(|| anyhow!("远程路径编码无效"))?,
                    &request.remote_path,
                )?;
            } else {
                sftp.rename(&temporary, remote, Some(ssh2::RenameFlags::empty()))
                    .map_err(|error| {
                        if sftp.lstat(remote).is_ok() {
                            anyhow!(TransferFailure::Conflict)
                        } else {
                            error.into()
                        }
                    })?;
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = sftp.unlink(&temporary);
        }
        result
    } else {
        let existing = match std::fs::symlink_metadata(local) {
            Ok(metadata) => Some(metadata),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error.into()),
        };
        if let Some(metadata) = &existing {
            if !metadata.is_file() {
                bail!("目标不是普通文件，不能覆盖");
            }
            if !request.overwrite {
                return Err(TransferFailure::Conflict.into());
            }
        }
        let mut source = sftp.open(remote)?;
        let stat = source.stat()?;
        if !stat.is_file() {
            bail!("暂不支持文件夹传输");
        }
        let total = stat.size.ok_or_else(|| anyhow!("无法读取远程文件大小"))?;
        let parent = local.parent().ok_or_else(|| anyhow!("本地路径无效"))?;
        let temporary = parent.join(format!(".orbit-transfer-{}.part", uuid::Uuid::new_v4()));
        let result = (|| -> Result<()> {
            use std::os::unix::fs::OpenOptionsExt;
            let mut destination = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            copy_stream(&mut source, &mut destination, total, control, progress)?;
            if let Some(metadata) = existing {
                destination.set_permissions(metadata.permissions())?;
            }
            destination.sync_all()?;
            drop(destination);
            control.check()?;
            if request.overwrite {
                std::fs::rename(&temporary, local)?;
            } else {
                std::fs::hard_link(&temporary, local).map_err(|error| {
                    if error.kind() == std::io::ErrorKind::AlreadyExists {
                        anyhow!(TransferFailure::Conflict)
                    } else {
                        error.into()
                    }
                })?;
                let _ = std::fs::remove_file(&temporary);
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancel_before_start_is_not_lost_and_ids_cannot_be_reused() {
        let registry = TransferRegistry::default();
        let id = registry.reserve().unwrap();
        registry.cancel(&id).unwrap();
        let control = registry.start(&id).unwrap();
        assert!(control.check().is_err());
        assert!(registry.start(&id).is_err());
        registry.finish(&id);
        assert!(registry.start(&id).is_err());
    }
    #[test]
    fn truncated_sources_and_failed_writes_do_not_report_success() {
        let mut output = Vec::new();
        assert!(copy_stream(
            &mut &b"short"[..],
            &mut output,
            100,
            &TransferControl::default(),
            None
        )
        .is_err());
        struct BrokenWriter;
        impl Write for BrokenWriter {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::other("disk full"))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        assert!(copy_stream(
            &mut &b"data"[..],
            &mut BrokenWriter,
            4,
            &TransferControl::default(),
            None
        )
        .is_err());
    }
    #[test]
    fn empty_files_complete_and_cancellation_stops_copy() {
        let mut output = Vec::new();
        copy_stream(
            &mut &b""[..],
            &mut output,
            0,
            &TransferControl::default(),
            None,
        )
        .unwrap();
        let control = TransferControl::default();
        control.cancelled.store(true, Ordering::Release);
        assert!(copy_stream(&mut &b"data"[..], &mut output, 4, &control, None).is_err());
        assert!(output.is_empty());
    }
}
