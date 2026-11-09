use std::io::{self, Read};
use std::time::{Duration, Instant};

use anyhow::Result;
use serde::Serialize;

use crate::db::Database;
use crate::models::Server;
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
}
