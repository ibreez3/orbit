use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use orbit_core::desktop::DesktopCore;
use serde_json::{json, Value};
use uuid::Uuid;

#[derive(Default)]
struct Buffer { bytes: Vec<u8>, truncated: bool }

pub struct Shell {
    core: Arc<DesktopCore>,
    channel: String,
    pub server: String,
    buffer: Arc<Mutex<Buffer>>,
    closed: Arc<AtomicBool>,
    command: Mutex<()>,
}

impl Shell {
    pub fn open(core: Arc<DesktopCore>, server: String) -> Result<Self, String> {
        let buffer = Arc::new(Mutex::new(Buffer::default())); let closed = Arc::new(AtomicBool::new(false));
        let data = buffer.clone(); let ended = closed.clone();
        let channel = core.connect(&server, Box::new(move |_, bytes| {
            if let Ok(mut buffer) = data.lock() {
                buffer.bytes.extend_from_slice(bytes);
                if buffer.bytes.len() > 1_048_576 { let excess = buffer.bytes.len() - 1_048_576; buffer.bytes.drain(..excess); buffer.truncated = true; }
            }
        }), Box::new(move |_| { ended.store(true, Ordering::SeqCst); })).map_err(|error| error.to_string())?;
        let shell = Self { core, channel, server, buffer, closed, command: Mutex::new(()) };
        shell.execute("stty -echo", 10_000)?;
        Ok(shell)
    }

    pub fn stop(&self) {
        self.closed.store(true, Ordering::SeqCst);
        let _ = self.core.disconnect(&self.channel);
    }

    pub fn execute(&self, command: &str, timeout_ms: u64) -> Result<Value, String> {
        let _command = self.command.try_lock().map_err(|_| "Shell 正在执行其他命令")?;
        if self.closed.load(Ordering::SeqCst) { return Err("Shell 已关闭".into()); }
        if command.trim().is_empty() || command.len() > 64 * 1024 || !(1..=50_000).contains(&timeout_ms) { return Err("命令或超时时间无效".into()); }
        let marker = format!("__ORBIT_DONE_{}__", Uuid::new_v4().simple());
        if let Ok(mut buffer) = self.buffer.lock() { buffer.bytes.clear(); buffer.truncated = false; }
        let input = format!("{command}\nprintf '\\n{marker}%s\\n' \"$?\"\n");
        self.core.write(&self.channel, input.as_bytes()).map_err(|error| error.to_string())?;
        let start = Instant::now();
        loop {
            if self.closed.load(Ordering::SeqCst) { return Err("Shell 已关闭或授权已撤销".into()); }
            if let Ok(mut buffer) = self.buffer.lock() {
                if let Some((position, end, exit_code)) = completion(&buffer.bytes, marker.as_bytes()) {
                    let output = String::from_utf8_lossy(&buffer.bytes[..position]).trim_end_matches(['\r','\n']).to_string();
                    let truncated = buffer.truncated; buffer.bytes.drain(..end);
                    return Ok(json!({"output":output,"exitCode":exit_code,"truncated":truncated,"durationMs":start.elapsed().as_millis() as u64}));
                }
            }
            if start.elapsed() >= Duration::from_millis(timeout_ms) { self.stop(); return Err("Shell 命令超时，已关闭会话".into()); }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Shell { fn drop(&mut self) { self.stop(); } }

fn completion(bytes: &[u8], marker: &[u8]) -> Option<(usize, usize, i32)> {
    let mut start = 0;
    for (index, byte) in bytes.iter().enumerate() {
        if *byte != b'\n' { continue; }
        let line = &bytes[start..index];
        if let Some(code) = line.strip_prefix(marker).and_then(|value| std::str::from_utf8(value).ok()).and_then(|value| value.trim_end_matches('\r').parse().ok()) { return Some((start, index + 1, code)); }
        start = index + 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn completion_only_accepts_complete_marker_lines() {
        assert_eq!(completion(b"echo __MARK__0\r\noutput\r\n__MARK__7\r\n", b"__MARK__"), Some((24, 35, 7)));
        assert!(completion(b"__MARK__0", b"__MARK__").is_none());
        assert!(completion(b"prefix__MARK__0\n", b"__MARK__").is_none());
    }
}
