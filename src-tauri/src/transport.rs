use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use ssh2::Session;

use crate::db::Database;
use crate::models::{CredentialGroup, ResolvedAuth, Server};

pub struct ProxyGuard {
    handle: Option<std::thread::JoinHandle<()>>,
    running: Arc<AtomicBool>,
}

impl Drop for ProxyGuard {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

pub struct SessionGuard {
    pub session: Session,
    _proxy: Option<ProxyGuard>,
}

pub fn create_session(server: &Server, db: &Database) -> Result<SessionGuard> {
    if server.jump_server_id.is_empty() {
        create_direct_session(server, db)
    } else {
        create_jump_session(server, db)
    }
}

fn resolve_group(db: &Database, server: &Server) -> Result<Option<CredentialGroup>> {
    if server.credential_group_id.is_empty() {
        return Ok(None);
    }
    db.get_credential_group(&server.credential_group_id)
        .map(Some)
        .map_err(|e| anyhow!("凭据分组加载失败: {}", e))
}

fn authenticate_session(server: &Server, db: &Database, session: &mut Session) -> Result<()> {
    let group = resolve_group(db, server)?;
    let auth = ResolvedAuth::resolve(server, group.as_ref())?;
    auth.authenticate(session)?;
    if !session.authenticated() {
        return Err(anyhow!("认证失败"));
    }
    Ok(())
}

fn create_direct_session(server: &Server, db: &Database) -> Result<SessionGuard> {
    let tcp = TcpStream::connect((server.host.as_str(), server.port))
        .map_err(|_| anyhow!("连接失败 {}:{}", server.host, server.port))?;
    tcp.set_nonblocking(false)?;
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.handshake()?;
    authenticate_session(server, db, &mut session)?;
    Ok(SessionGuard { session, _proxy: None })
}

fn create_jump_session(server: &Server, db: &Database) -> Result<SessionGuard> {
    let jump_server = db.get_server(&server.jump_server_id)
        .map_err(|_| anyhow!("跳板机服务器不存在 (id: {})", server.jump_server_id))?;

    let jump_tcp = TcpStream::connect((jump_server.host.as_str(), jump_server.port))
        .map_err(|_| anyhow!("跳板机连接失败 {}:{}", jump_server.host, jump_server.port))?;
    jump_tcp.set_nonblocking(false)?;
    let mut jump_session = Session::new()?;
    jump_session.set_tcp_stream(jump_tcp);
    jump_session.handshake()?;
    authenticate_session(&jump_server, db, &mut jump_session)?;
    jump_session.set_blocking(true);

    let tunnel = jump_session.channel_direct_tcpip(
        server.host.as_str(), server.port, None,
    ).map_err(|e| anyhow!("跳板机隧道建立失败 {}:{} - {}", server.host, server.port, e))?;

    let (proxy_port, proxy_handle, proxy_running) = start_local_proxy(tunnel, jump_session);

    let tcp = TcpStream::connect(("127.0.0.1", proxy_port))
        .map_err(|e| anyhow!("连接本地代理失败: {}", e))?;
    tcp.set_nonblocking(false)?;
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.handshake()
        .map_err(|e| anyhow!("目标服务器握手失败: {}", e))?;
    authenticate_session(server, db, &mut session)?;

    Ok(SessionGuard {
        session,
        _proxy: Some(ProxyGuard {
            handle: Some(proxy_handle),
            running: proxy_running,
        }),
    })
}

fn start_local_proxy(tunnel: ssh2::Channel, keep_alive: Session) -> (u16, std::thread::JoinHandle<()>, Arc<AtomicBool>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("无法绑定本地代理端口");
    let proxy_port = listener.local_addr().unwrap().port();
    let running = Arc::new(AtomicBool::new(true));
    let run = running.clone();

    let handle = std::thread::spawn(move || {
        let (mut local_tcp, _) = match listener.accept() {
            Ok(s) => s,
            Err(_) => return,
        };
        drop(listener);

        keep_alive.set_blocking(false);
        local_tcp.set_nonblocking(true).ok();

        let mut tunnel = tunnel;
        let mut buf_up = [0u8; 32768];
        let mut buf_down = [0u8; 32768];

        while run.load(Ordering::Relaxed) {
            let mut did_work = false;

            match tunnel.read(&mut buf_down) {
                Ok(n) if n > 0 => {
                    did_work = true;
                    let mut written = 0;
                    while written < n {
                        match local_tcp.write(&buf_down[written..n]) {
                            Ok(w) => written += w,
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                std::thread::sleep(Duration::from_micros(500));
                                continue;
                            }
                            Err(_) => { run.store(false, Ordering::Relaxed); return; }
                        }
                    }
                }
                Ok(_) => { run.store(false, Ordering::Relaxed); return; }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => { run.store(false, Ordering::Relaxed); return; }
            }

            match local_tcp.read(&mut buf_up) {
                Ok(n) if n > 0 => {
                    did_work = true;
                    let mut written = 0;
                    while written < n {
                        match tunnel.write(&buf_up[written..n]) {
                            Ok(w) => written += w,
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                std::thread::sleep(Duration::from_micros(500));
                                continue;
                            }
                            Err(_) => { run.store(false, Ordering::Relaxed); return; }
                        }
                    }
                }
                Ok(_) => { run.store(false, Ordering::Relaxed); return; }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => { run.store(false, Ordering::Relaxed); return; }
            }

            if !did_work {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    });

    (proxy_port, handle, running)
}
