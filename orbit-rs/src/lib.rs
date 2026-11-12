pub mod agent;
mod crypto;
pub mod database;
mod db;
mod docker;
mod ffi;
mod host_key;
mod models;
mod monitor;
pub mod server_organization;
mod sftp;
mod sftp_transfer;
mod ssh;
mod transport;

use std::sync::Mutex;

pub struct OrbitApp {
    pub db: db::Database,
    pub transfers: sftp_transfer::TransferRegistry,
    pub db_path: String,
    pub ssh: Mutex<ssh::SshManager>,
    pub pool: transport::SessionPool,
    pub agent_jobs: Mutex<agent::AgentJobRegistry>,
    pub last_error: Mutex<Option<String>>,
}

impl OrbitApp {
    pub fn new(db_path: &str) -> anyhow::Result<Self> {
        let database = db::Database::new(db_path)?;
        Ok(Self {
            db: database,
            transfers: sftp_transfer::TransferRegistry::default(),
            db_path: db_path.to_string(),
            ssh: Mutex::new(ssh::SshManager::new()),
            pool: transport::SessionPool::new(),
            agent_jobs: Mutex::new(agent::AgentJobRegistry::new()),
            last_error: Mutex::new(None),
        })
    }

    pub fn clear_error(&self) {
        if let Ok(mut last_error) = self.last_error.lock() {
            *last_error = None;
        }
    }

    pub fn set_error(&self, message: impl Into<String>) {
        if let Ok(mut last_error) = self.last_error.lock() {
            *last_error = Some(message.into());
        }
    }

    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().ok().and_then(|e| e.clone())
    }
}

fn init_logging(app_dir: &str) {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;
    use tracing_subscriber::EnvFilter;
    use tracing_subscriber::Layer;

    let file_appender =
        tracing_appender::rolling::never(std::path::Path::new(app_dir), "orbit.log");
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
