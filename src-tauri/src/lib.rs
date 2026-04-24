mod db;
mod models;
mod monitor;
mod sftp;
mod ssh;

use std::sync::Mutex;

use tauri::{AppHandle, State};

use models::*;

struct AppState {
    db: db::Database,
    ssh: Mutex<ssh::SshManager>,
    sftp: Mutex<sftp::SftpManager>,
}

#[tauri::command]
async fn list_servers(state: State<'_, AppState>) -> Result<Vec<Server>, String> {
    state.db.list_servers().map_err(|e| e.to_string())
}

#[tauri::command]
async fn add_server(state: State<'_, AppState>, input: ServerInput) -> Result<Server, String> {
    state.db.add_server(&input).map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_server(
    state: State<'_, AppState>,
    id: String,
    input: ServerInput,
) -> Result<Server, String> {
    state
        .db
        .update_server(&id, &input)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_server(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state.db.delete_server(&id).map_err(|e| e.to_string())
}

#[tauri::command]
async fn test_connection(state: State<'_, AppState>, input: ServerInput) -> Result<bool, String> {
    let server = Server {
        id: String::new(),
        name: input.name.clone(),
        host: input.host.clone(),
        port: input.port.unwrap_or(22),
        group_name: String::new(),
        auth_type: input.auth_type.clone().unwrap_or_else(|| "password".into()),
        username: input.username.clone(),
        password: input.password.clone().unwrap_or_default(),
        private_key: input.private_key.clone().unwrap_or_default(),
        key_passphrase: input.key_passphrase.clone().unwrap_or_default(),
        created_at: String::new(),
        updated_at: String::new(),
    };
    let mgr = ssh::SshManager::new();
    let tcp = std::net::TcpStream::connect((server.host.as_str(), server.port))
        .map_err(|e| format!("连接失败: {}", e))?;
    let mut session = ssh2::Session::new().map_err(|e| format!("SSH会话创建失败: {}", e))?;
    session.set_tcp_stream(tcp);
    session.handshake().map_err(|e| format!("握手失败: {}", e))?;

    match server.auth_type.as_str() {
        "password" => session
            .userauth_password(&server.username, &server.password)
            .map_err(|e| format!("密码认证失败: {}", e))?,
        "key" => session
            .userauth_pubkey_memory(
                &server.username,
                None,
                &server.private_key,
                if server.key_passphrase.is_empty() {
                    None
                } else {
                    Some(server.key_passphrase.as_str())
                },
            )
            .map_err(|e| format!("密钥认证失败: {}", e))?,
        _ => return Err("不支持的认证类型".into()),
    }

    Ok(session.authenticated())
}

#[tauri::command]
async fn connect_ssh(
    state: State<'_, AppState>,
    server_id: String,
    app_handle: AppHandle,
) -> Result<String, String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let session_id = uuid::Uuid::new_v4().to_string();
    let mut mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.connect(&session_id, &server, app_handle)
        .map_err(|e| e.to_string())?;
    Ok(session_id)
}

#[tauri::command]
async fn write_ssh(
    state: State<'_, AppState>,
    session_id: String,
    data: Vec<u8>,
) -> Result<(), String> {
    let mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.write(&session_id, &data).map_err(|e| e.to_string())
}

#[tauri::command]
async fn resize_ssh(
    state: State<'_, AppState>,
    session_id: String,
    cols: u32,
    rows: u32,
) -> Result<(), String> {
    let mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.resize(&session_id, cols, rows)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn disconnect_ssh(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<(), String> {
    let mut mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.disconnect(&session_id).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_list(
    state: State<'_, AppState>,
    server_id: String,
    path: String,
) -> Result<Vec<FileEntry>, String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let mut mgr = state.sftp.lock().map_err(|e| e.to_string())?;
    mgr.list_dir(&server, &path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_download(
    state: State<'_, AppState>,
    server_id: String,
    remote_path: String,
    local_path: String,
) -> Result<(), String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let mgr = state.sftp.lock().map_err(|e| e.to_string())?;
    mgr.download_file(&server, &remote_path, &local_path)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_upload(
    state: State<'_, AppState>,
    server_id: String,
    local_path: String,
    remote_path: String,
) -> Result<(), String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let mgr = state.sftp.lock().map_err(|e| e.to_string())?;
    mgr.upload_file(&server, &local_path, &remote_path)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_mkdir(
    state: State<'_, AppState>,
    server_id: String,
    path: String,
) -> Result<(), String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let mgr = state.sftp.lock().map_err(|e| e.to_string())?;
    mgr.mkdir(&server, &path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_remove(
    state: State<'_, AppState>,
    server_id: String,
    path: String,
    is_dir: bool,
) -> Result<(), String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let mgr = state.sftp.lock().map_err(|e| e.to_string())?;
    mgr.remove(&server, &path, is_dir)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_server_stats(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<ServerStats, String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    let script = monitor::get_monitor_script();
    let output = mgr
        .exec_command(&server, script)
        .map_err(|e| e.to_string())?;
    monitor::collect_stats(&output).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app_dir = dirs_next().expect("无法获取应用数据目录");
    std::fs::create_dir_all(&app_dir).expect("无法创建应用数据目录");
    let db_path = format!("{}/ssh-manager.db", app_dir);

    let database = db::Database::new(&db_path).expect("数据库初始化失败");

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .manage(AppState {
            db: database,
            ssh: Mutex::new(ssh::SshManager::new()),
            sftp: Mutex::new(sftp::SftpManager::new()),
        })
        .invoke_handler(tauri::generate_handler![
            list_servers,
            add_server,
            update_server,
            delete_server,
            test_connection,
            connect_ssh,
            write_ssh,
            resize_ssh,
            disconnect_ssh,
            sftp_list,
            sftp_download,
            sftp_upload,
            sftp_mkdir,
            sftp_remove,
            get_server_stats,
        ])
        .run(tauri::generate_context!())
        .expect("启动失败");
}

fn dirs_next() -> Option<String> {
    let base = dirs::data_local_dir()
        .or_else(dirs::data_dir)
        .or_else(dirs::home_dir)?;
    Some(format!("{}", base.join("ssh-manager").display()))
}
