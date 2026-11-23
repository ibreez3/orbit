#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod local_terminal;
mod commands;
mod ai;
mod gateway;
mod agent_transport;
mod agent_shell;

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex};
use orbit_core::desktop::{DesktopCore, ServerInput, ServerSummary, FileEntry, TransferRequest, TemporaryConnectionInput};
use serde::Serialize;
use tauri::{ipc::Channel, Emitter, Manager, State};

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum TerminalEvent {
    Data { bytes: Vec<u8> },
    Closed,
}

#[derive(Default)]
struct Flow {
    state: Mutex<(usize, bool)>,
    ready: Condvar,
}

impl Flow {
    fn stop(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.1 = true;
            self.ready.notify_all();
        }
    }

    fn send(&self, channel: &Channel<TerminalEvent>, bytes: &[u8]) {
        let Ok(mut state) = self.state.lock() else { return };
        while state.0 >= 256 * 1024 && !state.1 {
            let Ok(next) = self.ready.wait(state) else { return };
            state = next;
        }
        if state.1 { return; }
        state.0 += bytes.len();
        drop(state);
        if channel.send(TerminalEvent::Data { bytes: bytes.to_vec() }).is_err() {
            self.stop();
        }
    }
}

struct Connection {
    flow: Arc<Flow>,
    session: Option<String>,
}

struct AppState {
    core: Arc<DesktopCore>,
    connections: Mutex<HashMap<String, Connection>>,
    locals: Mutex<HashMap<String, Arc<local_terminal::LocalTerminal>>>,
}

fn error(value: impl std::fmt::Display) -> String { value.to_string() }

#[tauri::command]
async fn servers(state: State<'_, AppState>) -> Result<Vec<ServerSummary>, String> {
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.servers().map_err(error)).await.map_err(error)?
}

#[tauri::command]
async fn add_server(state: State<'_, AppState>, input: ServerInput) -> Result<String, String> {
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.add_server(&input).map_err(error)).await.map_err(error)?
}

#[tauri::command]
async fn delete_server(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.delete_server(&id).map_err(error)).await.map_err(error)?
}

#[tauri::command]
async fn connect(state: State<'_, AppState>, token: String, server_id: String, output: Channel<TerminalEvent>, temporary: Option<TemporaryConnectionInput>) -> Result<String, String> {
    let flow = Arc::new(Flow::default());
    {
        let mut connections = state.connections.lock().map_err(error)?;
        if connections.contains_key(&token) { return Err("连接已存在".into()); }
        connections.insert(token.clone(), Connection { flow: flow.clone(), session: None });
    }
    if server_id == "__local__" {
        let local_flow = flow.clone();
        let result = tauri::async_runtime::spawn_blocking(move || local_terminal::LocalTerminal::start(local_flow, output)).await.map_err(error).and_then(|result| result);
        let mut connections = state.connections.lock().map_err(error)?;
        return match result {
            Ok(local) => {
                if let Some(connection) = connections.get_mut(&token) {
                    let id = format!("local:{}", token);
                    state.locals.lock().map_err(error)?.insert(id.clone(), Arc::new(local));
                    connection.session = Some(id.clone());
                    Ok(id)
                } else { flow.stop(); local.stop(); Err("连接已取消".into()) }
            }
            Err(message) => { connections.remove(&token); flow.stop(); Err(message) }
        };
    }
    let core = state.core.clone();
    let data_flow = flow.clone();
    let closed_output = output.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let data = Box::new(move |_: &str, bytes: &[u8]| data_flow.send(&output, bytes));
        let closed = Box::new(move |_: &str| { let _ = closed_output.send(TerminalEvent::Closed); });
        match temporary {
            Some(input) => core.connect_temporary(input, data, closed),
            None => core.connect(&server_id, data, closed),
        }.map_err(error)
    }).await.map_err(error).and_then(|result| result);
    let mut connections = state.connections.lock().map_err(error)?;
    match result {
        Ok(session) => {
            if let Some(connection) = connections.get_mut(&token) {
                connection.session = Some(session.clone());
                Ok(session)
            } else {
                drop(connections);
                flow.stop();
                let _ = state.core.disconnect(&session);
                Err("连接已取消".into())
            }
        }
        Err(message) => {
            connections.remove(&token);
            flow.stop();
            Err(message)
        }
    }
}

#[tauri::command]
fn acknowledge(state: State<'_, AppState>, token: String, bytes: usize) -> Result<(), String> {
    if let Some(connection) = state.connections.lock().map_err(error)?.get(&token) {
        let mut flow = connection.flow.state.lock().map_err(error)?;
        flow.0 = flow.0.saturating_sub(bytes);
        connection.flow.ready.notify_all();
    }
    Ok(())
}

#[tauri::command]
async fn disconnect(state: State<'_, AppState>, token: String) -> Result<(), String> {
    let connection = state.connections.lock().map_err(error)?.remove(&token);
    if let Some(connection) = connection {
        connection.flow.stop();
        if let Some(id) = connection.session {
            if let Some(local) = state.locals.lock().map_err(error)?.remove(&id) { local.stop(); return Ok(()); }
            let core = state.core.clone();
            tauri::async_runtime::spawn_blocking(move || core.disconnect(&id).map_err(error)).await.map_err(error)??;
        }
    }
    Ok(())
}

#[tauri::command]
async fn terminal_write(state: State<'_, AppState>, id: String, bytes: Vec<u8>) -> Result<(), String> {
    let local = state.locals.lock().map_err(error)?.get(&id).cloned();
    if let Some(local) = local { return tauri::async_runtime::spawn_blocking(move || local.write(&bytes)).await.map_err(error)?; }
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.write(&id, &bytes).map_err(error)).await.map_err(error)?
}

#[tauri::command]
async fn resize(state: State<'_, AppState>, id: String, cols: u32, rows: u32) -> Result<(), String> {
    if cols == 0 || rows == 0 || cols > 1000 || rows > 1000 { return Err("终端尺寸无效".into()); }
    let local = state.locals.lock().map_err(error)?.get(&id).cloned();
    if let Some(local) = local { return tauri::async_runtime::spawn_blocking(move || local.resize(cols, rows)).await.map_err(error)?; }
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.resize(&id, cols, rows).map_err(error)).await.map_err(error)?
}

#[tauri::command]
async fn resolve_host_key(state: State<'_, AppState>, id: String, trust: bool) -> Result<(), String> {
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.resolve_host_key(&id, trust).map_err(error)).await.map_err(error)?
}

#[tauri::command]
async fn files(state: State<'_, AppState>, server_id: String, path: String) -> Result<Vec<FileEntry>, String> {
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.files(&server_id, &path).map_err(error)).await.map_err(error)?
}

#[tauri::command]
fn reserve_transfer(state: State<'_, AppState>) -> Result<String, String> { state.core.reserve_transfer().map_err(error) }

#[tauri::command]
fn cancel_transfer(state: State<'_, AppState>, id: String) -> Result<(), String> { state.core.cancel_transfer(&id).map_err(error) }

#[tauri::command]
async fn transfer(state: State<'_, AppState>, request: TransferRequest, progress: Channel<(u64, u64)>) -> Result<(), String> {
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.transfer(&request, Box::new(move |done, total| { let _ = progress.send((done, total)); })).map_err(error)).await.map_err(error)?
}

#[tauri::command]
async fn request(state: State<'_, AppState>, action: String, args: serde_json::Value) -> Result<serde_json::Value, String> {
    let core = state.core.clone();
    tauri::async_runtime::spawn_blocking(move || core.request(&action, args).map_err(|error| format!("{error:#}"))).await.map_err(error)?
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let directory = app.path().app_local_data_dir()?;
            std::fs::create_dir_all(&directory)?;
            let core = Arc::new(DesktopCore::new(&directory.join("orbit.db").to_string_lossy())?);
            let handle = app.handle().clone();
            core.on_host_key(Arc::new(move |json| {
                if let Ok(payload) = serde_json::from_str::<serde_json::Value>(&json) {
                    let _ = handle.emit("host-key", payload);
                }
            }))?;
            app.manage(Arc::new(gateway::Gateway::new(core.clone(), app.handle().clone())?));
            app.manage(ai::Requests::default());
            app.manage(Arc::new(commands::Jobs::default()));
            app.manage(AppState { core, connections: Mutex::new(HashMap::new()), locals: Mutex::new(HashMap::new()) });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![commands::command_start, commands::command_poll, commands::command_cancel, commands::command_release, gateway::gateway_snapshot, gateway::gateway_approve, gateway::gateway_revoke, gateway::gateway_expose, gateway::gateway_enable, ai::ai_config, ai::ai_save_config, ai::ai_chat, ai::ai_cancel, request, servers, add_server, delete_server, connect, acknowledge, disconnect, terminal_write, resize, resolve_host_key, files, reserve_transfer, cancel_transfer, transfer])
        .build(tauri::generate_context!())
        .expect("无法启动 Orbit");
    app.run(|app, event| {
        if let tauri::RunEvent::Exit = event {
            let state = app.state::<AppState>();
            if let Ok(connections) = state.connections.lock() {
                for connection in connections.values() { connection.flow.stop(); }
            }
            if let Ok(mut locals) = state.locals.lock() { for local in locals.values() { local.stop(); } locals.clear(); }
            app.state::<Arc<gateway::Gateway>>().stop();
            if let Ok(jobs) = app.state::<Arc<commands::Jobs>>().0.lock() { for job in jobs.values() { job.cancel(); } }
            state.core.shutdown();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn closing_terminal_releases_a_blocked_output_worker() {
        let flow = Arc::new(Flow::default());
        let (sent, received) = mpsc::channel();
        let channel = Channel::new(move |_| { sent.send(()).unwrap(); Ok(()) });
        flow.send(&channel, &vec![0; 256 * 1024]);
        received.recv_timeout(Duration::from_secs(1)).unwrap();
        let worker_flow = flow.clone();
        let (finished, completion) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            worker_flow.send(&channel, b"blocked");
            finished.send(()).unwrap();
        });
        assert!(completion.recv_timeout(Duration::from_millis(100)).is_err());
        flow.stop();
        completion.recv_timeout(Duration::from_secs(2)).unwrap();
        worker.join().unwrap();
        assert!(received.try_recv().is_err());
    }
}
