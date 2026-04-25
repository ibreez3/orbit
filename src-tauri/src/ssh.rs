use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::models::Server;
use crate::db::Database;
use crate::transport;

#[derive(Serialize, Clone)]
pub struct TrafficStats {
    pub bytes_read: u64,
    pub bytes_written: u64,
}

struct ActiveSession {
    guard: transport::SessionGuard,
    channel: Arc<std::sync::Mutex<ssh2::Channel>>,
    running: Arc<AtomicBool>,
    reader_handle: Option<std::thread::JoinHandle<()>>,
    bytes_read: Arc<AtomicU64>,
    bytes_written: Arc<AtomicU64>,
}

pub struct SshManager {
    sessions: HashMap<String, ActiveSession>,
}

impl SshManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
        }
    }

    pub fn connect(
        &mut self,
        session_id: &str,
        server: &Server,
        db: &Database,
        app_handle: AppHandle,
    ) -> Result<()> {
        let guard = transport::create_session(server, db)?;
        let mut channel = guard.session.channel_session()?;
        channel.request_pty("xterm-256color", None, None)?;
        channel.shell()?;
        guard.session.set_blocking(false);
        self.spawn_reader_and_insert(session_id, guard, channel, app_handle)
    }

    fn spawn_reader_and_insert(
        &mut self,
        session_id: &str,
        guard: transport::SessionGuard,
        channel: ssh2::Channel,
        app_handle: AppHandle,
    ) -> Result<()> {
        let channel = Arc::new(std::sync::Mutex::new(channel));
        let running = Arc::new(AtomicBool::new(true));
        let bytes_read = Arc::new(AtomicU64::new(0));
        let bytes_written = Arc::new(AtomicU64::new(0));
        let sid = session_id.to_string();
        let ch = channel.clone();
        let run = running.clone();
        let br = bytes_read.clone();
        let handle = app_handle.clone();

        let reader_handle = std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            while run.load(Ordering::Relaxed) {
                let mut ch = match ch.lock() {
                    Ok(g) => g,
                    Err(_) => {
                        std::thread::sleep(Duration::from_millis(10));
                        continue;
                    }
                };
                match ch.read(&mut buf) {
                    Ok(n) if n > 0 => {
                        let data: Vec<u8> = buf[..n].to_vec();
                        br.fetch_add(n as u64, Ordering::Relaxed);
                        let _ = handle.emit(&format!("ssh-data-{}", sid), data);
                    }
                    Ok(_) => {
                        let _ = handle.emit(&format!("ssh-closed-{}", sid), ());
                        run.store(false, Ordering::Relaxed);
                        break;
                    }
                    Err(e) => {
                        if e.kind() == std::io::ErrorKind::WouldBlock {
                            drop(ch);
                            std::thread::sleep(Duration::from_millis(5));
                            continue;
                        }
                        run.store(false, Ordering::Relaxed);
                        break;
                    }
                }
            }
        });

        self.sessions.insert(
            session_id.to_string(),
            ActiveSession {
                guard,
                channel,
                running,
                reader_handle: Some(reader_handle),
                bytes_read,
                bytes_written,
            },
        );
        Ok(())
    }

    pub fn write(&self, session_id: &str, data: &[u8]) -> Result<()> {
        let s = self.sessions.get(session_id).ok_or_else(|| anyhow!("会话不存在"))?;
        let mut ch = s.channel.lock().map_err(|_| anyhow!("通道锁定失败"))?;
        ch.write_all(data)?;
        s.bytes_written.fetch_add(data.len() as u64, Ordering::Relaxed);
        Ok(())
    }

    pub fn resize(&self, session_id: &str, cols: u32, rows: u32) -> Result<()> {
        let s = self.sessions.get(session_id).ok_or_else(|| anyhow!("会话不存在"))?;
        let mut ch = s.channel.lock().map_err(|_| anyhow!("通道锁定失败"))?;
        ch.request_pty_size(cols, rows, None, None)?;
        Ok(())
    }

    pub fn get_traffic(&self, session_id: &str) -> Result<TrafficStats> {
        let s = self.sessions.get(session_id).ok_or_else(|| anyhow!("会话不存在"))?;
        Ok(TrafficStats {
            bytes_read: s.bytes_read.load(Ordering::Relaxed),
            bytes_written: s.bytes_written.load(Ordering::Relaxed),
        })
    }

    pub fn disconnect(&mut self, session_id: &str) -> Result<()> {
        if let Some(mut s) = self.sessions.remove(session_id) {
            s.running.store(false, Ordering::Relaxed);
            if let Some(h) = s.reader_handle.take() {
                let _ = h.join();
            }
            let _ = s.guard.session.disconnect(None, "bye", None);
        }
        Ok(())
    }

    pub fn exec_command(
        pool: &transport::SessionPool,
        server: &Server,
        db: &Database,
        command: &str,
    ) -> Result<String> {
        pool.acquire(server, db)?;
        let result = pool.with_session_mut(&server.id, |session| {
            let mut channel = session.channel_session()?;
            channel.exec(command)?;
            let mut output = String::new();
            channel.read_to_string(&mut output)?;
            Ok(output)
        });
        pool.release(&server.id);
        result
    }
}

impl Drop for SshManager {
    fn drop(&mut self) {
        for (_, mut s) in self.sessions.drain() {
            s.running.store(false, Ordering::Relaxed);
            if let Some(h) = s.reader_handle.take() {
                let _ = h.join();
            }
            let _ = s.guard.session.disconnect(None, "bye", None);
        }
    }
}
