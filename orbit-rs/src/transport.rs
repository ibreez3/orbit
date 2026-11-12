use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use ssh2::Session;
use tracing::{debug, error, info, instrument, warn};

use crate::db::Database;
use crate::models::{CredentialGroup, ResolvedAuth, Server};

const DEFAULT_CONNECT_TIMEOUT_SECS: u64 = 10;
const DEFAULT_KEEPALIVE_SECS: u32 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionSettings {
    pub connect_timeout: Duration,
    pub keepalive_seconds: u32,
}

impl Default for ConnectionSettings {
    fn default() -> Self {
        Self {
            connect_timeout: Duration::from_secs(DEFAULT_CONNECT_TIMEOUT_SECS),
            keepalive_seconds: DEFAULT_KEEPALIVE_SECS,
        }
    }
}

static CONNECTION_SETTINGS: Mutex<ConnectionSettings> = Mutex::new(ConnectionSettings {
    connect_timeout: Duration::from_secs(DEFAULT_CONNECT_TIMEOUT_SECS),
    keepalive_seconds: DEFAULT_KEEPALIVE_SECS,
});

/// Applies the user's SSH preferences to every future connection.
///
/// The values are clamped so a malformed preference can never produce a
/// zero-length timeout or an absurd keepalive interval.
pub fn set_connection_settings(timeout_seconds: u32, keepalive_seconds: u32) -> ConnectionSettings {
    let settings = ConnectionSettings {
        connect_timeout: Duration::from_secs(timeout_seconds.clamp(1, 300) as u64),
        keepalive_seconds: keepalive_seconds.min(3600),
    };
    if let Ok(mut current) = CONNECTION_SETTINGS.lock() {
        *current = settings;
    }
    settings
}

pub fn connection_settings() -> ConnectionSettings {
    CONNECTION_SETTINGS
        .lock()
        .map(|settings| *settings)
        .unwrap_or_default()
}

fn stage_timeout_ms(settings: ConnectionSettings) -> u32 {
    settings
        .connect_timeout
        .as_millis()
        .min(u32::MAX as u128) as u32
}

/// Applies keepalive to a live session. A zero interval disables it.
pub fn apply_keepalive(session: &mut Session, seconds: u32) {
    if seconds == 0 {
        session.set_keepalive(false, 0);
    } else {
        session.set_keepalive(true, seconds);
    }
}

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

#[cfg(test)]
mod timeout_tests {
    use super::{
        connect_tcp_with_timeout, connection_settings, create_session, set_connection_settings,
    };
    use crate::db::Database;
    use crate::models::ServerInput;
    use std::net::TcpListener;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    static SETTINGS_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn connects_to_local_listener() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let _ = listener.accept();
        });

        let stream = connect_tcp_with_timeout("127.0.0.1", port, Duration::from_secs(1)).unwrap();

        assert!(stream.peer_addr().is_ok());
    }

    #[test]
    fn unroutable_address_fails_within_timeout() {
        let started = Instant::now();

        let result = connect_tcp_with_timeout("192.0.2.1", 22, Duration::from_millis(300));

        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn connection_settings_are_clamped_and_readable() {
        let _lock = SETTINGS_TEST_LOCK.lock().unwrap();
        let original = connection_settings();
        let clamped = set_connection_settings(0, u32::MAX);
        assert_eq!(clamped.connect_timeout, Duration::from_secs(1));
        assert_eq!(clamped.keepalive_seconds, 3600);
        assert_eq!(connection_settings(), clamped);

        let updated = set_connection_settings(45, 0);
        assert_eq!(updated.connect_timeout, Duration::from_secs(45));
        assert_eq!(updated.keepalive_seconds, 0);

        set_connection_settings(
            original.connect_timeout.as_secs() as u32,
            original.keepalive_seconds,
        );
    }

    #[test]
    fn handshake_uses_configured_connect_timeout() {
        let _lock = SETTINGS_TEST_LOCK.lock().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            if let Ok((stream, _)) = listener.accept() {
                std::thread::sleep(Duration::from_secs(2));
                drop(stream);
            }
        });

        let db = Database::new(":memory:").unwrap();
        let saved = db
            .add_server(&ServerInput {
                name: "slow-handshake".into(),
                host: "127.0.0.1".into(),
                port: Some(port),
                group_name: None,
                auth_type: Some("password".into()),
                username: "tester".into(),
                password: Some("secret".into()),
                private_key: None,
                key_source: None,
                key_file_path: None,
                key_passphrase: None,
                credential_group_id: None,
                jump_server_id: None,
                folder_id: None,
            })
            .unwrap();
        let server = db.get_server(&saved.id).unwrap();

        let original = connection_settings();
        set_connection_settings(1, 0);
        let started = Instant::now();
        let result = create_session(&server, &db);
        let elapsed = started.elapsed();
        set_connection_settings(
            original.connect_timeout.as_secs() as u32,
            original.keepalive_seconds,
        );

        assert!(result.is_err());
        assert!(
            elapsed >= Duration::from_millis(800),
            "handshake returned too early: {:?}",
            elapsed
        );
        assert!(
            elapsed < Duration::from_secs(4),
            "configured timeout was not applied: {:?}",
            elapsed
        );
    }

    #[test]
    #[ignore]
    fn real_server_smoke_from_env() {
        use super::{create_session, Database};
        use crate::models::ServerInput;

        let host = std::env::var("ORBIT_TEST_HOST").expect("ORBIT_TEST_HOST");
        let user = std::env::var("ORBIT_TEST_USER").expect("ORBIT_TEST_USER");
        let password = std::env::var("ORBIT_TEST_PASSWORD").expect("ORBIT_TEST_PASSWORD");

        let db = Database::new(":memory:").unwrap();
        let saved = db
            .add_server(&ServerInput {
                name: "real-server".into(),
                host,
                port: Some(22),
                group_name: None,
                auth_type: Some("password".into()),
                username: user.clone(),
                password: Some(password.clone()),
                private_key: None,
                key_source: None,
                key_file_path: None,
                key_passphrase: None,
                credential_group_id: None,
                jump_server_id: None,
                folder_id: None,
            })
            .unwrap();
        let server = db.get_server(&saved.id).unwrap();

        let guard = create_session(&server, &db).expect("connect to real server");
        assert!(guard.session.authenticated());
        drop(guard);

        let pool = super::SessionPool::new();
        let whoami = crate::ssh::SshManager::exec_command_checked(
            &pool, &server, &db, "whoami", "whoami",
        )
        .expect("whoami");
        println!("whoami: {}", whoami.trim());
        assert_eq!(whoami.trim(), user);

        let entries = crate::sftp::SftpManager::list_dir_full(&pool, &server, &db, ".")
            .expect("sftp list");
        println!("sftp entries: {}", entries.len());
        assert!(!entries.is_empty());

        let stamp = format!("{}", chrono::Utc::now().timestamp_millis());
        let remote = format!("/tmp/orbit-smoke-{}.txt", stamp);
        let local = std::env::temp_dir().join(format!("orbit-smoke-{}.txt", stamp));
        let downloaded = std::env::temp_dir().join(format!("orbit-smoke-{}-down.txt", stamp));
        std::fs::write(&local, "ORBIT_SFTP_CONTENT").unwrap();
        crate::sftp::SftpManager::upload_file(
            &pool,
            &server,
            &db,
            local.to_str().unwrap(),
            &remote,
            None,
        )
        .expect("sftp upload");
        let text = crate::sftp::SftpManager::read_text_file(&pool, &server, &db, &remote, 1024)
            .expect("sftp read");
        assert_eq!(text, "ORBIT_SFTP_CONTENT");
        crate::sftp::SftpManager::download_file(
            &pool,
            &server,
            &db,
            &remote,
            downloaded.to_str().unwrap(),
            None,
        )
        .expect("sftp download");
        assert_eq!(
            std::fs::read_to_string(&downloaded).unwrap(),
            "ORBIT_SFTP_CONTENT"
        );
        crate::sftp::SftpManager::remove(&pool, &server, &db, &remote, false)
            .expect("sftp remove");
        let _ = std::fs::remove_file(&local);
        let _ = std::fs::remove_file(&downloaded);
        println!("sftp upload/read/download/remove ok");

        let stats_output = crate::ssh::SshManager::exec_command_output(
            &pool,
            &server,
            &db,
            crate::monitor::get_monitor_script(),
        )
        .expect("monitor script");
        let stats = crate::monitor::collect_stats(&stats_output.stdout).expect("parse stats");
        println!(
            "stats: cpu={} mem={}% disk={}% uptime={}",
            stats.cpu_usage, stats.mem_percent, stats.disk_percent, stats.uptime
        );

        let process_output = crate::ssh::SshManager::exec_command_output(
            &pool,
            &server,
            &db,
            crate::monitor::get_process_script(),
        )
        .expect("process script");
        let processes = crate::monitor::parse_processes(&process_output.stdout);
        println!("processes: {}", processes.len());
        assert!(!processes.is_empty());

        let bad = db
            .add_server(&ServerInput {
                name: "wrong-password".into(),
                host: server.host.clone(),
                port: Some(22),
                group_name: None,
                auth_type: Some("password".into()),
                username: user,
                password: Some("ORBIT_WRONG_PASSWORD".into()),
                private_key: None,
                key_source: None,
                key_file_path: None,
                key_passphrase: None,
                credential_group_id: None,
                jump_server_id: None,
                folder_id: None,
            })
            .unwrap();
        let bad_server = db.get_server(&bad.id).unwrap();
        let error = match create_session(&bad_server, &db) {
            Ok(_) => panic!("wrong password unexpectedly connected"),
            Err(error) => format!("{error}"),
        };
        println!("wrong password error: {error}");
        assert!(!error.contains("ORBIT_WRONG_PASSWORD"));
    }

    #[test]
    #[ignore]
    fn real_server_jump_host_from_env() {
        use super::{create_session, Database, SessionPool};
        use crate::models::{ServerInput, Server};

        fn input(
            name: &str,
            host: &str,
            user: &str,
            password: &str,
            jump_server_id: Option<String>,
        ) -> ServerInput {
            ServerInput {
                name: name.into(),
                host: host.into(),
                port: Some(22),
                group_name: None,
                auth_type: Some("password".into()),
                username: user.into(),
                password: Some(password.into()),
                private_key: None,
                key_source: None,
                key_file_path: None,
                key_passphrase: None,
                credential_group_id: None,
                jump_server_id,
                folder_id: None,
            }
        }

        let host = std::env::var("ORBIT_TEST_HOST").expect("ORBIT_TEST_HOST");
        let user = std::env::var("ORBIT_TEST_USER").expect("ORBIT_TEST_USER");
        let password = std::env::var("ORBIT_TEST_PASSWORD").expect("ORBIT_TEST_PASSWORD");

        let db = Database::new(":memory:").unwrap();
        let jump = db
            .add_server(&input("jump", &host, &user, &password, None))
            .unwrap();
        let target = db
            .add_server(&input(
                "target",
                "127.0.0.1",
                &user,
                &password,
                Some(jump.id.clone()),
            ))
            .unwrap();
        let target: Server = db.get_server(&target.id).unwrap();

        let guard = create_session(&target, &db).expect("jump-host session");
        assert!(guard.session.authenticated());
        drop(guard);

        let pool = SessionPool::new();
        let whoami = crate::ssh::SshManager::exec_command_checked(
            &pool,
            &target,
            &db,
            "whoami",
            "whoami via jump",
        )
        .expect("whoami via jump host");
        println!("jump host whoami: {}", whoami.trim());
        assert_eq!(whoami.trim(), user);
    }
}

fn connect_tcp_with_timeout(host: &str, port: u16, timeout: Duration) -> Result<TcpStream> {
    let addrs: Vec<SocketAddr> = (host, port)
        .to_socket_addrs()
        .map_err(|error| anyhow!("解析主机失败 {}: {}", host, error))?
        .collect();
    if addrs.is_empty() {
        return Err(anyhow!("主机地址无法解析: {}", host));
    }

    let mut last_error = None;
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, timeout) {
            Ok(stream) => return Ok(stream),
            Err(error) => last_error = Some(error),
        }
    }

    Err(anyhow!(
        "TCP 连接超时或失败 {}:{} - {}",
        host,
        port,
        last_error
            .map(|error| error.to_string())
            .unwrap_or_else(|| "未知错误".to_string())
    ))
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
    let settings = connection_settings();
    let tcp = connect_tcp_with_timeout(&server.host, server.port, settings.connect_timeout)
        .map_err(|e| {
            error!(error = %e, "TCP 连接失败");
            anyhow!(
                "连接失败 {}:{} - 请检查主机地址和端口是否正确，以及网络是否可达",
                server.host,
                server.port
            )
        })?;
    tcp.set_nonblocking(false)?;
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.set_timeout(stage_timeout_ms(settings));
    session.handshake().map_err(|e| {
        error!(error = %e, "SSH 握手失败");
        anyhow!("SSH 握手失败 {}:{} - {}", server.host, server.port, e)
    })?;
    db.host_keys.verify(db, server, &session, "direct")?;
    authenticate_session(server, db, &mut session)?;
    let _ = apply_keepalive(&mut session, settings.keepalive_seconds);
    session.set_timeout(0);
    info!("直连会话建立成功");
    Ok(SessionGuard {
        session,
        _proxy: None,
    })
}

#[instrument(skip(db), fields(host = %server.host, port = server.port))]
fn create_jump_session(server: &Server, db: &Database) -> Result<SessionGuard> {
    let settings = connection_settings();
    let jump_server = db.get_server(&server.jump_server_id).map_err(|e| {
        error!(jump_id = %server.jump_server_id, error = %e, "跳板机服务器不存在");
        anyhow!("跳板机服务器不存在 (id: {})", server.jump_server_id)
    })?;

    info!(jump_host = %jump_server.host, jump_port = jump_server.port, "连接跳板机");
    let jump_tcp = connect_tcp_with_timeout(
        &jump_server.host,
        jump_server.port,
        settings.connect_timeout,
    )
    .map_err(|e| {
        error!(jump_host = %jump_server.host, error = %e, "跳板机 TCP 连接失败");
        anyhow!(
            "跳板机连接失败 {}:{} - 请检查跳板机地址和网络",
            jump_server.host,
            jump_server.port
        )
    })?;
    jump_tcp.set_nonblocking(false)?;
    let mut jump_session = Session::new()?;
    jump_session.set_tcp_stream(jump_tcp);
    jump_session.set_timeout(stage_timeout_ms(settings));
    jump_session.handshake().map_err(|e| {
        error!(error = %e, "跳板机 SSH 握手失败");
        anyhow!("跳板机 SSH 握手失败: {}", e)
    })?;
    db.host_keys.verify(db, &jump_server, &jump_session, "jump")?;
    authenticate_session(&jump_server, db, &mut jump_session)?;
    let _ = apply_keepalive(&mut jump_session, settings.keepalive_seconds);
    jump_session.set_blocking(true);

    info!(
        target = format!("{}:{}", server.host, server.port),
        "建立 TCP 转发隧道"
    );
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

    jump_session.set_timeout(0);
    let (proxy_port, proxy_handle, proxy_running) =
        start_local_proxy(tunnel, jump_session)?;
    let proxy = ProxyGuard {
        handle: Some(proxy_handle),
        running: proxy_running,
    };
    debug!(proxy_port, "本地代理已启动");

    let tcp = connect_tcp_with_timeout("127.0.0.1", proxy_port, settings.connect_timeout)
        .map_err(|e| {
            error!(proxy_port, error = %e, "连接本地代理失败");
            anyhow!("连接本地代理失败: {}", e)
        })?;
    tcp.set_nonblocking(false)?;
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.set_timeout(stage_timeout_ms(settings));
    session.handshake().map_err(|e| {
        error!(error = %e, "目标服务器握手失败");
        anyhow!(
            "目标服务器握手失败 - 请确认跳板机能够访问 {}:{} ({})",
            server.host,
            server.port,
            e
        )
    })?;
    db.host_keys.verify(db, server, &session, "target")?;
    authenticate_session(server, db, &mut session)?;
    let _ = apply_keepalive(&mut session, settings.keepalive_seconds);
    session.set_timeout(0);

    info!("跳板机会话建立成功");
    Ok(SessionGuard {
        session,
        _proxy: Some(proxy),
    })
}

fn start_local_proxy(
    tunnel: ssh2::Channel,
    keep_alive: Session,
) -> Result<(u16, std::thread::JoinHandle<()>, std::sync::Arc<AtomicBool>)> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|error| anyhow!("无法绑定本地代理端口: {}", error))?;
    let proxy_port = listener
        .local_addr()
        .map_err(|error| anyhow!("读取本地代理端口失败: {}", error))?
        .port();
    listener.set_nonblocking(true)?;
    let running = std::sync::Arc::new(AtomicBool::new(true));
    let run = running.clone();

    let handle = std::thread::spawn(move || {
        let (mut local_tcp, _) = loop {
            if !run.load(Ordering::Relaxed) {
                return;
            }
            match listener.accept() {
                Ok(s) => break s,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => {
                    warn!(error = %e, "代理线程 accept 失败");
                    return;
                }
            }
        };
        drop(listener);

        keep_alive.set_blocking(false);
        local_tcp.set_nonblocking(true).ok();

        let mut tunnel = tunnel;
        let mut buf_up = [0u8; 32768];
        let mut buf_down = [0u8; 32768];
        let mut idle_sleep = Duration::from_micros(250);
        const MIN_IDLE_SLEEP: Duration = Duration::from_micros(250);
        const MAX_IDLE_SLEEP: Duration = Duration::from_millis(10);

        while run.load(Ordering::Relaxed) {
            let mut did_work = false;

            match tunnel.read(&mut buf_down) {
                Ok(n) if n > 0 => {
                    did_work = true;
                    let mut written = 0;
                    while written < n && run.load(Ordering::Relaxed) {
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
                    while written < n && run.load(Ordering::Relaxed) {
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

            if did_work {
                idle_sleep = MIN_IDLE_SLEEP;
            } else {
                std::thread::sleep(idle_sleep);
                idle_sleep = std::cmp::min(idle_sleep * 2, MAX_IDLE_SLEEP);
            }
        }
    });

    Ok((proxy_port, handle, running))
}

struct PooledEntry {
    guard: Mutex<SessionGuard>,
    last_used: Mutex<Instant>,
    ref_count: AtomicUsize,
}

pub struct SessionPool {
    inner: Mutex<HashMap<String, Arc<PooledEntry>>>,
}

pub struct SessionPoolLease<'a> {
    pool: &'a SessionPool,
    server_id: String,
}

impl Drop for SessionPoolLease<'_> {
    fn drop(&mut self) {
        self.pool.release(&self.server_id);
    }
}

impl SessionPool {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    pub fn acquire(&self, server: &Server, db: &Database) -> Result<()> {
        let existing = {
            let pool = self.inner.lock().map_err(|_| anyhow!("连接池锁定失败"))?;
            pool.get(&server.id).cloned()
        };

        if let Some(entry) = existing {
            let g = entry.guard.lock().map_err(|_| anyhow!("会话锁定失败"))?;
            if g.session.authenticated() {
                entry.ref_count.fetch_add(1, Ordering::Relaxed);
                *entry.last_used.lock().map_err(|_| anyhow!("锁定失败"))? = Instant::now();
                debug!(server_id = %server.id, ref_count = entry.ref_count.load(Ordering::Relaxed), "复用连接池会话");
                return Ok(());
            }
        }

        let guard = create_session(server, db)?;

        let mut pool = self.inner.lock().map_err(|_| anyhow!("连接池锁定失败"))?;
        pool.insert(
            server.id.clone(),
            Arc::new(PooledEntry {
                guard: Mutex::new(guard),
                last_used: Mutex::new(Instant::now()),
                ref_count: AtomicUsize::new(1),
            }),
        );
        debug!(server_id = %server.id, "新建连接池会话");
        Ok(())
    }

    pub fn acquire_scoped<'a>(
        &'a self,
        server: &Server,
        db: &Database,
    ) -> Result<SessionPoolLease<'a>> {
        self.acquire(server, db)?;
        Ok(SessionPoolLease {
            pool: self,
            server_id: server.id.clone(),
        })
    }

    pub fn with_session_mut<F, T>(&self, server_id: &str, f: F) -> Result<T>
    where
        F: FnOnce(&mut Session) -> Result<T>,
    {
        let entry = {
            let pool = self.inner.lock().map_err(|_| anyhow!("连接池锁定失败"))?;
            pool.get(server_id).cloned()
        }
        .ok_or_else(|| anyhow!("连接池中无此服务器会话"))?;
        let mut g = entry.guard.lock().map_err(|_| anyhow!("会话锁定失败"))?;
        f(&mut g.session)
    }

    pub fn release(&self, server_id: &str) {
        let entry = {
            let pool = self.inner.lock().map_err(|_| anyhow!("连接池锁定失败"));
            pool.ok().and_then(|p| p.get(server_id).cloned())
        };
        if let Some(entry) = entry {
            let prev = entry.ref_count.fetch_sub(1, Ordering::Relaxed);
            debug!(server_id, ref_count = prev - 1, "释放连接池引用");
        }
    }

    pub fn remove(&self, server_id: &str) {
        if let Ok(mut pool) = self.inner.lock() {
            pool.remove(server_id);
            info!(server_id, "连接池会话已移除");
        }
    }

    /// Applies a keepalive change to already-pooled sessions so the setting
    /// takes effect without waiting for the next connection.
    pub fn set_keepalive(&self, seconds: u32) {
        let entries: Vec<Arc<PooledEntry>> = match self.inner.lock() {
            Ok(pool) => pool.values().cloned().collect(),
            Err(_) => return,
        };
        for entry in entries {
            if let Ok(mut guard) = entry.guard.lock() {
                let _ = apply_keepalive(&mut guard.session, seconds);
            }
        }
    }
}
