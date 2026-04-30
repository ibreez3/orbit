mod crypto;
mod db;
mod ffi;
mod models;
mod monitor;
mod sftp;
mod ssh;
mod transport;

use std::sync::Mutex;

pub struct OrbitApp {
    pub db: db::Database,
    pub ssh: Mutex<ssh::SshManager>,
    pub pool: transport::SessionPool,
}

impl OrbitApp {
    pub fn new(db_path: &str) -> anyhow::Result<Self> {
        let database = db::Database::new(db_path)?;
        Ok(Self {
            db: database,
            ssh: Mutex::new(ssh::SshManager::new()),
            pool: transport::SessionPool::new(),
        })
    }
}

fn init_logging(app_dir: &str) {
    use tracing_subscriber::EnvFilter;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;
    use tracing_subscriber::Layer;

    let file_appender = tracing_appender::rolling::never(
        std::path::Path::new(app_dir),
        "orbit.log",
    );
    let (file_writer, _guard) = tracing_appender::non_blocking(file_appender);

    let file_layer = tracing_subscriber::fmt::layer()
        .with_writer(file_writer)
        .with_ansi(false)
        .with_target(true)
        .with_filter(EnvFilter::try_new("orbit=debug").unwrap_or_else(|_| EnvFilter::new("debug")));

    let console_layer = tracing_subscriber::fmt::layer()
        .with_ansi(true)
        .with_target(false)
        .with_filter(EnvFilter::try_new("orbit=info").unwrap_or_else(|_| EnvFilter::new("info")));

    let subscriber = tracing_subscriber::registry()
        .with(console_layer)
        .with(file_layer);

    if subscriber.try_init().is_err() {
        eprintln!("日志系统初始化失败");
    }

    tracing::info!("日志文件: {}/orbit.log", app_dir);
    std::mem::forget(_guard);
}
