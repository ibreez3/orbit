use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use serde::Serialize;
use tracing::{debug, info, warn};

use crate::db::Database;
use crate::models::Server;
use crate::transport;

#[derive(Serialize, Clone)]
pub struct TrafficStats {
    pub bytes_read: u64,
    pub bytes_written: u64,
}

pub type DataCallback = Box<dyn Fn(&str, &[u8]) + Send + Sync>;
pub type ClosedCallback = Box<dyn Fn(&str) + Send + Sync>;

#[derive(Debug, Clone)]
pub struct SshCommandOutput {
    pub stdout: String,
    pub stderr: String,
    pub exit_status: i32,
}

impl SshCommandOutput {
    pub fn into_success_stdout(self, context: &str) -> Result<String> {
        if self.exit_status == 0 {
            return Ok(self.stdout);
        }

        let stderr = self.stderr.trim();
        let stdout = self.stdout.trim();
        let detail = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            "no output"
        };
        Err(anyhow!(
            "{} failed with exit status {}: {}",
            context,
            self.exit_status,
            detail
        ))
    }
}

pub(crate) struct ActiveChannel {
    channel: Arc<std::sync::Mutex<ssh2::Channel>>,
    running: Arc<AtomicBool>,
    reader_handle: Option<std::thread::JoinHandle<()>>,
    bytes_read: Arc<AtomicU64>,
    bytes_written: Arc<AtomicU64>,
}

struct SharedSession {
    guard: transport::SessionGuard,
    channels: HashMap<String, ActiveChannel>,
    session_lock: Arc<std::sync::Mutex<()>>,
    server_id: String,
}

struct IdleSession {
    guard: transport::SessionGuard,
    session_lock: Arc<std::sync::Mutex<()>>,
}

pub(crate) fn spawn_channel_reader(
    channel_id: &str,
    channel: ssh2::Channel,
    data_cb: DataCallback,
    closed_cb: ClosedCallback,
    session_lock: Arc<std::sync::Mutex<()>>,
) -> Result<ActiveChannel> {
    let channel = Arc::new(std::sync::Mutex::new(channel));
    let running = Arc::new(AtomicBool::new(true));
    let bytes_read = Arc::new(AtomicU64::new(0));
    let bytes_written = Arc::new(AtomicU64::new(0));
    let sid = channel_id.to_string();
    let ch = channel.clone();
    let run = running.clone();
    let br = bytes_read.clone();
    let lock = session_lock;

    let reader_handle = std::thread::spawn(move || {
        let mut buf = [0u8; 65536];
        let mut idle_sleep = Duration::from_millis(1);
        const MIN_IDLE_SLEEP: Duration = Duration::from_millis(1);
        const MAX_IDLE_SLEEP: Duration = Duration::from_millis(10);

        while run.load(Ordering::Relaxed) {
            // 锁顺序：先 session_lock 再 channel mutex，与 write/resize 一致
            // 避免 ABBA 死锁
            let read_result = {
                let _guard = match lock.lock() {
                    Ok(g) => g,
                    Err(_) => break,
                };
                let mut ch = match ch.lock() {
                    Ok(g) => g,
                    Err(_) => continue,
                };
                ch.read(&mut buf)
            };

            match read_result {
                Ok(n) if n > 0 => {
                    idle_sleep = MIN_IDLE_SLEEP;
                    let data: &[u8] = &buf[..n];
                    br.fetch_add(n as u64, Ordering::Relaxed);
                    data_cb(&sid, data);
                }
                Ok(_) => {
                    debug!(session_id = %sid, "SSH channel 正常关闭");
                    closed_cb(&sid);
                    run.store(false, Ordering::Relaxed);
                    break;
                }
                Err(e) => {
                    if e.kind() == std::io::ErrorKind::WouldBlock {
                        std::thread::sleep(idle_sleep);
                        idle_sleep = std::cmp::min(idle_sleep * 2, MAX_IDLE_SLEEP);
                        continue;
                    }
                    warn!(session_id = %sid, error = %e, "SSH channel 读取错误");
                    closed_cb(&sid);
                    run.store(false, Ordering::Relaxed);
                    break;
                }
            }
        }
    });

    Ok(ActiveChannel {
        channel,
        running,
        reader_handle: Some(reader_handle),
        bytes_read,
        bytes_written,
    })
}

pub struct SshManager {
    sessions: HashMap<String, SharedSession>,
    channel_to_session: HashMap<String, String>,
    idle_pool: HashMap<String, Vec<IdleSession>>,
    port_forwards: HashMap<String, Arc<AtomicBool>>,
}

impl SshManager {
    pub fn register_port_forward(&mut self, id: &str, running: Arc<AtomicBool>) {
        self.port_forwards.insert(id.to_string(), running);
    }

    pub fn stop_port_forward(&mut self, id: &str) {
        if let Some(running) = self.port_forwards.remove(id) {
            running.store(false, Ordering::Relaxed);
        }
    }
    pub(crate) fn register_session(
        &mut self,
        session_id: &str,
        server_id: &str,
        guard: transport::SessionGuard,
        active_channel: ActiveChannel,
        session_lock: Arc<std::sync::Mutex<()>>,
    ) {
        self.channel_to_session
            .insert(session_id.to_string(), session_id.to_string());
        self.sessions.insert(
            session_id.to_string(),
            SharedSession {
                guard,
                channels: [(session_id.to_string(), active_channel)]
                    .into_iter()
                    .collect(),
                session_lock,
                server_id: server_id.to_string(),
            },
        );
    }

    pub fn take_idle_session(
        &mut self,
        server_id: &str,
    ) -> Option<(transport::SessionGuard, Arc<std::sync::Mutex<()>>)> {
        if let Some(sessions) = self.idle_pool.get_mut(server_id) {
            if let Some(idle) = sessions.pop() {
                info!(server_id, "复用空闲 SSH 连接");
                return Some((idle.guard, idle.session_lock));
            }
        }
        None
    }

    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
            channel_to_session: HashMap::new(),
            idle_pool: HashMap::new(),
            port_forwards: HashMap::new(),
        }
    }

    pub fn connect(
        &mut self,
        session_id: &str,
        server: &Server,
        db: &Database,
        data_cb: DataCallback,
        closed_cb: ClosedCallback,
    ) -> Result<()> {
        let guard = transport::create_session(server, db)?;
        let mut channel = guard.session.channel_session()?;
        channel.setenv("LANG", "en_US.UTF-8")?;
        channel.setenv("LC_ALL", "en_US.UTF-8")?;
        channel.request_pty("xterm-256color", None, None)?;
        channel.shell()?;
        guard.session.set_blocking(false);
        info!(session_id, server = %server.name, "SSH 终端连接成功");

        let session_lock = Arc::new(std::sync::Mutex::new(()));
        let active_channel = spawn_channel_reader(
            session_id,
            channel,
            data_cb,
            closed_cb,
            session_lock.clone(),
        )?;

        self.channel_to_session
            .insert(session_id.to_string(), session_id.to_string());
        self.sessions.insert(
            session_id.to_string(),
            SharedSession {
                guard,
                channels: [(session_id.to_string(), active_channel)]
                    .into_iter()
                    .collect(),
                session_lock,
                server_id: server.id.clone(),
            },
        );
        Ok(())
    }

    pub fn spawn_channel(
        &mut self,
        existing_session_id: &str,
        new_channel_id: &str,
        data_cb: DataCallback,
        closed_cb: ClosedCallback,
    ) -> Result<()> {
        let session_key = self
            .channel_to_session
            .get(existing_session_id)
            .cloned()
            .ok_or_else(|| anyhow!("源会话不存在: {}", existing_session_id))?;

        let session_lock_arc = {
            let shared = self
                .sessions
                .get(&session_key)
                .ok_or_else(|| anyhow!("共享会话丢失"))?;
            shared.session_lock.clone()
        };

        let shared = self
            .sessions
            .get_mut(&session_key)
            .ok_or_else(|| anyhow!("共享会话在创建 channel 前丢失"))?;

        let _lock = session_lock_arc
            .lock()
            .map_err(|e| anyhow!("session lock failed: {}", e))?;

        shared.guard.session.set_blocking(true);
        let mut channel = shared
            .guard
            .session
            .channel_session()
            .map_err(|e| anyhow!("创建 channel 失败: {}", e))?;
        channel
            .setenv("LANG", "en_US.UTF-8")
            .map_err(|e| anyhow!("设置 LANG 环境变量失败: {}", e))?;
        channel
            .setenv("LC_ALL", "en_US.UTF-8")
            .map_err(|e| anyhow!("设置 LC_ALL 环境变量失败: {}", e))?;
        channel
            .request_pty("xterm-256color", None, None)
            .map_err(|e| anyhow!("请求 PTY 失败: {}", e))?;
        channel
            .shell()
            .map_err(|e| anyhow!("启动 shell 失败: {}", e))?;
        shared.guard.session.set_blocking(false);
        drop(_lock);

        info!(
            existing_session_id,
            new_channel_id, "复用 SSH 连接创建新 channel"
        );

        let shared = self
            .sessions
            .get_mut(&session_key)
            .ok_or_else(|| anyhow!("共享会话在添加 channel 前丢失"))?;
        let session_key_for_index = session_key.clone();
        let active_channel = spawn_channel_reader(
            new_channel_id,
            channel,
            data_cb,
            closed_cb,
            session_lock_arc,
        )?;
        shared
            .channels
            .insert(new_channel_id.to_string(), active_channel);
        self.channel_to_session
            .insert(new_channel_id.to_string(), session_key_for_index);
        Ok(())
    }

    pub fn write(&self, session_id: &str, data: &[u8]) -> Result<()> {
        let session_key = self
            .channel_to_session
            .get(session_id)
            .ok_or_else(|| anyhow!("会话不存在"))?;
        let shared = self
            .sessions
            .get(session_key)
            .ok_or_else(|| anyhow!("会话不存在"))?;
        let ch = shared
            .channels
            .get(session_id)
            .ok_or_else(|| anyhow!("会话不存在"))?;

        let _lock = shared
            .session_lock
            .lock()
            .map_err(|_| anyhow!("session lock failed"))?;
        let mut c = ch.channel.lock().map_err(|_| anyhow!("通道锁定失败"))?;
        c.write_all(data)?;
        ch.bytes_written
            .fetch_add(data.len() as u64, Ordering::Relaxed);
        Ok(())
    }

    pub fn resize(&self, session_id: &str, cols: u32, rows: u32) -> Result<()> {
        let session_key = self
            .channel_to_session
            .get(session_id)
            .ok_or_else(|| anyhow!("会话不存在"))?;
        let shared = self
            .sessions
            .get(session_key)
            .ok_or_else(|| anyhow!("会话不存在"))?;
        let ch = shared
            .channels
            .get(session_id)
            .ok_or_else(|| anyhow!("会话不存在"))?;

        let _lock = shared
            .session_lock
            .lock()
            .map_err(|_| anyhow!("session lock failed"))?;
        let mut c = ch.channel.lock().map_err(|_| anyhow!("通道锁定失败"))?;
        c.request_pty_size(cols, rows, None, None)?;
        Ok(())
    }

    pub fn get_traffic(&self, session_id: &str) -> Result<TrafficStats> {
        let session_key = self
            .channel_to_session
            .get(session_id)
            .ok_or_else(|| anyhow!("会话不存在"))?;
        let shared = self
            .sessions
            .get(session_key)
            .ok_or_else(|| anyhow!("会话不存在"))?;
        let ch = shared
            .channels
            .get(session_id)
            .ok_or_else(|| anyhow!("会话不存在"))?;

        Ok(TrafficStats {
            bytes_read: ch.bytes_read.load(Ordering::Relaxed),
            bytes_written: ch.bytes_written.load(Ordering::Relaxed),
        })
    }

    pub fn disconnect(&mut self, channel_id: &str) -> Result<()> {
        let Some(session_key) = self.channel_to_session.get(channel_id).cloned() else {
            return Ok(());
        };

        let mut should_pool_session = false;
        if let Some(shared) = self.sessions.get_mut(&session_key) {
            if let Some(mut ch) = shared.channels.remove(channel_id) {
                self.channel_to_session.remove(channel_id);
                ch.running.store(false, Ordering::Relaxed);
                if let Some(h) = ch.reader_handle.take() {
                    let _ = h.join();
                }
                info!(channel_id, "SSH channel 已关闭");
                should_pool_session = shared.channels.is_empty();
            }
        }

        if should_pool_session {
            if let Some(shared) = self.sessions.remove(&session_key) {
                let server_id = shared.server_id;
                self.idle_pool
                    .entry(server_id)
                    .or_default()
                    .push(IdleSession {
                        guard: shared.guard,
                        session_lock: shared.session_lock,
                    });
                info!(channel_id, "SSH 连接已归还连接池");
            }
        }
        Ok(())
    }

    pub fn shutdown(&mut self) {
        for (_, sessions) in self.idle_pool.drain() {
            for idle in sessions {
                let _ = idle.guard.session.set_blocking(true);
                let _ = idle.guard.session.disconnect(None, "bye", None);
            }
        }
        for (_, mut shared) in self.sessions.drain() {
            for (_, mut ch) in shared.channels.drain() {
                ch.running.store(false, Ordering::Relaxed);
                if let Some(h) = ch.reader_handle.take() {
                    let _ = h.join();
                }
            }
            let _ = shared.guard.session.set_blocking(true);
            let _ = shared.guard.session.disconnect(None, "bye", None);
        }
        info!("SSH 连接池已关闭");
    }

    pub fn exec_command(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        command: &str,
    ) -> Result<String> {
        debug!(server = %server.name, command, "执行远程命令");
        let _lease = pool.acquire_scoped(server, db)?;
        let result = pool.with_session_mut(&server.id, |session| {
            let mut channel = session.channel_session()?;
            channel.exec(command)?;
            session.set_timeout(30_000);
            let mut output = String::new();
            let read_result = channel.read_to_string(&mut output);
            session.set_timeout(0);
            read_result?;
            Ok(output)
        });
        if let Err(ref e) = result {
            warn!(server = %server.name, command, error = %e, "远程命令执行失败");
        }
        result
    }

    pub fn exec_command_checked(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        command: &str,
        context: &str,
    ) -> Result<String> {
        Self::exec_command_output(pool, server, db, command)?.into_success_stdout(context)
    }

    pub fn exec_command_output(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        command: &str,
    ) -> Result<SshCommandOutput> {
        debug!(server = %server.name, command, "执行远程命令并检查退出状态");
        let _lease = pool.acquire_scoped(server, db)?;
        let result = pool.with_session_mut(&server.id, |session| {
            let mut channel = session.channel_session()?;
            channel.exec(command)?;
            session.set_timeout(30_000);

            let mut stdout = String::new();
            let stdout_result = channel.read_to_string(&mut stdout);
            let mut stderr = String::new();
            let mut stderr_stream = channel.stderr();
            let stderr_result = stderr_stream.read_to_string(&mut stderr);
            let wait_result = channel.wait_close();
            let exit_status_result = channel.exit_status();
            session.set_timeout(0);

            stdout_result?;
            stderr_result?;
            wait_result?;
            Ok(SshCommandOutput {
                stdout,
                stderr,
                exit_status: exit_status_result?,
            })
        });
        if let Err(ref e) = result {
            warn!(server = %server.name, command, error = %e, "远程命令执行失败");
        }
        result
    }
}

impl Drop for SshManager {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checked_command_output_rejects_nonzero_exit_with_stderr() {
        let output = SshCommandOutput {
            stdout: String::new(),
            stderr: "permission denied".into(),
            exit_status: 13,
        };

        let err = output
            .into_success_stdout("sqlite schema")
            .expect_err("nonzero exit");

        assert!(err.to_string().contains("sqlite schema"));
        assert!(err.to_string().contains("exit status 13"));
        assert!(err.to_string().contains("permission denied"));
    }
}
