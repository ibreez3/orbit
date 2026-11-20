use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use orbit_core::{agent::AgentJob, desktop::DesktopCore};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{Emitter, State};
use uuid::Uuid;
use crate::error;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request { id: String, op: String, session_id: Option<String>, token: Option<String>, tool: Option<String>, #[serde(default)] args: Value }

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Approval {
    request_id: String, kind: String, agent_name: String, session_id: Option<String>, server_id: Option<String>, command: String, status: String,
    #[serde(skip)]
    created: Option<Instant>,
    #[serde(skip)]
    credential: Option<Value>,
}

struct Job { value: Arc<AgentJob>, server: String, mode: String, escalated: bool }
struct Session {
    token: String, name: String, created: Instant, touched: Instant, created_at: u64,
    writes: HashSet<String>, jobs: HashMap<String, Job>, idempotency: HashMap<String, (String, String)>, shells: HashMap<String, Arc<crate::agent_shell::Shell>>,
}

#[derive(Default)]
struct Inner {
    enabled: bool, exposed: HashSet<String>, sessions: HashMap<String, Session>, approvals: HashMap<String, Approval>, audit: Vec<Value>,
}

pub struct Gateway {
    core: Arc<DesktopCore>, app: tauri::AppHandle, inner: Mutex<Inner>,
    listener: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() }
fn failure(code: &str, message: &str) -> Value { json!({"code":code,"message":message}) }
fn equal(left: &str, right: &str) -> bool {
    if left.len() != right.len() { return false; }
    left.bytes().zip(right.bytes()).fold(0u8, |difference, (a, b)| difference | (a ^ b)) == 0
}
fn requires_write(command: &str, mode: &str) -> bool {
    if mode != "read" || command.chars().any(|ch| ";|&$><`\n\r\\".contains(ch)) { return true; }
    let words: Vec<_> = command.split_whitespace().collect();
    !matches!(words.first().copied(), Some("whoami" | "pwd" | "id" | "uname" | "uptime" | "ls" | "cat" | "head" | "tail" | "wc" | "ps" | "free" | "df" | "du" | "hostname"))
}

impl Gateway {
    pub fn new(core: Arc<DesktopCore>, app: tauri::AppHandle) -> Result<Self, String> {
        let exposed = core.private_setting("agent.exposed").map_err(error)?.map(|value| serde_json::from_str(&value).map_err(error)).transpose()?.unwrap_or_default();
        let audit = core.private_setting("agent.audit").map_err(error)?.map(|value| serde_json::from_str(&value).map_err(error)).transpose()?.unwrap_or_default();
        Ok(Self { core, app, inner: Mutex::new(Inner { exposed, audit, ..Inner::default() }), listener: Mutex::new(None) })
    }

    fn changed(&self) { let _ = self.app.emit("agent-changed", ()); }

    fn record(&self, inner: &mut Inner, event: Value) {
        inner.audit.push(event);
        if inner.audit.len() > 500 { inner.audit.drain(..inner.audit.len() - 500); }
        if let Ok(value) = serde_json::to_string(&inner.audit) { let _ = self.core.save_private_setting("agent.audit", &value); }
    }

    fn expire(inner: &mut Inner) {
        let expired: Vec<_> = inner.sessions.iter().filter(|(_, session)| session.created.elapsed() > Duration::from_secs(8 * 3600) || (session.shells.is_empty() && session.jobs.values().all(|job| job.value.is_finished()) && session.touched.elapsed() > Duration::from_secs(1800))).map(|(id, _)| id.clone()).collect();
        for id in expired { Self::revoke_locked(inner, &id); }
        for approval in inner.approvals.values_mut() {
            if approval.status == "pending" && approval.created.map(|created| created.elapsed() > Duration::from_secs(300)).unwrap_or(true) { approval.status = "expired".into(); }
        }
        inner.approvals.retain(|_, approval| approval.created.map(|created| created.elapsed() <= Duration::from_secs(600)).unwrap_or(false));
    }

    fn revoke_locked(inner: &mut Inner, id: &str) {
        if let Some(session) = inner.sessions.remove(id) { for job in session.jobs.values() { job.value.cancel(); } for shell in session.shells.values() { shell.stop(); } }
        inner.approvals.retain(|_, approval| approval.session_id.as_deref() != Some(id));
    }

    pub fn stop(&self) {
        if let Ok(mut listener) = self.listener.lock() { if let Some(listener) = listener.take() { listener.abort(); } }
        if let Ok(mut inner) = self.inner.lock() {
            inner.enabled = false;
            let ids: Vec<_> = inner.sessions.keys().cloned().collect();
            for id in ids { Self::revoke_locked(&mut inner, &id); }
            inner.approvals.clear();
        }
        self.changed();
    }

    pub fn snapshot(&self) -> Result<Value, String> {
        let mut inner = self.inner.lock().map_err(error)?; Self::expire(&mut inner);
        Ok(json!({"enabled":inner.enabled,"exposed":inner.exposed,"approvals":inner.approvals.values().filter(|approval| approval.status == "pending").collect::<Vec<_>>(),"sessions":inner.sessions.iter().map(|(id, session)| json!({"sessionId":id,"agentName":session.name,"createdAt":session.created_at,"writeServers":session.writes,"openShellCount":session.shells.len(),"openJobCount":session.jobs.values().filter(|job| !job.value.is_finished()).count()})).collect::<Vec<_>>(),"audit":inner.audit}))
    }

    fn authenticated<'a>(inner: &'a mut Inner, request: &Request) -> Result<&'a mut Session, Value> {
        let session = request.session_id.as_ref().and_then(|id| inner.sessions.get_mut(id)).ok_or_else(|| failure("unauthorized", "会话不存在或已过期"))?;
        if !request.token.as_ref().map(|token| equal(token, &session.token)).unwrap_or(false) { return Err(failure("unauthorized", "会话凭据无效")); }
        session.touched = Instant::now();
        Ok(session)
    }

    fn approve_write(&self, inner: &mut Inner, session_id: &str, server: &str, command: &str) -> Result<(), Value> {
        let session = inner.sessions.get(session_id).ok_or_else(|| failure("unauthorized", "会话已撤销"))?;
        if session.writes.contains(server) { return Ok(()); }
        let approval = if let Some(approval) = inner.approvals.values().find(|approval| approval.kind == "write" && approval.session_id.as_deref() == Some(session_id) && approval.server_id.as_deref() == Some(server) && approval.status == "pending") { approval.clone() } else {
            if inner.approvals.len() >= 64 { return Err(failure("invalid_request", "待处理授权过多")); }
            let approval = Approval { request_id: Uuid::new_v4().to_string(), kind: "write".into(), agent_name: session.name.clone(), session_id: Some(session_id.into()), server_id: Some(server.into()), command: command.into(), status: "pending".into(), created: Some(Instant::now()), credential: None };
            inner.approvals.insert(approval.request_id.clone(), approval.clone()); self.changed(); approval
        };
        Err(json!({"pending":true,"requestId":approval.request_id}))
    }

    pub fn handle(&self, request: Request) -> Value {
        let result = self.call(&request);
        match result {
            Ok(result) => json!({"id":request.id,"ok":true,"result":result}),
            Err(error) if error["pending"].as_bool() == Some(true) => json!({"id":request.id,"ok":true,"result":{"status":"pending_approval","requestId":error["requestId"],"message":"请在 Orbit 中批准后重试相同操作"}}),
            Err(error) => json!({"id":request.id,"ok":false,"error":error}),
        }
    }

    fn call(&self, request: &Request) -> Result<Value, Value> {
        let invalid = |message: &str| failure("invalid_request", message);
        let mut inner = self.inner.lock().map_err(|_| invalid("网关锁定失败"))?;
        Self::expire(&mut inner);
        if !inner.enabled { return Err(failure("orbit_unavailable", "Agent 网关未启用")); }
        if request.op == "ping" { return Ok(json!({"alive":true,"sessionExpired":false})); }
        if request.op == "hello" {
            if inner.approvals.len() >= 64 { return Err(invalid("待处理授权过多")); }
            let name = request.args["clientName"].as_str().filter(|name| !name.trim().is_empty() && name.len() <= 128).ok_or_else(|| invalid("缺少客户端名称"))?;
            let id = Uuid::new_v4().to_string();
            inner.approvals.insert(id.clone(), Approval { request_id: id.clone(), kind: "admission".into(), agent_name: name.into(), session_id: None, server_id: None, command: String::new(), status: "pending".into(), created: Some(Instant::now()), credential: None });
            self.changed();
            return Ok(json!({"status":"pending_approval","requestId":id}));
        }
        if request.op == "admission_status" {
            let id = request.args["requestId"].as_str().ok_or_else(|| invalid("缺少 requestId"))?;
            let approval = inner.approvals.get(id).filter(|approval| approval.kind == "admission").ok_or_else(|| invalid("授权请求不存在"))?;
            return Ok(json!({"requestId":id,"status":approval.status,"session":approval.credential}));
        }
        Self::authenticated(&mut inner, request)?;
        let session_id = request.session_id.as_deref().unwrap_or_default();
        if request.op == "revoke" { Self::revoke_locked(&mut inner, session_id); self.changed(); return Ok(json!({"revoked":true})); }
        if request.op != "call" { return Err(invalid("不支持的操作")); }
        match request.tool.as_deref().unwrap_or_default() {
            "orbit_list_servers" => {
                let servers = self.core.servers().map_err(|error| invalid(&error.to_string()))?;
                Ok(json!(servers.into_iter().filter(|server| inner.exposed.contains(&server.id)).map(|server| json!({"id":server.id,"name":server.name,"host":server.host,"port":server.port,"username":server.username,"aiEnabled":true})).collect::<Vec<_>>()))
            }
            "orbit_approval_status" => {
                let id = request.args["requestId"].as_str().ok_or_else(|| invalid("缺少 requestId"))?;
                let approval = inner.approvals.get(id).filter(|approval| approval.session_id.as_deref() == Some(session_id)).ok_or_else(|| failure("unauthorized", "授权请求不属于当前会话"))?;
                Ok(json!({"requestId":id,"status":approval.status}))
            }
            "orbit_shell_open" => {
                let query = request.args["server"].as_str().ok_or_else(|| invalid("缺少 server"))?;
                let servers = self.core.servers().map_err(|error| invalid(&error.to_string()))?;
                let matches: Vec<_> = servers.iter().filter(|server| server.id == query || server.name == query || server.host == query).collect();
                if matches.len() != 1 { return Err(failure("server_not_found", "服务器不存在或名称不唯一")); }
                let server = matches[0].id.clone();
                if !inner.exposed.contains(&server) { return Err(failure("server_not_exposed", "服务器尚未开放给 Agent")); }
                self.approve_write(&mut inner, session_id, &server, "open persistent shell")?;
                if inner.sessions.get(session_id).map(|session| session.shells.len() >= 8).unwrap_or(true) { return Err(invalid("Shell 数量达到上限")); }
                drop(inner);
                let shell = Arc::new(crate::agent_shell::Shell::open(self.core.clone(), server.clone()).map_err(|error| invalid(&error))?);
                let mut inner = self.inner.lock().map_err(|_| invalid("网关锁定失败"))?;
                Self::expire(&mut inner);
                if !inner.enabled || !inner.exposed.contains(&server) { shell.stop(); return Err(failure("server_not_exposed", "服务器已停止开放")); }
                let session = Self::authenticated(&mut inner, request)?;
                if !session.writes.contains(&server) || session.shells.len() >= 8 { shell.stop(); return Err(failure("write_grant_required", "Shell 授权失效或数量达到上限")); }
                let id = Uuid::new_v4().to_string(); session.shells.insert(id.clone(), shell);
                self.record(&mut inner, json!({"timestamp":now(),"sessionId":session_id,"serverId":server,"tool":"orbit_shell_open","shellId":id,"result":"opened"}));
                Ok(json!({"shellId":id,"serverId":server}))
            }
            "orbit_shell_exec" | "orbit_shell_close" => {
                let id = request.args["shellId"].as_str().ok_or_else(|| invalid("缺少 shellId"))?;
                let session = inner.sessions.get_mut(session_id).ok_or_else(|| failure("unauthorized", "会话已撤销"))?;
                if request.tool.as_deref() == Some("orbit_shell_close") {
                    let shell = session.shells.remove(id).ok_or_else(|| failure("shell_not_found", "Shell 不属于当前会话"))?;
                    drop(inner); shell.stop(); return Ok(json!({"closed":true}));
                }
                let shell = session.shells.get(id).cloned().ok_or_else(|| failure("shell_not_found", "Shell 不属于当前会话"))?;
                if !session.writes.contains(&shell.server) { return Err(failure("write_grant_required", "Shell 写权限已撤销")); }
                let command = request.args["command"].as_str().ok_or_else(|| invalid("缺少 command"))?;
                let timeout = request.args.get("timeoutMs").map(|value| value.as_u64().filter(|value| (1..=50_000).contains(value)).ok_or_else(|| invalid("timeoutMs 无效"))).transpose()?.unwrap_or(30_000);
                drop(inner);
                let result = shell.execute(command, timeout);
                let mut inner = self.inner.lock().map_err(|_| invalid("网关锁定失败"))?;
                Self::expire(&mut inner); Self::authenticated(&mut inner, request)?;
                if !inner.enabled || !inner.exposed.contains(&shell.server) { return Err(failure("server_not_exposed", "服务器已停止开放")); }
                self.record(&mut inner, json!({"timestamp":now(),"sessionId":session_id,"serverId":shell.server,"tool":"orbit_shell_exec","command":command,"result":if result.is_ok(){"completed"}else{"failed"}}));
                result.map_err(|error| failure("shell_timeout", &error))
            }
            "orbit_exec" => {
                let query = request.args["server"].as_str().ok_or_else(|| invalid("缺少 server"))?;
                let command = request.args["command"].as_str().filter(|command| !command.trim().is_empty() && command.len() <= 64 * 1024).ok_or_else(|| invalid("命令为空或过长"))?;
                let mode = request.args["mode"].as_str().unwrap_or("read");
                if !matches!(mode, "read" | "write") { return Err(invalid("mode 必须为 read 或 write")); }
                let servers = self.core.servers().map_err(|error| invalid(&error.to_string()))?;
                let matches: Vec<_> = servers.iter().filter(|server| server.id == query || server.name == query || server.host == query).collect();
                if matches.len() != 1 { return Err(failure("server_not_found", "服务器不存在或名称不唯一，请使用 ID")); }
                let server = matches[0];
                if !inner.exposed.contains(&server.id) { return Err(failure("server_not_exposed", "服务器尚未开放给 Agent")); }
                let write = requires_write(command, mode);
                if write { self.approve_write(&mut inner, session_id, &server.id, command)?; }
                let session = inner.sessions.get_mut(session_id).ok_or_else(|| failure("unauthorized", "会话已撤销"))?;
                let number = |key: &str, default: u64, max: u64| -> Result<u64, Value> { request.args.get(key).map(|value| value.as_u64().filter(|value| *value <= max).ok_or_else(|| invalid("数值参数超出范围"))).unwrap_or(Ok(default)) };
                let timeout = number("timeoutMs", 30_000, 300_000)?.max(1) as u32;
                let wait = number("waitMs", 1000, 30_000)? as u32;
                let max_bytes = number("maxOutputBytes", 262_144, 1_048_576)?.max(1024) as usize;
                let key = request.args.get("idempotencyKey").map(|value| value.as_str().filter(|value| !value.is_empty() && value.len() <= 128).ok_or_else(|| invalid("idempotencyKey 无效"))).transpose()?;
                let fingerprint = json!([server.id, command, mode, timeout, max_bytes]).to_string();
                if let Some((previous, job_id)) = key.and_then(|key| session.idempotency.get(key)) {
                    if previous != &fingerprint { return Err(invalid("幂等键不能用于不同命令")); }
                    if let Some(job) = session.jobs.get(job_id) {
                        let mut result = serde_json::to_value(job.value.completed_output(&server.id)).map_err(|error| invalid(&error.to_string()))?;
                        result["jobId"] = json!(job_id); result["mode"] = json!(job.mode); result["escalated"] = json!(job.escalated);
                        return Ok(result);
                    }
                }
                if session.jobs.values().filter(|job| !job.value.is_finished()).count() >= 16 { return Err(invalid("并发作业达到上限")); }
                if session.jobs.len() >= 512 {
                    session.jobs.retain(|_, job| !job.value.is_finished());
                    session.idempotency.retain(|_, (_, id)| session.jobs.contains_key(id));
                }
                let job = self.core.start_job(&server.id, command.into(), timeout, max_bytes).map_err(|error| invalid(&error.to_string()))?;
                let id = job.id().to_string();
                if let Some(key) = key { session.idempotency.insert(key.into(), (fingerprint, id.clone())); }
                session.jobs.insert(id.clone(), Job { value: job.clone(), server: server.id.clone(), mode: if write { "write" } else { "read" }.into(), escalated: write && mode == "read" });
                self.record(&mut inner, json!({"timestamp":now(),"sessionId":session_id,"serverId":server.id,"tool":"orbit_exec","command":command,"mode":if write {"write"}else{"read"},"jobId":id,"result":"started"}));
                drop(inner);
                job.wait_for_finish(wait);
                let mut inner = self.inner.lock().map_err(|_| invalid("网关锁定失败"))?;
                Self::expire(&mut inner);
                Self::authenticated(&mut inner, request)?;
                if !inner.enabled || !inner.exposed.contains(&server.id) { return Err(failure("server_not_exposed", "服务器或网关已关闭")); }
                let mut result = serde_json::to_value(job.completed_output(&server.id)).map_err(|error| invalid(&error.to_string()))?;
                result["jobId"] = json!(id); result["mode"] = json!(if write { "write" } else { "read" }); result["escalated"] = json!(write && mode == "read");
                Ok(result)
            }
            "orbit_job_status" | "orbit_job_output" | "orbit_job_cancel" => {
                let id = request.args["jobId"].as_str().ok_or_else(|| invalid("缺少 jobId"))?;
                let job = inner.sessions.get(session_id).and_then(|session| session.jobs.get(id)).ok_or_else(|| failure("unauthorized", "作业不属于当前会话"))?;
                match request.tool.as_deref() {
                    Some("orbit_job_status") => { let mut value = serde_json::to_value(job.value.status_dto()).map_err(|error| invalid(&error.to_string()))?; value["serverId"] = json!(job.server); value["mode"] = json!(job.mode); value["escalated"] = json!(job.escalated); Ok(value) },
                    Some("orbit_job_output") => {
                        let cursor = request.args.get("cursor").map(|value| value.as_u64().ok_or_else(|| invalid("cursor 无效"))).transpose()?.unwrap_or(0);
                        Ok(serde_json::to_value(job.value.output_dto(cursor as usize)).map_err(|error| invalid(&error.to_string()))?)
                    }
                    _ => { job.value.cancel(); Ok(json!({"cancelled":true})) }
                }
            }
            _ => Err(invalid("不支持的工具")),
        }
    }
}

#[tauri::command]
pub fn gateway_snapshot(gateway: State<'_, Arc<Gateway>>) -> Result<Value, String> { gateway.snapshot() }

#[tauri::command]
pub fn gateway_approve(gateway: State<'_, Arc<Gateway>>, id: String, approved: bool) -> Result<(), String> {
    let mut inner = gateway.inner.lock().map_err(error)?; Gateway::expire(&mut inner);
    if !inner.enabled { return Err("网关已关闭".into()); }
    let approval = inner.approvals.get(&id).filter(|approval| approval.status == "pending").cloned().ok_or("授权请求不存在或已过期")?;
    let mut credential = None;
    if approved {
        if approval.kind == "admission" {
            let session_id = Uuid::new_v4().to_string(); let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
            inner.sessions.insert(session_id.clone(), Session { token: token.clone(), name: approval.agent_name.clone(), created: Instant::now(), touched: Instant::now(), created_at: now(), writes: HashSet::new(), jobs: HashMap::new(), idempotency: HashMap::new(), shells: HashMap::new() });
            credential = Some(json!({"sessionId":session_id,"token":token}));
        } else {
            let server = approval.server_id.as_ref().ok_or("缺少服务器")?;
            if !inner.exposed.contains(server) { return Err("服务器已停止向 Agent 开放".into()); }
            let session = approval.session_id.as_ref().and_then(|id| inner.sessions.get_mut(id)).ok_or("会话已撤销")?;
            session.writes.insert(server.clone());
        }
    }
    let value = inner.approvals.get_mut(&id).ok_or("授权请求已失效")?;
    value.status = if approved { "approved" } else { "denied" }.into(); value.credential = credential;
    gateway.record(&mut inner, json!({"timestamp":now(),"type":approval.kind,"agent":approval.agent_name,"serverId":approval.server_id,"result":if approved {"approved"}else{"denied"}}));
    drop(inner); gateway.changed(); Ok(())
}

#[tauri::command]
pub fn gateway_revoke(gateway: State<'_, Arc<Gateway>>, id: String) -> Result<(), String> {
    let mut inner = gateway.inner.lock().map_err(error)?; Gateway::revoke_locked(&mut inner, &id);
    gateway.record(&mut inner, json!({"timestamp":now(),"sessionId":id,"result":"revoked"}));
    drop(inner); gateway.changed(); Ok(())
}

#[tauri::command]
pub fn gateway_expose(gateway: State<'_, Arc<Gateway>>, id: String, enabled: bool) -> Result<(), String> {
    if !gateway.core.servers().map_err(error)?.iter().any(|server| server.id == id) { return Err("服务器不存在".into()); }
    let mut inner = gateway.inner.lock().map_err(error)?;
    let mut exposed = inner.exposed.clone(); if enabled { exposed.insert(id.clone()); } else { exposed.remove(&id); }
    gateway.core.save_private_setting("agent.exposed", &serde_json::to_string(&exposed).map_err(error)?).map_err(error)?;
    inner.exposed = exposed;
    if !enabled {
        for session in inner.sessions.values_mut() { session.writes.remove(&id); session.shells.retain(|_, shell| { if shell.server == id { shell.stop(); false } else { true } }); for job in session.jobs.values().filter(|job| job.server == id) { job.value.cancel(); } }
        inner.approvals.retain(|_, approval| approval.server_id.as_deref() != Some(&id));
    }
    drop(inner); gateway.changed(); Ok(())
}

#[tauri::command]
pub async fn gateway_enable(gateway: State<'_, Arc<Gateway>>, enabled: bool) -> Result<(), String> {
    if !enabled { gateway.stop(); return Ok(()); }
    #[cfg(not(windows))]
    { Err("此 Agent 传输用于 Windows 命名管道".into()) }
    #[cfg(windows)]
    {
        let mut listener = gateway.listener.lock().map_err(error)?;
        if listener.as_ref().map(|listener| !listener.is_finished()).unwrap_or(false) { return Ok(()); }
        listener.take();
        let mut pipe = crate::agent_transport::create_pipe(true).map_err(error)?;
        gateway.inner.lock().map_err(error)?.enabled = true;
        let shared = gateway.inner().clone();
        *listener = Some(tokio::spawn(async move {
            let mut clients = tokio::task::JoinSet::new();
            loop {
                if pipe.connect().await.is_err() { break; }
                let next = match crate::agent_transport::create_pipe(false) { Ok(next) => next, Err(_) => break };
                let connected = std::mem::replace(&mut pipe, next);
                while clients.try_join_next().is_some() {}
                if clients.len() >= 32 { drop(connected); continue; }
                let gateway = shared.clone();
                clients.spawn(async move {
                    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
                    let (reader, mut writer) = tokio::io::split(connected);
                    let mut bytes = Vec::new();
                    let read = tokio::time::timeout(Duration::from_secs(30), BufReader::new(reader).take(128 * 1024).read_until(b'\n', &mut bytes)).await;
                    if !matches!(read, Ok(Ok(_))) || bytes.last() != Some(&b'\n') { return; }
                    let request = match serde_json::from_slice::<Request>(&bytes) { Ok(request) => request, Err(_) => return };
                    let result = tauri::async_runtime::spawn_blocking(move || gateway.handle(request)).await;
                    if let Ok(response) = result { if let Ok(mut data) = serde_json::to_vec(&response) { data.push(b'\n'); let _ = tokio::time::timeout(Duration::from_secs(30), writer.write_all(&data)).await; } }
                });
            }
            if let Ok(mut inner) = shared.inner.lock() {
                inner.enabled = false;
                let ids: Vec<_> = inner.sessions.keys().cloned().collect();
                for id in ids { Gateway::revoke_locked(&mut inner, &id); }
                inner.approvals.clear();
            }
            shared.changed();
        }));
        drop(listener); gateway.changed(); Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn uncertain_commands_require_explicit_write_grant() {
        for command in ["rm -rf /tmp/test", "echo hi > file", "ls; touch file", "ls $(touch file)", "python3 script.py", "find . -delete", "git branch new", "docker run image"] { assert!(requires_write(command, "read"), "{command}"); }
        assert!(!requires_write("uname -a", "read")); assert!(requires_write("uname -a", "write"));
    }
    #[test]
    fn authentication_rejects_other_tokens_and_revoke_clears_grants() {
        let mut inner = Inner::default();
        inner.sessions.insert("session".into(), Session { token: "secret".into(), name: "test".into(), created: Instant::now(), touched: Instant::now(), created_at: now(), writes: HashSet::from(["server".into()]), jobs: HashMap::new(), idempotency: HashMap::new(), shells: HashMap::new() });
        let mut request = Request { id: "request".into(), op: "call".into(), session_id: Some("session".into()), token: Some("wrong!".into()), tool: None, args: Value::Null };
        assert!(Gateway::authenticated(&mut inner, &request).is_err());
        request.token = Some("secret".into()); assert!(Gateway::authenticated(&mut inner, &request).is_ok());
        Gateway::revoke_locked(&mut inner, "session"); assert!(Gateway::authenticated(&mut inner, &request).is_err());
    }
}
