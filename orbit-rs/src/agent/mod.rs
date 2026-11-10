use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use serde::Serialize;

use crate::db::Database;
use crate::models::Server;
use crate::transport;
use crate::transport::SessionPool;

/// Result of one agent-facing command execution.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentExecOutput {
    pub status: String,
    pub server_id: String,
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i32,
    pub duration_ms: u64,
    pub truncated: bool,
    pub stdout_bytes: usize,
    pub stderr_bytes: usize,
    pub job_id: Option<String>,
    pub mode: String,
    pub escalated: bool,
}

/// Truncates a string to at most `limit` bytes without splitting a UTF-8
/// character, returning the retained text and whether anything was dropped.
pub fn truncate_agent_output(input: &str, limit: usize) -> (String, bool) {
    if input.len() <= limit {
        return (input.to_string(), false);
    }
    let mut end = limit;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    (input[..end].to_string(), true)
}

/// Executes a command for an AI agent. Unlike the terminal-facing exec path,
/// stdout and stderr are drained together in a non-blocking loop so a full
/// stderr pipe cannot deadlock the command.
pub fn exec_agent_command(
    pool: &SessionPool,
    server: &Server,
    db: &Database,
    command: &str,
    timeout_ms: u32,
    max_bytes: usize,
) -> Result<AgentExecOutput> {
    let started = Instant::now();
    let _lease = pool.acquire_scoped(server, db)?;

    pool.with_session_mut(&server.id, |session| {
        let result = (|| -> Result<AgentExecOutput> {
            let mut channel = session.channel_session()?;
            channel.exec(command)?;

            let mut stderr_stream = channel.stderr();
            let _ = session.set_blocking(false);

            let limit = if max_bytes == 0 { usize::MAX } else { max_bytes };
            let mut stdout = Vec::new();
            let mut stderr = Vec::new();
            let mut stdout_total = 0usize;
            let mut stderr_total = 0usize;
            let mut truncated = false;
            let mut stdout_eof = false;
            let mut stderr_eof = false;
            let mut timed_out = false;
            let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1) as u64);
            let mut buf = [0u8; 8192];

            while !(stdout_eof && stderr_eof) {
                if Instant::now() >= deadline {
                    timed_out = true;
                    break;
                }

                let mut progressed = false;
                if !stdout_eof {
                    match channel.read(&mut buf) {
                        Ok(0) => stdout_eof = true,
                        Ok(read) => {
                            stdout_total += read;
                            append_capped(&mut stdout, &buf[..read], limit, &mut truncated);
                            progressed = true;
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                        Err(error) => return Err(error.into()),
                    }
                }
                if !stderr_eof {
                    match stderr_stream.read(&mut buf) {
                        Ok(0) => stderr_eof = true,
                        Ok(read) => {
                            stderr_total += read;
                            append_capped(&mut stderr, &buf[..read], limit, &mut truncated);
                            progressed = true;
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                        Err(error) => return Err(error.into()),
                    }
                }
                if !progressed {
                    std::thread::sleep(Duration::from_millis(2));
                }
            }

            drop(stderr_stream);
            let _ = session.set_blocking(true);
            let exit_code = if timed_out {
                -1
            } else {
                channel.exit_status().unwrap_or(-1)
            };

            Ok(AgentExecOutput {
                status: if timed_out { "timed_out" } else { "completed" }.to_string(),
                server_id: server.id.clone(),
                stdout: String::from_utf8_lossy(&stdout).into_owned(),
                stderr: String::from_utf8_lossy(&stderr).into_owned(),
                exit_code,
                duration_ms: started.elapsed().as_millis() as u64,
                truncated,
                stdout_bytes: stdout_total,
                stderr_bytes: stderr_total,
                job_id: None,
                mode: "read".to_string(),
                escalated: false,
            })
        })();

        let _ = session.set_blocking(true);
        result
    })
}

fn append_capped(target: &mut Vec<u8>, bytes: &[u8], limit: usize, truncated: &mut bool) {
    let remaining = limit.saturating_sub(target.len());
    if remaining == 0 {
        if !bytes.is_empty() {
            *truncated = true;
        }
        return;
    }
    let take = remaining.min(bytes.len());
    target.extend_from_slice(&bytes[..take]);
    if take < bytes.len() {
        *truncated = true;
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentJobState {
    Running,
    Completed,
    Failed,
    TimedOut,
    Cancelled,
}

impl AgentJobState {
    fn as_str(self) -> &'static str {
        match self {
            AgentJobState::Running => "running",
            AgentJobState::Completed => "completed",
            AgentJobState::Failed => "failed",
            AgentJobState::TimedOut => "timed_out",
            AgentJobState::Cancelled => "cancelled",
        }
    }
}

pub struct AgentOutputBuffer {
    data: Vec<u8>,
    limit: usize,
    truncated: bool,
}

impl AgentOutputBuffer {
    pub fn new(limit: usize) -> Self {
        Self {
            data: Vec::new(),
            limit: if limit == 0 { usize::MAX } else { limit },
            truncated: false,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) {
        append_capped(&mut self.data, bytes, self.limit, &mut self.truncated);
    }

    pub fn read(&self, from: usize) -> (String, usize) {
        let start = from.min(self.data.len());
        let chunk = String::from_utf8_lossy(&self.data[start..]).into_owned();
        (chunk, self.data.len())
    }

    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_truncated(&self) -> bool {
        self.truncated
    }
}

struct AgentJobInner {
    state: AgentJobState,
    exit_code: Option<i32>,
    stdout: AgentOutputBuffer,
    stderr: AgentOutputBuffer,
    combined: AgentOutputBuffer,
    stdout_bytes: usize,
    stderr_bytes: usize,
    finished_at: Option<Instant>,
}

pub struct AgentJob {
    id: String,
    started: Instant,
    cancel: AtomicBool,
    inner: Mutex<AgentJobInner>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentJobStatusDto {
    pub job_id: String,
    pub status: AgentJobState,
    pub exit_code: Option<i32>,
    pub duration_ms: u64,
    pub truncated: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentJobOutputDto {
    pub job_id: String,
    pub chunk: String,
    pub next_cursor: usize,
    pub eof: bool,
    pub truncated: bool,
}

impl AgentJob {
    fn new(id: String, max_bytes: usize) -> Self {
        Self {
            id,
            started: Instant::now(),
            cancel: AtomicBool::new(false),
            inner: Mutex::new(AgentJobInner {
                state: AgentJobState::Running,
                exit_code: None,
                stdout: AgentOutputBuffer::new(max_bytes),
                stderr: AgentOutputBuffer::new(max_bytes),
                combined: AgentOutputBuffer::new(max_bytes),
                stdout_bytes: 0,
                stderr_bytes: 0,
                finished_at: None,
            }),
        }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    fn is_running(&self) -> bool {
        self.inner
            .lock()
            .map(|inner| inner.state == AgentJobState::Running)
            .unwrap_or(false)
    }

    fn push_stdout(&self, bytes: &[u8]) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.stdout_bytes += bytes.len();
            inner.stdout.push(bytes);
            inner.combined.push(bytes);
        }
    }

    fn push_stderr(&self, bytes: &[u8]) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.stderr_bytes += bytes.len();
            inner.stderr.push(bytes);
            inner.combined.push(bytes);
        }
    }

    fn finish(&self, state: AgentJobState, exit_code: Option<i32>) {
        if let Ok(mut inner) = self.inner.lock() {
            if inner.state == AgentJobState::Running {
                inner.state = state;
                inner.exit_code = exit_code;
                inner.finished_at = Some(Instant::now());
            }
        }
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    pub fn wait_for_finish(&self, wait_ms: u32) -> bool {
        let deadline = Instant::now() + Duration::from_millis(wait_ms as u64);
        loop {
            if self.is_finished() {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    pub fn is_finished(&self) -> bool {
        self.inner
            .lock()
            .map(|inner| inner.state != AgentJobState::Running)
            .unwrap_or(true)
    }

    pub fn status_dto(&self) -> AgentJobStatusDto {
        let (state, exit_code, duration_ms, truncated) = match self.inner.lock() {
            Ok(inner) => {
                let duration = inner
                    .finished_at
                    .unwrap_or_else(Instant::now)
                    .duration_since(self.started)
                    .as_millis() as u64;
                (
                    inner.state,
                    inner.exit_code,
                    duration,
                    inner.combined.is_truncated(),
                )
            }
            Err(_) => (AgentJobState::Failed, None, 0, false),
        };
        AgentJobStatusDto {
            job_id: self.id.clone(),
            status: state,
            exit_code,
            duration_ms,
            truncated,
        }
    }

    pub fn output_dto(&self, cursor: usize) -> AgentJobOutputDto {
        match self.inner.lock() {
            Ok(inner) => {
                let (chunk, next_cursor) = inner.combined.read(cursor);
                let eof = inner.state != AgentJobState::Running && cursor >= inner.combined.len();
                AgentJobOutputDto {
                    job_id: self.id.clone(),
                    chunk,
                    next_cursor,
                    eof,
                    truncated: inner.combined.is_truncated(),
                }
            }
            Err(_) => AgentJobOutputDto {
                job_id: self.id.clone(),
                chunk: String::new(),
                next_cursor: cursor,
                eof: true,
                truncated: false,
            },
        }
    }

    pub fn completed_output(&self, server_id: &str) -> AgentExecOutput {
        let (state, exit_code, stdout, stderr, truncated, stdout_bytes, stderr_bytes, duration_ms) =
            match self.inner.lock() {
                Ok(inner) => (
                    inner.state,
                    inner.exit_code,
                    inner.stdout.read(0).0,
                    inner.stderr.read(0).0,
                    inner.stdout.is_truncated() || inner.stderr.is_truncated(),
                    inner.stdout_bytes,
                    inner.stderr_bytes,
                    inner
                        .finished_at
                        .unwrap_or_else(Instant::now)
                        .duration_since(self.started)
                        .as_millis() as u64,
                ),
                Err(_) => (
                    AgentJobState::Failed,
                    None,
                    String::new(),
                    String::new(),
                    false,
                    0,
                    0,
                    0,
                ),
            };
        AgentExecOutput {
            status: state.as_str().to_string(),
            server_id: server_id.to_string(),
            stdout,
            stderr,
            exit_code: exit_code.unwrap_or(-1),
            duration_ms,
            truncated,
            stdout_bytes,
            stderr_bytes,
            job_id: None,
            mode: "read".to_string(),
            escalated: false,
        }
    }
}

pub struct AgentJobRegistry {
    jobs: std::collections::HashMap<String, Arc<AgentJob>>,
}

impl AgentJobRegistry {
    const MAX_RETAINED_JOBS: usize = 512;

    pub fn new() -> Self {
        Self {
            jobs: std::collections::HashMap::new(),
        }
    }

    pub fn insert(&mut self, job: Arc<AgentJob>) {
        if self.jobs.len() >= Self::MAX_RETAINED_JOBS {
            self.jobs.retain(|_, existing| existing.is_running());
        }
        self.jobs.insert(job.id().to_string(), job);
    }

    pub fn len(&self) -> usize {
        self.jobs.len()
    }

    pub fn get(&self, job_id: &str) -> Option<Arc<AgentJob>> {
        self.jobs.get(job_id).cloned()
    }

    pub fn remove(&mut self, job_id: &str) {
        self.jobs.remove(job_id);
    }
}

pub fn start_agent_job(
    server: Server,
    db_path: String,
    command: String,
    timeout_ms: u32,
    max_bytes: usize,
) -> (String, Arc<AgentJob>) {
    let id = uuid::Uuid::new_v4().to_string();
    let job = Arc::new(AgentJob::new(id.clone(), max_bytes));
    let worker = job.clone();
    std::thread::spawn(move || {
        run_agent_job(worker, server, db_path, command, timeout_ms);
    });
    (id, job)
}

fn run_agent_job(job: Arc<AgentJob>, server: Server, db_path: String, command: String, timeout_ms: u32) {
    let db = match Database::new(&db_path) {
        Ok(db) => db,
        Err(_) => {
            job.finish(AgentJobState::Failed, None);
            return;
        }
    };
    let guard = match transport::create_session(&server, &db) {
        Ok(guard) => guard,
        Err(_) => {
            job.finish(AgentJobState::Failed, None);
            return;
        }
    };
    let mut channel = match guard.session.channel_session() {
        Ok(channel) => channel,
        Err(_) => {
            job.finish(AgentJobState::Failed, None);
            return;
        }
    };
    if channel.exec(&command).is_err() {
        job.finish(AgentJobState::Failed, None);
        return;
    }
    let mut stderr_stream = channel.stderr();
    let _ = guard.session.set_blocking(false);
    let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1) as u64);
    let mut stdout_eof = false;
    let mut stderr_eof = false;
    let mut buffer = [0u8; 8192];

    loop {
        if job.cancel.load(Ordering::Relaxed) {
            let _ = guard.session.set_blocking(true);
            job.finish(AgentJobState::Cancelled, None);
            return;
        }
        if Instant::now() >= deadline {
            let _ = guard.session.set_blocking(true);
            job.finish(AgentJobState::TimedOut, None);
            return;
        }
        let mut progressed = false;
        if !stdout_eof {
            match channel.read(&mut buffer) {
                Ok(0) => stdout_eof = true,
                Ok(read) => {
                    job.push_stdout(&buffer[..read]);
                    progressed = true;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => {
                    let _ = guard.session.set_blocking(true);
                    job.finish(AgentJobState::Failed, None);
                    return;
                }
            }
        }
        if !stderr_eof {
            match stderr_stream.read(&mut buffer) {
                Ok(0) => stderr_eof = true,
                Ok(read) => {
                    job.push_stderr(&buffer[..read]);
                    progressed = true;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => {
                    let _ = guard.session.set_blocking(true);
                    job.finish(AgentJobState::Failed, None);
                    return;
                }
            }
        }
        if stdout_eof && stderr_eof {
            drop(stderr_stream);
            let _ = guard.session.set_blocking(true);
            let exit_code = channel.exit_status().unwrap_or(-1);
            job.finish(AgentJobState::Completed, Some(exit_code));
            return;
        }
        if !progressed {
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::truncate_agent_output;

    #[test]
    fn truncates_output_and_reports_truncation() {
        let (text, truncated) = truncate_agent_output("abcdef", 4);
        assert_eq!(text, "abcd");
        assert!(truncated);
    }

    #[test]
    fn keeps_output_below_limit() {
        let (text, truncated) = truncate_agent_output("abc", 4);
        assert_eq!(text, "abc");
        assert!(!truncated);
    }

    #[test]
    fn job_registry_keeps_a_bounded_number_of_finished_jobs() {
        let mut registry = super::AgentJobRegistry::new();
        for index in 0..600 {
            let job = std::sync::Arc::new(super::AgentJob::new(format!("job-{index}"), 1024));
            job.finish(super::AgentJobState::Completed, Some(0));
            registry.insert(job);
        }
        assert!(registry.len() <= 512);
    }

    #[test]
    fn job_output_cursor_returns_only_new_bytes() {
        let mut buffer = super::AgentOutputBuffer::new(16);
        buffer.push(b"hello");
        buffer.push(b" world");
        let (chunk, cursor) = buffer.read(0);
        assert_eq!(chunk, "hello world");
        let (tail, _) = buffer.read(cursor);
        assert_eq!(tail, "");
    }
}
