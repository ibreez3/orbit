mod db;
mod models;
mod monitor;
mod sftp;
mod ssh;
mod transport;

use std::sync::Mutex;
use tauri::{AppHandle, State};
use models::*;

struct AppState {
    db: db::Database,
    ssh: Mutex<ssh::SshManager>,
    pool: transport::SessionPool,
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
async fn update_server(state: State<'_, AppState>, id: String, input: ServerInput) -> Result<Server, String> {
    state.db.update_server(&id, &input).map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_server(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state.pool.remove(&id);
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
        key_source: input.key_source.clone().unwrap_or_else(|| "content".into()),
        key_file_path: input.key_file_path.clone().unwrap_or_default(),
        key_passphrase: input.key_passphrase.clone().unwrap_or_default(),
        credential_group_id: input.credential_group_id.clone().unwrap_or_default(),
        jump_server_id: input.jump_server_id.clone().unwrap_or_default(),
        created_at: String::new(),
        updated_at: String::new(),
    };
    let guard = transport::create_session(&server, &state.db).map_err(|e| e.to_string())?;
    Ok(guard.session.authenticated())
}

#[tauri::command]
async fn connect_ssh(state: State<'_, AppState>, server_id: String, app_handle: AppHandle) -> Result<String, String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let session_id = uuid::Uuid::new_v4().to_string();
    let mut mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.connect(&session_id, &server, &state.db, app_handle).map_err(|e| e.to_string())?;
    Ok(session_id)
}

#[tauri::command]
async fn write_ssh(state: State<'_, AppState>, session_id: String, data: Vec<u8>) -> Result<(), String> {
    let mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.write(&session_id, &data).map_err(|e| e.to_string())
}

#[tauri::command]
async fn resize_ssh(state: State<'_, AppState>, session_id: String, cols: u32, rows: u32) -> Result<(), String> {
    let mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.resize(&session_id, cols, rows).map_err(|e| e.to_string())
}

#[tauri::command]
async fn disconnect_ssh(state: State<'_, AppState>, session_id: String) -> Result<(), String> {
    let mut mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.disconnect(&session_id).map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_ssh_traffic(state: State<'_, AppState>, session_id: String) -> Result<ssh::TrafficStats, String> {
    let mgr = state.ssh.lock().map_err(|e| e.to_string())?;
    mgr.get_traffic(&session_id).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_list(state: State<'_, AppState>, server_id: String, path: String) -> Result<Vec<FileEntry>, String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    sftp::SftpManager::list_dir(&state.pool, &server, &state.db, &path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_download(state: State<'_, AppState>, server_id: String, remote_path: String, local_path: String) -> Result<(), String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    sftp::SftpManager::download_file(&state.pool, &server, &state.db, &remote_path, &local_path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_upload(state: State<'_, AppState>, server_id: String, local_path: String, remote_path: String) -> Result<(), String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    sftp::SftpManager::upload_file(&state.pool, &server, &state.db, &local_path, &remote_path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_mkdir(state: State<'_, AppState>, server_id: String, path: String) -> Result<(), String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    sftp::SftpManager::mkdir(&state.pool, &server, &state.db, &path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_remove(state: State<'_, AppState>, server_id: String, path: String, is_dir: bool) -> Result<(), String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    sftp::SftpManager::remove(&state.pool, &server, &state.db, &path, is_dir).map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_disconnect(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    state.pool.remove(&server_id);
    Ok(())
}

#[tauri::command]
async fn get_server_stats(state: State<'_, AppState>, server_id: String) -> Result<ServerStats, String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let output = ssh::SshManager::exec_command(&state.pool, &server, &state.db, monitor::get_monitor_script()).map_err(|e| e.to_string())?;
    monitor::collect_stats(&output).map_err(|e| e.to_string())
}

#[tauri::command]
async fn list_credential_groups(state: State<'_, AppState>) -> Result<Vec<CredentialGroup>, String> {
    state.db.list_credential_groups().map_err(|e| e.to_string())
}

#[tauri::command]
async fn add_credential_group(state: State<'_, AppState>, input: CredentialGroupInput) -> Result<CredentialGroup, String> {
    state.db.add_credential_group(&input).map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_credential_group(state: State<'_, AppState>, id: String, input: CredentialGroupInput) -> Result<CredentialGroup, String> {
    state.db.update_credential_group(&id, &input).map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_credential_group(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state.db.delete_credential_group(&id).map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_server_home(state: State<'_, AppState>, server_id: String) -> Result<String, String> {
    let server = state.db.get_server(&server_id).map_err(|e| e.to_string())?;
    let output = ssh::SshManager::exec_command(&state.pool, &server, &state.db, "echo $HOME").map_err(|e| e.to_string())?;
    Ok(output.trim().to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app_dir = dirs_next().expect("无法获取应用数据目录");
    std::fs::create_dir_all(&app_dir).expect("无法创建应用数据目录");
    let db_path = format!("{}/orbit.db", app_dir);

    let database = db::Database::new(&db_path).expect("数据库初始化失败");

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .manage(AppState {
            db: database,
            ssh: Mutex::new(ssh::SshManager::new()),
            pool: transport::SessionPool::new(),
        })
        .invoke_handler(tauri::generate_handler![
            list_servers, add_server, update_server, delete_server,
            test_connection,
            connect_ssh, write_ssh, resize_ssh, disconnect_ssh,
            get_ssh_traffic,
            sftp_list, sftp_download, sftp_upload, sftp_mkdir, sftp_remove, sftp_disconnect,
            get_server_stats,
            list_credential_groups, add_credential_group, update_credential_group, delete_credential_group,
            get_server_home,
        ])
        .run(tauri::generate_context!())
        .expect("启动失败");
}

fn dirs_next() -> Option<String> {
    let base = dirs::data_local_dir().or_else(dirs::data_dir).or_else(dirs::home_dir)?;
    Some(format!("{}", base.join("orbit").display()))
}
