use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use tauri::ipc::Channel;
use crate::{error, Flow, TerminalEvent};

pub struct LocalTerminal {
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
}

impl LocalTerminal {
    pub fn start(flow: Arc<Flow>, output: Channel<TerminalEvent>) -> Result<Self, String> {
        let pair = native_pty_system().openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).map_err(error)?;
        let mut command = CommandBuilder::new(if cfg!(windows) { "powershell.exe" } else { "/bin/zsh" });
        if cfg!(windows) { command.args(["-NoLogo"]); } else { command.arg("-l"); }
        if let Some(directory) = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }) { command.cwd(directory); }
        command.env("TERM", "xterm-256color");
        let mut reader = pair.master.try_clone_reader().map_err(error)?;
        let writer = pair.master.take_writer().map_err(error)?;
        let mut child = pair.slave.spawn_command(command).map_err(error)?;
        let killer = child.clone_killer();
        drop(pair.slave);
        std::thread::spawn(move || { let _ = child.wait(); });
        std::thread::spawn(move || {
            let mut bytes = [0u8; 8192];
            loop {
                match reader.read(&mut bytes) {
                    Ok(0) | Err(_) => break,
                    Ok(length) => {
                        flow.send(&output, &bytes[..length]);
                        if flow.state.lock().map(|state| state.1).unwrap_or(true) { break; }
                    }
                }
            }
            let _ = output.send(TerminalEvent::Closed);
        });
        Ok(Self { master: Mutex::new(pair.master), writer: Mutex::new(writer), killer: Mutex::new(killer) })
    }

    pub fn write(&self, bytes: &[u8]) -> Result<(), String> {
        let mut writer = self.writer.lock().map_err(error)?;
        writer.write_all(bytes).map_err(error)?;
        writer.flush().map_err(error)
    }

    pub fn resize(&self, cols: u32, rows: u32) -> Result<(), String> {
        self.master.lock().map_err(error)?.resize(PtySize { rows: rows as u16, cols: cols as u16, pixel_width: 0, pixel_height: 0 }).map_err(error)
    }

    pub fn stop(&self) {
        if let Ok(mut killer) = self.killer.lock() { let _ = killer.kill(); }
    }
}

impl Drop for LocalTerminal {
    fn drop(&mut self) { self.stop(); }
}
