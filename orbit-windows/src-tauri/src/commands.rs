use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use orbit_core::agent::AgentJob;
use tauri::State;
use crate::{AppState, error};

#[derive(Default)]
pub struct Jobs(pub Mutex<HashMap<String, Arc<AgentJob>>>);

#[tauri::command]
pub async fn command_start(state: State<'_, AppState>, jobs: State<'_, Arc<Jobs>>, server_id: String, command: String, timeout_ms: u32) -> Result<String, String> {
    if command.trim().is_empty() || command.len() > 65_536 { return Err("命令为空或过长".into()); }
    let core = state.core.clone();
    let jobs = jobs.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut registry = jobs.0.lock().map_err(error)?;
        if registry.len() >= 64 || registry.values().filter(|job| !job.is_finished()).count() >= 16 { return Err("同时执行的命令过多".into()); }
        let job = core.start_job(&server_id, command, timeout_ms, 1_048_576).map_err(error)?;
        let id = job.id().to_string();
        registry.insert(id.clone(), job);
        Ok(id)
    }).await.map_err(error)?
}

#[tauri::command]
pub fn command_poll(jobs: State<'_, Arc<Jobs>>, id: String, cursor: usize) -> Result<serde_json::Value, String> {
    let registry = jobs.0.lock().map_err(error)?;
    let job = registry.get(&id).ok_or("命令不存在")?;
    Ok(serde_json::json!({ "status": job.status_dto(), "output": job.output_dto(cursor) }))
}

#[tauri::command]
pub fn command_cancel(jobs: State<'_, Arc<Jobs>>, id: String) -> Result<(), String> {
    if let Some(job) = jobs.0.lock().map_err(error)?.get(&id) { job.cancel(); }
    Ok(())
}

#[tauri::command]
pub fn command_release(jobs: State<'_, Arc<Jobs>>, id: String) -> Result<(), String> {
    if let Some(job) = jobs.0.lock().map_err(error)?.remove(&id) { job.cancel(); }
    Ok(())
}
