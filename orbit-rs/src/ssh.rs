use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use serde::Serialize;
use tracing::{debug, info, warn};

use crate::db::Database;
use crate::models::{Server, TemporaryConnectionInput};
use crate::transport;

#[derive(Serialize, Clone)]
pub struct TrafficStats {
    pub bytes_read: u64,
    pub bytes_written: u64,
}

pub type DataCallback = Box<dyn Fn(&str, &[u8]) + Send + Sync>;
pub type ClosedCallback = Box<dyn Fn(&str) + Send + Sync>;
pub type SessionPoolKey = Option<String>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemporarySessionDescriptor {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: String,
    pub credential_group_id: Option<String>,
    pub jump_server_id: Option<String>,
}

impl TemporarySessionDescriptor {
    #[allow(dead_code)]
    pub fn new(
        host: impl Into<String>,
        port: u16,
        username: impl Into<String>,
        auth_type: impl Into<String>,
        credential_group_id: Option<String>,
        jump_server_id: Option<String>,
    ) -> Self {
        Self {
            host: host.into(),
            port,
            username: username.into(),
            auth_type: auth_type.into(),
            credential_group_id,
            jump_server_id,
        }
    }

    pub fn from_input(input: &TemporaryConnectionInput) -> Self {
        Self::new(
            input.host.trim(),
            input.port,
            input.username.trim(),
            input.auth_type.clone(),
            input.credential_group_id().map(str::to_owned),
            input.jump_server_id().map(str::to_owned),
        )
    }

    pub fn matches(&self, input: &TemporaryConnectionInput) -> bool {
        self == &Self::from_input(input)
    }
}

fn promotable_descriptor<'a>(
    pool_key: Option<&str>,
    temporary: Option<&'a TemporarySessionDescriptor>,
) -> Result<&'a TemporarySessionDescriptor> {
    if pool_key.is_some() {
        return Err(anyhow!("已保存服务器会话不能通过临时提升接口保存"));
    }
    temporary.ok_or_else(|| anyhow!("会话不是可提升的临时会话"))
}

#[derive(Debug, PartialEq, Eq)]
enum DisconnectDisposition {
    Pool,
    Close,
}

fn disconnect_disposition(pool_key: Option<&str>) -> DisconnectDisposition {
    if pool_key.is_some() {
        DisconnectDisposition::Pool
    } else {
        DisconnectDisposition::Close
    }
}

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
    pool_key: SessionPoolKey,
    temporary: Option<TemporarySessionDescriptor>,
}

struct IdleSession {
    guard: transport::SessionGuard,
    session_lock: Arc<std::sync::Mutex<()>>,
}

fn notify_channel_closed(channel_id: &str, running: &AtomicBool, closed_cb: &ClosedCallback) {
    running.store(false, Ordering::Release);
    closed_cb(channel_id);
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
                    notify_channel_closed(&sid, &run, &closed_cb);
                    break;
                }
                Err(e) => {
                    if e.kind() == std::io::ErrorKind::WouldBlock {
                        std::thread::sleep(idle_sleep);
                        idle_sleep = std::cmp::min(idle_sleep * 2, MAX_IDLE_SLEEP);
                        continue;
                    }
                    warn!(session_id = %sid, error = %e, "SSH channel 读取错误");
                    notify_channel_closed(&sid, &run, &closed_cb);
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
        pool_key: Option<String>,
        temporary: Option<TemporarySessionDescriptor>,
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
                pool_key,
                temporary,
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

    /// Applies a keepalive change to every live terminal session.
    pub fn set_keepalive_all(&mut self, seconds: u32) {
        for shared in self.sessions.values_mut() {
            let _ = transport::apply_keepalive(&mut shared.guard.session, seconds);
        }
        for idle in self.idle_pool.values_mut().flatten() {
            let _ = transport::apply_keepalive(&mut idle.guard.session, seconds);
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

        self.register_session(
            session_id,
            Some(server.id.clone()),
            None,
            guard,
            active_channel,
            session_lock,
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

    pub fn temporary_descriptor(&self, channel_id: &str) -> Result<TemporarySessionDescriptor> {
        let session_key = self
            .channel_to_session
            .get(channel_id)
            .ok_or_else(|| anyhow!("临时会话不存在或已关闭"))?;
        let shared = self
            .sessions
            .get(session_key)
            .ok_or_else(|| anyhow!("临时会话不存在或已关闭"))?;
        let channel = shared
            .channels
            .get(channel_id)
            .ok_or_else(|| anyhow!("临时会话不存在或已关闭"))?;
        if !channel.running.load(Ordering::Acquire) {
            return Err(anyhow!("临时会话不存在或已关闭"));
        }
        Ok(promotable_descriptor(shared.pool_key.as_deref(), shared.temporary.as_ref())?.clone())
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
                match disconnect_disposition(shared.pool_key.as_deref()) {
                    DisconnectDisposition::Pool => {
                        let pool_key = shared.pool_key.expect("pool key checked above");
                        self.idle_pool
                            .entry(pool_key)
                            .or_default()
                            .push(IdleSession {
                                guard: shared.guard,
                                session_lock: shared.session_lock,
                            });
                        info!(channel_id, "SSH 连接已归还连接池");
                    }
                    DisconnectDisposition::Close => {
                        shared.guard.session.set_blocking(true);
                        let _ = shared.guard.session.disconnect(None, "bye", None);
                        info!(channel_id, "非池化 SSH 连接已关闭");
                    }
                }
                drop(shared.temporary);
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
        Self::exec_command_output_with_timeout(pool, server, db, command, 30_000)
    }

    /// Executes a remote command with an explicit read timeout.
    ///
    /// When the timeout elapses the SSH channel is dropped, which makes the
    /// remote sshd terminate the command's process group.
    pub fn exec_command_output_with_timeout(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        command: &str,
        timeout_ms: u32,
    ) -> Result<SshCommandOutput> {
        debug!(server = %server.name, command, timeout_ms, "执行远程命令并检查退出状态");
        let _lease = pool.acquire_scoped(server, db)?;
        let result = pool.with_session_mut(&server.id, |session| {
            let mut channel = session.channel_session()?;
            channel.exec(command)?;
            session.set_timeout(timeout_ms.max(1));

            let mut stdout = String::new();
            let stdout_result = channel.read_to_string(&mut stdout);
            if let Err(error) = stdout_result {
                session.set_timeout(0);
                return Err(error.into());
            }
            let mut stderr = String::new();
            let mut stderr_stream = channel.stderr();
            let stderr_result = stderr_stream.read_to_string(&mut stderr);
            if let Err(error) = stderr_result {
                session.set_timeout(0);
                return Err(error.into());
            }
            let wait_result = channel.wait_close();
            let exit_status_result = channel.exit_status();
            session.set_timeout(0);

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
    fn saved_session_is_poolable_but_temporary_session_is_not() {
        assert_eq!(
            disconnect_disposition(Some("server-1")),
            DisconnectDisposition::Pool
        );
        assert_eq!(disconnect_disposition(None), DisconnectDisposition::Close);
    }

    #[test]
    fn temporary_descriptor_contains_no_secret_fields() {
        let descriptor =
            TemporarySessionDescriptor::new("host", 22, "alice", "password", None, None);
        let debug = format!("{descriptor:?}");
        assert!(!debug.contains("password_value"));
        assert!(!debug.contains("private_key"));
    }

    #[test]
    fn temporary_promotion_descriptor_requires_non_poolable_temporary_state() {
        let descriptor =
            TemporarySessionDescriptor::new("host", 22, "alice", "password", None, None);
        assert!(promotable_descriptor(None, Some(&descriptor)).is_ok());
        assert!(promotable_descriptor(Some("saved-1"), Some(&descriptor)).is_err());
        assert!(promotable_descriptor(None, None).is_err());
    }

    #[test]
    fn temporary_promotion_close_callback_observes_stopped_channel() {
        let running = Arc::new(AtomicBool::new(true));
        let observed_running = Arc::new(AtomicBool::new(true));
        let callback_running = running.clone();
        let callback_observation = observed_running.clone();
        let closed_cb: ClosedCallback = Box::new(move |_| {
            callback_observation.store(callback_running.load(Ordering::Acquire), Ordering::Relaxed);
        });

        notify_channel_closed("temporary-session", &running, &closed_cb);

        assert!(!observed_running.load(Ordering::Relaxed));
    }

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
