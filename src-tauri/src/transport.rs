use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use ssh2::Session;
use tracing::{debug, info, warn, error, instrument};

use crate::db::Database;
use crate::models::{CredentialGroup, ResolvedAuth, Server};

pub struct ProxyGuard {
    handle: Option<std::thread::JoinHandle<()>>,
    running: std::sync::Arc<AtomicBool>,
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

#[instrument(skip(db), fields(server = %server.name))]
pub fn create_session(server: &Server, db: &Database) -> Result<SessionGuard> {
    if server.jump_server_id.is_empty() {
        info!(host = %server.host, port = server.port, "直连服务器");
        create_direct_session(server, db)
    } else {
        info!(host = %server.host, port = server.port, jump_id = %server.jump_server_id, "通过跳板机连接");
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

#[instrument(skip(db, session), fields(username = %server.username))]
fn authenticate_session(server: &Server, db: &Database, session: &mut Session) -> Result<()> {
    let group = resolve_group(db, server)?;
    let auth = ResolvedAuth::resolve(server, group.as_ref())?;
    auth.authenticate(session)?;
    if !session.authenticated() {
        return Err(anyhow!("认证失败"));
    }
    debug!("认证成功");
    Ok(())
}

#[instrument(skip(db), fields(host = %server.host, port = server.port))]
fn create_direct_session(server: &Server, db: &Database) -> Result<SessionGuard> {
    let tcp = TcpStream::connect((server.host.as_str(), server.port))
        .map_err(|e| {
            error!(error = %e, "TCP 连接失败");
            anyhow!("连接失败 {}:{} - 请检查主机地址和端口是否正确，以及网络是否可达", server.host, server.port)
        })?;
    tcp.set_nonblocking(false)?;
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.handshake().map_err(|e| {
        error!(error = %e, "SSH 握手失败");
        anyhow!("SSH 握手失败 {}:{} - {}", server.host, server.port, e)
    })?;
    authenticate_session(server, db, &mut session)?;
    info!("直连会话建立成功");
    Ok(SessionGuard { session, _proxy: None })
}

#[instrument(skip(db), fields(host = %server.host, port = server.port))]
fn create_jump_session(server: &Server, db: &Database) -> Result<SessionGuard> {
    let jump_server = db.get_server(&server.jump_server_id)
        .map_err(|e| {
            error!(jump_id = %server.jump_server_id, error = %e, "跳板机服务器不存在");
            anyhow!("跳板机服务器不存在 (id: {})", server.jump_server_id)
        })?;

    info!(jump_host = %jump_server.host, jump_port = jump_server.port, "连接跳板机");
    let jump_tcp = TcpStream::connect((jump_server.host.as_str(), jump_server.port))
        .map_err(|e| {
            error!(jump_host = %jump_server.host, error = %e, "跳板机 TCP 连接失败");
            anyhow!("跳板机连接失败 {}:{} - 请检查跳板机地址和网络", jump_server.host, jump_server.port)
        })?;
    jump_tcp.set_nonblocking(false)?;
    let mut jump_session = Session::new()?;
    jump_session.set_tcp_stream(jump_tcp);
    jump_session.handshake().map_err(|e| {
        error!(error = %e, "跳板机 SSH 握手失败");
        anyhow!("跳板机 SSH 握手失败: {}", e)
    })?;
    authenticate_session(&jump_server, db, &mut jump_session)?;
    jump_session.set_blocking(true);

    info!(target = format!("{}:{}", server.host, server.port), "建立 TCP 转发隧道");
    let tunnel = jump_session.channel_direct_tcpip(
        server.host.as_str(), server.port, None,
    ).map_err(|e| {
        let err_str = e.to_string();
        let msg = if err_str.contains("denied") || err_str.contains("not allowed") || err_str.contains("forwarding") {
            error!("跳板机拒绝 TCP 转发，可能未开启 AllowTcpForwarding");
            format!(
                "跳板机 TCP 转发被拒绝 ({}:{}) - 跳板机 sshd_config 需要开启 AllowTcpForwarding yes",
                server.host, server.port
            )
        } else if err_str.contains("timed out") || err_str.contains("timeout") {
            error!(target = format!("{}:{}", server.host, server.port), "目标服务器不可达");
            format!(
                "通过跳板机连接目标 {}:{} 超时 - 请检查目标地址是否正确，以及跳板机能否访问该地址",
                server.host, server.port
            )
        } else if err_str.contains("refused") || err_str.contains("Connection refused") {
            error!(target = format!("{}:{}", server.host, server.port), "目标服务器拒绝连接");
            format!(
                "目标服务器 {}:{} 拒绝连接 - 请检查目标 SSH 服务是否运行",
                server.host, server.port
            )
        } else {
            error!(error = %err_str, "隧道建立失败");
            format!("跳板机隧道建立失败 {}:{} - {}", server.host, server.port, err_str)
        };
        anyhow!("{}", msg)
    })?;

    let (proxy_port, proxy_handle, proxy_running) = start_local_proxy(tunnel, jump_session);
    debug!(proxy_port, "本地代理已启动");

    let tcp = TcpStream::connect(("127.0.0.1", proxy_port))
        .map_err(|e| {
            error!(proxy_port, error = %e, "连接本地代理失败");
            anyhow!("连接本地代理失败: {}", e)
        })?;
    tcp.set_nonblocking(false)?;
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.handshake().map_err(|e| {
        error!(error = %e, "目标服务器握手失败");
        anyhow!("目标服务器握手失败 - 请确认跳板机能够访问 {}:{} ({})", server.host, server.port, e)
    })?;
    authenticate_session(server, db, &mut session)?;

    info!("跳板机会话建立成功");
    Ok(SessionGuard {
        session,
        _proxy: Some(ProxyGuard {
            handle: Some(proxy_handle),
            running: proxy_running,
        }),
    })
}

fn start_local_proxy(tunnel: ssh2::Channel, keep_alive: Session) -> (u16, std::thread::JoinHandle<()>, std::sync::Arc<AtomicBool>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("无法绑定本地代理端口");
    let proxy_port = listener.local_addr().unwrap().port();
    let running = std::sync::Arc::new(AtomicBool::new(true));
    let run = running.clone();

    let handle = std::thread::spawn(move || {
        let (mut local_tcp, _) = match listener.accept() {
            Ok(s) => s,
            Err(e) => {
                warn!(error = %e, "代理线程 accept 失败");
                return;
            }
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
                            Err(e) => {
                                debug!(error = %e, "代理写入 local_tcp 失败，退出");
                                run.store(false, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                }
                Ok(_) => {
                    debug!("隧道 EOF，代理退出");
                    run.store(false, Ordering::Relaxed);
                    return;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => {
                    debug!(error = %e, "隧道读取失败，代理退出");
                    run.store(false, Ordering::Relaxed);
                    return;
                }
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
                            Err(e) => {
                                debug!(error = %e, "代理写入隧道失败，退出");
                                run.store(false, Ordering::Relaxed);
                                return;
                            }
                        }
                    }
                }
                Ok(_) => {
                    debug!("local_tcp EOF，代理退出");
                    run.store(false, Ordering::Relaxed);
                    return;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => {
                    debug!(error = %e, "local_tcp 读取失败，代理退出");
                    run.store(false, Ordering::Relaxed);
                    return;
                }
            }

            if !did_work {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    });

    (proxy_port, handle, running)
}

struct PooledEntry {
    guard: SessionGuard,
    last_used: Instant,
    ref_count: usize,
}

pub struct SessionPool {
    inner: Mutex<HashMap<String, PooledEntry>>,
}

impl SessionPool {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    pub fn acquire(&self, server: &Server, db: &Database) -> Result<()> {
        let mut pool = self.inner.lock().map_err(|_| anyhow!("连接池锁定失败"))?;
        if let Some(entry) = pool.get_mut(&server.id) {
            if entry.guard.session.authenticated() {
                entry.last_used = Instant::now();
                entry.ref_count += 1;
                debug!(server_id = %server.id, ref_count = entry.ref_count, "复用连接池会话");
                return Ok(());
            }
            warn!(server_id = %server.id, "连接池会话已失效，重新创建");
            pool.remove(&server.id);
        }
        let guard = create_session(server, db)?;
        pool.insert(
            server.id.clone(),
            PooledEntry {
                guard,
                last_used: Instant::now(),
                ref_count: 1,
            },
        );
        debug!(server_id = %server.id, "新建连接池会话");
        Ok(())
    }

    #[allow(dead_code)]
    pub fn with_session<F, T>(&self, server_id: &str, f: F) -> Result<T>
    where
        F: FnOnce(&Session) -> Result<T>,
    {
        let pool = self.inner.lock().map_err(|_| anyhow!("连接池锁定失败"))?;
        let entry = pool.get(server_id).ok_or_else(|| anyhow!("连接池中无此服务器会话"))?;
        f(&entry.guard.session)
    }

    pub fn with_session_mut<F, T>(&self, server_id: &str, f: F) -> Result<T>
    where
        F: FnOnce(&mut Session) -> Result<T>,
    {
        let mut pool = self.inner.lock().map_err(|_| anyhow!("连接池锁定失败"))?;
        let entry = pool.get_mut(server_id).ok_or_else(|| anyhow!("连接池中无此服务器会话"))?;
        f(&mut entry.guard.session)
    }

    pub fn release(&self, server_id: &str) {
        if let Ok(mut pool) = self.inner.lock() {
            if let Some(entry) = pool.get_mut(server_id) {
                entry.ref_count = entry.ref_count.saturating_sub(1);
                debug!(server_id, ref_count = entry.ref_count, "释放连接池引用");
            }
        }
    }

    pub fn remove(&self, server_id: &str) {
        if let Ok(mut pool) = self.inner.lock() {
            pool.remove(server_id);
            info!(server_id, "连接池会话已移除");
        }
    }

    #[allow(dead_code)]
    pub fn cleanup_idle(&self, timeout: Duration) {
        if let Ok(mut pool) = self.inner.lock() {
            let before = pool.len();
            pool.retain(|id, entry| {
                if entry.ref_count > 0 || entry.last_used.elapsed() < timeout {
                    true
                } else {
                    info!(server_id = %id, idle = ?entry.last_used.elapsed(), "清理空闲连接");
                    false
                }
            });
            let removed = before - pool.len();
            if removed > 0 {
                debug!(removed, remaining = pool.len(), "空闲连接清理完成");
            }
        }
    }
}
