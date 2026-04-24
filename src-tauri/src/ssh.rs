use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use ssh2::Session;
use tauri::{AppHandle, Emitter};

use crate::models::Server;

struct ActiveSession {
    session: Session,
    channel: Arc<std::sync::Mutex<ssh2::Channel>>,
    running: Arc<AtomicBool>,
    reader_handle: Option<std::thread::JoinHandle<()>>,
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
        app_handle: AppHandle,
    ) -> Result<()> {
        let tcp = TcpStream::connect((server.host.as_str(), server.port))
            .map_err(|e| anyhow!("连接失败 {}:{}", server.host, server.port))?;
        tcp.set_nonblocking(false)?;

        let mut session = Session::new()?;
        session.set_tcp_stream(tcp);
        session.handshake()?;

        match server.auth_type.as_str() {
            "password" => {
                session
                    .userauth_password(&server.username, &server.password)
                    .map_err(|_| anyhow!("密码认证失败"))?;
            }
            "key" => {
                if server.private_key.is_empty() {
                    return Err(anyhow!("私钥内容为空"));
                }
                let passphrase = if server.key_passphrase.is_empty() {
                    None
                } else {
                    Some(server.key_passphrase.as_str())
                };
                session
                    .userauth_pubkey_memory(
                        &server.username,
                        None,
                        &server.private_key,
                        passphrase,
                    )
                    .map_err(|e| anyhow!("密钥认证失败: {}", e))?;
            }
            _ => return Err(anyhow!("不支持的认证类型: {}", server.auth_type)),
        }

        if !session.authenticated() {
            return Err(anyhow!("认证失败"));
        }

        let mut channel = session.channel_session()?;
        channel.request_pty("xterm-256color", None, None)?;
        channel.shell()?;

        session.set_blocking(false);

        let channel = Arc::new(std::sync::Mutex::new(channel));
        let running = Arc::new(AtomicBool::new(true));

        let sid = session_id.to_string();
        let ch = channel.clone();
        let run = running.clone();
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
                session,
                channel,
                running,
                reader_handle: Some(reader_handle),
            },
        );

        Ok(())
    }

    pub fn write(&self, session_id: &str, data: &[u8]) -> Result<()> {
        let s = self
            .sessions
            .get(session_id)
            .ok_or_else(|| anyhow!("会话不存在: {}", session_id))?;
        let mut ch = s.channel.lock().map_err(|_| anyhow!("通道锁定失败"))?;
        ch.write_all(data)?;
        Ok(())
    }

    pub fn resize(&self, session_id: &str, cols: u32, rows: u32) -> Result<()> {
        let s = self
            .sessions
            .get(session_id)
            .ok_or_else(|| anyhow!("会话不存在: {}", session_id))?;
        let mut ch = s.channel.lock().map_err(|_| anyhow!("通道锁定失败"))?;
        ch.request_pty_size(cols, rows, None, None)?;
        Ok(())
    }

    pub fn disconnect(&mut self, session_id: &str) -> Result<()> {
        if let Some(mut s) = self.sessions.remove(session_id) {
            s.running.store(false, Ordering::Relaxed);
            if let Some(h) = s.reader_handle.take() {
                let _ = h.join();
            }
            let _ = s.session.disconnect(None, "bye", None);
        }
        Ok(())
    }

    pub fn exec_command(&self, server: &Server, command: &str) -> Result<String> {
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

        let mut channel = session.channel_session()?;
        channel.exec(command)?;
        let mut output = String::new();
        channel.read_to_string(&mut output)?;
        Ok(output)
    }
}

impl Drop for SshManager {
    fn drop(&mut self) {
        for (_, mut s) in self.sessions.drain() {
            s.running.store(false, Ordering::Relaxed);
            if let Some(h) = s.reader_handle.take() {
                let _ = h.join();
            }
            let _ = s.session.disconnect(None, "bye", None);
        }
    }
}
