use std::sync::Arc;
use tracing::info;
use crate::{models::Server, ssh, OrbitApp};

fn open_server_terminal_channel(
    guard: &crate::transport::SessionGuard,
    session_lock: &Arc<std::sync::Mutex<()>>,
) -> anyhow::Result<ssh2::Channel> {
    let _lock = session_lock
        .lock()
        .map_err(|error| anyhow::anyhow!("SSH session lock failed: {}", error))?;
    guard.session.set_blocking(true);
    let channel_result = (|| {
        let mut channel = guard
            .session
            .channel_session()
            .map_err(|error| anyhow::anyhow!("创建 SSH channel 失败: {}", error))?;
        let _ = channel.setenv("LANG", "en_US.UTF-8");
        let _ = channel.setenv("LC_ALL", "en_US.UTF-8");
        channel
            .request_pty("xterm-256color", None, None)
            .map_err(|error| anyhow::anyhow!("请求远端 PTY 失败: {}", error))?;
        channel
            .shell()
            .map_err(|error| anyhow::anyhow!("启动远端 shell 失败: {}", error))?;
        Ok(channel)
    })();
    guard.session.set_blocking(false);
    channel_result
}

pub(crate) fn connect_server_session(
    app: &OrbitApp,
    server: Server,
    pool_key: Option<String>,
    temporary: Option<ssh::TemporarySessionDescriptor>,
    data_cb: ssh::DataCallback,
    closed_cb: ssh::ClosedCallback,
) -> anyhow::Result<String> {
    let session_id = uuid::Uuid::new_v4().to_string();
    let reused = match pool_key.as_deref() {
        Some(pool_key) => {
            let mut manager = app
                .ssh
                .lock()
                .map_err(|error| anyhow::anyhow!("SSH 会话管理器锁定失败: {}", error))?;
            manager.take_idle_session(pool_key)
        }
        None => None,
    };

    let reusable_channel = reused.and_then(|(guard, session_lock)| {
        match open_server_terminal_channel(&guard, &session_lock) {
            Ok(channel) => Some((guard, session_lock, channel)),
            Err(error) => {
                info!(
                    pool_key = pool_key.as_deref().unwrap_or_default(),
                    error = %error,
                    "空闲连接已失效，创建新连接"
                );
                None
            }
        }
    });

    let (guard, session_lock, channel) = match reusable_channel {
        Some(reused) => reused,
        None => {
            let guard = crate::transport::create_session(&server, &app.db)?;
            let session_lock = Arc::new(std::sync::Mutex::new(()));
            let channel = open_server_terminal_channel(&guard, &session_lock)?;
            (guard, session_lock, channel)
        }
    };

    let active_channel = ssh::spawn_channel_reader(
        &session_id,
        channel,
        data_cb,
        closed_cb,
        session_lock.clone(),
    )?;

    let mut manager = app
        .ssh
        .lock()
        .map_err(|error| anyhow::anyhow!("SSH 会话管理器锁定失败: {}", error))?;
    manager.register_session(
        &session_id,
        pool_key,
        temporary,
        guard,
        active_channel,
        session_lock,
    );
    info!(session_id, server = %server.name, "SSH 终端连接成功");
    Ok(session_id)
}


pub(crate) fn start_port_forward(app: &OrbitApp, id: &str, server_id: &str, local_port: u16, remote_host: &str, remote_port: u16) -> anyhow::Result<u16> {
    if remote_host.trim().is_empty() || remote_port == 0 { anyhow::bail!("远端地址和端口无效"); }
    let server = app.db.get_server(server_id)?;
    let guard = crate::transport::create_session(&server, &app.db)?;
    let listener = std::net::TcpListener::bind(("127.0.0.1", local_port))?;
    listener.set_nonblocking(true)?;
    let actual_port = listener.local_addr()?.port();
    let running = Arc::new(std::sync::atomic::AtomicBool::new(true));
    app.ssh.lock().map_err(|_| anyhow::anyhow!("会话锁定失败"))?.register_port_forward(id, running.clone());
    guard.session.set_blocking(false);
    let session = guard.session.clone();
    let remote_host = remote_host.to_string();
    let open_lock = Arc::new(std::sync::Mutex::new(()));
    crate::ffi::spawn_port_forward_listener(listener, running, guard, move |local_tcp, run| {
        let Ok(channel_open_guard) = open_lock.lock() else { return; };
        let Some(channel) = crate::ffi::open_port_forward_channel(&session, &remote_host, remote_port, &run) else { return; };
        drop(channel_open_guard);
        crate::ffi::proxy_port_forward_connection(local_tcp, channel, run);
    });
    Ok(actual_port)
}
