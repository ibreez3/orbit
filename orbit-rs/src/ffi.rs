use std::ffi::{c_void, CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::docker;
use crate::models::*;
use crate::monitor;
use crate::sftp;
use crate::sftp::SftpManager;
use crate::ssh;
use crate::{init_logging, OrbitApp};
use tracing::{error, info};

pub type OrbitDataCallback = extern "C" fn(*const c_char, *const u8, usize, *mut c_void);
pub type OrbitClosedCallback = extern "C" fn(*const c_char, *mut c_void);
pub type OrbitProgressCallback = extern "C" fn(*const c_char, u64, u64, *mut c_void);

#[no_mangle]
pub extern "C" fn orbit_app_new(db_path: *const c_char) -> *mut OrbitApp {
    if db_path.is_null() {
        return ptr::null_mut();
    }
    let db_path_str = match unsafe { CStr::from_ptr(db_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return ptr::null_mut(),
    };
    let app_dir = std::path::Path::new(db_path_str)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();
    init_logging(&app_dir);

    match OrbitApp::new(db_path_str) {
        Ok(app) => Box::into_raw(Box::new(app)),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn orbit_app_free(app: *mut OrbitApp) {
    if !app.is_null() {
        unsafe { drop(Box::from_raw(app)) };
    }
}

#[no_mangle]
pub extern "C" fn orbit_list_servers(app: *mut OrbitApp, out_json: *mut *mut c_char) -> i32 {
    if app.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    match app.db.list_servers() {
        Ok(servers) => json_to_out(&servers, out_json),
        Err(_) => -2,
    }
}

#[no_mangle]
pub extern "C" fn orbit_add_server(
    app: *mut OrbitApp,
    json_input: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || json_input.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let input = match parse_json_input::<ServerInput>(json_input) {
        Ok(i) => i,
        Err(_) => return -2,
    };
    match app.db.add_server(&input) {
        Ok(server) => json_to_out(&server, out_json),
        Err(_) => -3,
    }
}

#[no_mangle]
pub extern "C" fn orbit_update_server(
    app: *mut OrbitApp,
    id: *const c_char,
    json_input: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || id.is_null() || json_input.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let id_str = match unsafe { CStr::from_ptr(id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let input = match parse_json_input::<ServerInput>(json_input) {
        Ok(i) => i,
        Err(_) => return -2,
    };
    match app.db.update_server(id_str, &input) {
        Ok(server) => json_to_out(&server, out_json),
        Err(_) => -3,
    }
}

#[no_mangle]
pub extern "C" fn orbit_delete_server(app: *mut OrbitApp, id: *const c_char) -> i32 {
    if app.is_null() || id.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let id_str = match unsafe { CStr::from_ptr(id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    app.pool.remove(id_str);
    match app.db.delete_server(id_str) {
        Ok(_) => 0,
        Err(_) => -3,
    }
}

#[no_mangle]
pub extern "C" fn orbit_list_credential_groups(
    app: *mut OrbitApp,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    match app.db.list_credential_groups() {
        Ok(groups) => json_to_out(&groups, out_json),
        Err(_) => -2,
    }
}

#[no_mangle]
pub extern "C" fn orbit_add_credential_group(
    app: *mut OrbitApp,
    json_input: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || json_input.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let input = match parse_json_input::<CredentialGroupInput>(json_input) {
        Ok(i) => i,
        Err(_) => return -2,
    };
    match app.db.add_credential_group(&input) {
        Ok(group) => json_to_out(&group, out_json),
        Err(_) => -3,
    }
}

#[no_mangle]
pub extern "C" fn orbit_update_credential_group(
    app: *mut OrbitApp,
    id: *const c_char,
    json_input: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || id.is_null() || json_input.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let id_str = match unsafe { CStr::from_ptr(id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let input = match parse_json_input::<CredentialGroupInput>(json_input) {
        Ok(i) => i,
        Err(_) => return -2,
    };
    match app.db.update_credential_group(id_str, &input) {
        Ok(group) => json_to_out(&group, out_json),
        Err(_) => -3,
    }
}

#[no_mangle]
pub extern "C" fn orbit_delete_credential_group(app: *mut OrbitApp, id: *const c_char) -> i32 {
    if app.is_null() || id.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let id_str = match unsafe { CStr::from_ptr(id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    match app.db.delete_credential_group(id_str) {
        Ok(_) => 0,
        Err(_) => -3,
    }
}

#[no_mangle]
pub extern "C" fn orbit_test_connection(app: *mut OrbitApp, json_input: *const c_char) -> i32 {
    if app.is_null() || json_input.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let input = match parse_json_input::<ServerInput>(json_input) {
        Ok(i) => i,
        Err(_) => return -2,
    };
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
    match crate::transport::create_session(&server, &app.db) {
        Ok(guard) => {
            if guard.session.authenticated() {
                1
            } else {
                0
            }
        }
        Err(_) => 0,
    }
}

#[no_mangle]
pub extern "C" fn orbit_connect_ssh(
    app: *mut OrbitApp,
    server_id: *const c_char,
    data_cb: OrbitDataCallback,
    closed_cb: OrbitClosedCallback,
    userdata: *mut std::ffi::c_void,
    out_session_id: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || out_session_id.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid_str = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid_str) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    let session_id = uuid::Uuid::new_v4().to_string();
    let sid_for_cb = session_id.clone();
    let ud = userdata as usize;

    // --- Try to reuse idle connection from pool ---
    let reused = {
        let mut mgr = match app.ssh.lock() {
            Ok(m) => m,
            Err(_) => return -4,
        };
        mgr.take_idle_session(sid_str)
    };

    if let Some((guard, session_lock)) = reused {
        let data_cb: ssh::DataCallback = Box::new(move |sid: &str, data: &[u8]| {
            let c_sid = match CString::new(sid) {
                Ok(s) => s,
                Err(_) => return,
            };
            data_cb(c_sid.as_ptr(), data.as_ptr(), data.len(), ud as *mut c_void);
        });

        let closed_cb: ssh::ClosedCallback = Box::new(move |sid: &str| {
            let c_sid = match CString::new(sid) {
                Ok(s) => s,
                Err(_) => return,
            };
            closed_cb(c_sid.as_ptr(), ud as *mut c_void);
        });

        let channel_result = {
            let _lock = match session_lock.lock() {
                Ok(l) => l,
                Err(_) => return -6,
            };
            guard.session.set_blocking(true);
            let result: anyhow::Result<ssh2::Channel> = (|| {
                let mut channel = guard.session.channel_session()?;
                channel.setenv("LANG", "en_US.UTF-8")?;
                channel.setenv("LC_ALL", "en_US.UTF-8")?;
                channel.request_pty("xterm-256color", None, None)?;
                channel.shell()?;
                Ok(channel)
            })();
            guard.session.set_blocking(false);
            drop(_lock);
            result
        };

        match channel_result {
            Ok(channel) => {
                match ssh::spawn_channel_reader(
                    &session_id,
                    channel,
                    data_cb,
                    closed_cb,
                    session_lock.clone(),
                ) {
                    Ok(active_channel) => {
                        let mut mgr = match app.ssh.lock() {
                            Ok(m) => m,
                            Err(_) => return -4,
                        };
                        mgr.register_session(
                            &session_id,
                            sid_str,
                            guard,
                            active_channel,
                            session_lock,
                        );
                        let c_id = CString::new(sid_for_cb).unwrap_or_default();
                        unsafe { *out_session_id = c_id.into_raw() };
                        return 0;
                    }
                    Err(_) => {}
                }
            }
            Err(_) => {
                info!(server_id = sid_str, "空闲连接已失效，创建新连接");
            }
        }
        // Reuse failed — guard dropped, stale connection cleaned up. Fall through.
    }

    // --- No idle session → create new connection ---
    let guard = match crate::transport::create_session(&server, &app.db) {
        Ok(g) => g,
        Err(_) => return -5,
    };

    let mut channel: ssh2::Channel = match guard.session.channel_session() {
        Ok(ch) => ch,
        Err(_) => return -6,
    };
    let _ = channel.setenv("LANG", "en_US.UTF-8");
    let _ = channel.setenv("LC_ALL", "en_US.UTF-8");
    if channel.request_pty("xterm-256color", None, None).is_err() {
        return -7;
    }
    if channel.shell().is_err() {
        return -8;
    }
    guard.session.set_blocking(false);

    let data_cb: ssh::DataCallback = Box::new(move |sid: &str, data: &[u8]| {
        let c_sid = match CString::new(sid) {
            Ok(s) => s,
            Err(_) => return,
        };
        data_cb(c_sid.as_ptr(), data.as_ptr(), data.len(), ud as *mut c_void);
    });

    let closed_cb: ssh::ClosedCallback = Box::new(move |sid: &str| {
        let c_sid = match CString::new(sid) {
            Ok(s) => s,
            Err(_) => return,
        };
        closed_cb(c_sid.as_ptr(), ud as *mut c_void);
    });

    let session_lock = std::sync::Arc::new(std::sync::Mutex::new(()));
    let active_channel = match ssh::spawn_channel_reader(
        &session_id,
        channel,
        data_cb,
        closed_cb,
        session_lock.clone(),
    ) {
        Ok(ac) => ac,
        Err(_) => return -9,
    };

    let mut mgr = match app.ssh.lock() {
        Ok(m) => m,
        Err(_) => return -4,
    };
    mgr.register_session(&session_id, sid_str, guard, active_channel, session_lock);
    let c_id = CString::new(sid_for_cb).unwrap_or_default();
    unsafe { *out_session_id = c_id.into_raw() };
    0
}

#[no_mangle]
pub extern "C" fn orbit_spawn_channel(
    app: *mut OrbitApp,
    existing_session_id: *const c_char,
    data_cb: OrbitDataCallback,
    closed_cb: OrbitClosedCallback,
    userdata: *mut std::ffi::c_void,
    out_channel_id: *mut *mut c_char,
) -> i32 {
    if app.is_null() || existing_session_id.is_null() || out_channel_id.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let existing_sid = match unsafe { CStr::from_ptr(existing_session_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let channel_id = uuid::Uuid::new_v4().to_string();
    let cid_for_cb = channel_id.clone();
    let ud = userdata as usize;

    let data_cb: ssh::DataCallback = Box::new(move |sid: &str, data: &[u8]| {
        let c_sid = match CString::new(sid) {
            Ok(s) => s,
            Err(_) => return,
        };
        data_cb(c_sid.as_ptr(), data.as_ptr(), data.len(), ud as *mut c_void);
    });

    let closed_cb: ssh::ClosedCallback = Box::new(move |sid: &str| {
        let c_sid = match CString::new(sid) {
            Ok(s) => s,
            Err(_) => return,
        };
        closed_cb(c_sid.as_ptr(), ud as *mut c_void);
    });

    let mut mgr = match app.ssh.lock() {
        Ok(m) => m,
        Err(_) => return -3,
    };
    match mgr.spawn_channel(existing_sid, &channel_id, data_cb, closed_cb) {
        Ok(_) => {
            let c_id = CString::new(cid_for_cb).unwrap_or_default();
            unsafe { *out_channel_id = c_id.into_raw() };
            0
        }
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_write_ssh(
    app: *mut OrbitApp,
    session_id: *const c_char,
    data: *const u8,
    data_len: usize,
) -> i32 {
    if app.is_null() || session_id.is_null() || data.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(session_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let buf = unsafe { std::slice::from_raw_parts(data, data_len) };
    let mgr = match app.ssh.lock() {
        Ok(m) => m,
        Err(_) => return -3,
    };
    match mgr.write(sid, buf) {
        Ok(_) => 0,
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_resize_ssh(
    app: *mut OrbitApp,
    session_id: *const c_char,
    cols: u32,
    rows: u32,
) -> i32 {
    if app.is_null() || session_id.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(session_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let mgr = match app.ssh.lock() {
        Ok(m) => m,
        Err(_) => return -3,
    };
    match mgr.resize(sid, cols, rows) {
        Ok(_) => 0,
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_disconnect_ssh(app: *mut OrbitApp, session_id: *const c_char) -> i32 {
    if app.is_null() || session_id.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(session_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let mut mgr = match app.ssh.lock() {
        Ok(m) => m,
        Err(_) => return -3,
    };
    match mgr.disconnect(sid) {
        Ok(_) => 0,
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_get_ssh_traffic(
    app: *mut OrbitApp,
    session_id: *const c_char,
    out_read: *mut u64,
    out_written: *mut u64,
) -> i32 {
    if app.is_null() || session_id.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(session_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let mgr = match app.ssh.lock() {
        Ok(m) => m,
        Err(_) => return -3,
    };
    match mgr.get_traffic(sid) {
        Ok(stats) => {
            if !out_read.is_null() {
                unsafe { *out_read = stats.bytes_read };
            }
            if !out_written.is_null() {
                unsafe { *out_written = stats.bytes_written };
            }
            0
        }
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_list_full(
    app: *mut OrbitApp,
    server_id: *const c_char,
    path: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || path.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match SftpManager::list_dir_full(&app.pool, &server, &app.db, path_str) {
        Ok(entries) => json_to_out(&entries, out_json),
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_download(
    app: *mut OrbitApp,
    server_id: *const c_char,
    remote_path: *const c_char,
    local_path: *const c_char,
    progress_cb: OrbitProgressCallback,
    userdata: *mut std::ffi::c_void,
) -> i32 {
    if app.is_null() || server_id.is_null() || remote_path.is_null() || local_path.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let remote = match unsafe { CStr::from_ptr(remote_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let local = match unsafe { CStr::from_ptr(local_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    let sid_c = CString::new(sid).unwrap_or_default();
    let ud = userdata as usize;
    let cb: sftp::ProgressCallback = Box::new(move |transferred, total| {
        progress_cb(sid_c.as_ptr(), transferred, total, ud as *mut c_void);
    });
    match sftp::SftpManager::download_file(&app.pool, &server, &app.db, remote, local, Some(&cb)) {
        Ok(_) => 0,
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_upload(
    app: *mut OrbitApp,
    server_id: *const c_char,
    local_path: *const c_char,
    remote_path: *const c_char,
    progress_cb: OrbitProgressCallback,
    userdata: *mut std::ffi::c_void,
) -> i32 {
    if app.is_null() || server_id.is_null() || local_path.is_null() || remote_path.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let local = match unsafe { CStr::from_ptr(local_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let remote = match unsafe { CStr::from_ptr(remote_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    let sid_c = CString::new(sid).unwrap_or_default();
    let ud = userdata as usize;
    let cb: sftp::ProgressCallback = Box::new(move |transferred, total| {
        progress_cb(sid_c.as_ptr(), transferred, total, ud as *mut c_void);
    });
    match sftp::SftpManager::upload_file(&app.pool, &server, &app.db, local, remote, Some(&cb)) {
        Ok(_) => 0,
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_mkdir(
    app: *mut OrbitApp,
    server_id: *const c_char,
    path: *const c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || path.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match sftp::SftpManager::mkdir(&app.pool, &server, &app.db, path_str) {
        Ok(_) => 0,
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_remove(
    app: *mut OrbitApp,
    server_id: *const c_char,
    path: *const c_char,
    is_dir: bool,
) -> i32 {
    if app.is_null() || server_id.is_null() || path.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match sftp::SftpManager::remove(&app.pool, &server, &app.db, path_str, is_dir) {
        Ok(_) => 0,
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_disconnect(app: *mut OrbitApp, server_id: *const c_char) -> i32 {
    if app.is_null() || server_id.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    app.pool.remove(sid);
    0
}

#[no_mangle]
pub extern "C" fn orbit_sftp_read_text_file(
    app: *mut OrbitApp,
    server_id: *const c_char,
    path: *const c_char,
    max_size: u64,
    out_content: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || path.is_null() || out_content.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match SftpManager::read_text_file(&app.pool, &server, &app.db, path_str, max_size) {
        Ok(content) => {
            info!(target: "orbit::ffi", server_id = %sid, path = %path_str, content_len = content.len(), "✅ orbit_sftp_read_text_file 成功");
            let c_str = CString::new(&content[..]);
            match c_str {
                Ok(s) => {
                    unsafe { *out_content = s.into_raw() };
                    0
                }
                Err(_) => {
                    error!(target: "orbit::ffi", server_id = %sid, path = %path_str, "CString 转换失败（含 null 字节），已过滤");
                    let sanitized: String = content.chars().filter(|&c| c != '\0').collect();
                    let s = CString::new(sanitized).unwrap_or_default();
                    unsafe { *out_content = s.into_raw() };
                    0
                }
            }
        }
        Err(e) => {
            error!(target: "orbit::ffi", server_id = %sid, path = %path_str, error = %e, "❌ orbit_sftp_read_text_file 失败");
            -4
        }
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_write_text_file(
    app: *mut OrbitApp,
    server_id: *const c_char,
    path: *const c_char,
    content: *const c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || path.is_null() || content.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let content_str = match unsafe { CStr::from_ptr(content) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    info!(target: "orbit::ffi", server_id = %sid, path = %path_str, content_len = content_str.len(), "🔵 orbit_sftp_write_text_file");
    match SftpManager::write_text_file(&app.pool, &server, &app.db, path_str, content_str) {
        Ok(_) => {
            info!(target: "orbit::ffi", server_id = %sid, path = %path_str, "✅ orbit_sftp_write_text_file 成功");
            0
        }
        Err(e) => {
            error!(target: "orbit::ffi", server_id = %sid, path = %path_str, error = %e, "❌ orbit_sftp_write_text_file 失败");
            -4
        }
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_rename(
    app: *mut OrbitApp,
    server_id: *const c_char,
    old_path: *const c_char,
    new_path: *const c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || old_path.is_null() || new_path.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let old = match unsafe { CStr::from_ptr(old_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let new = match unsafe { CStr::from_ptr(new_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    info!(target: "orbit::ffi", server_id = %sid, old = %old, new = %new, "🔵 orbit_sftp_rename");
    match SftpManager::rename(&app.pool, &server, &app.db, old, new) {
        Ok(_) => {
            info!(target: "orbit::ffi", server_id = %sid, old = %old, new = %new, "✅ orbit_sftp_rename 成功");
            0
        }
        Err(e) => {
            error!(target: "orbit::ffi", server_id = %sid, old = %old, new = %new, error = %e, "❌ orbit_sftp_rename 失败");
            -4
        }
    }
}

#[no_mangle]
pub extern "C" fn orbit_get_server_stats(
    app: *mut OrbitApp,
    server_id: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match ssh::SshManager::exec_command(&app.pool, &server, &app.db, monitor::get_monitor_script())
    {
        Ok(output) => match monitor::collect_stats(&output) {
            Ok(stats) => json_to_out(&stats, out_json),
            Err(_) => -5,
        },
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_get_server_home(
    app: *mut OrbitApp,
    server_id: *const c_char,
    out_home: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || out_home.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match ssh::SshManager::exec_command(&app.pool, &server, &app.db, "echo $HOME") {
        Ok(output) => {
            let home = output.trim().to_string();
            let c_home = CString::new(home).unwrap_or_default();
            unsafe { *out_home = c_home.into_raw() };
            0
        }
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_get_server_processes(
    app: *mut OrbitApp,
    server_id: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match ssh::SshManager::exec_command(&app.pool, &server, &app.db, monitor::get_process_script())
    {
        Ok(output) => {
            let processes = monitor::parse_processes(&output);
            json_to_out(&processes, out_json)
        }
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_docker_list_containers(
    app: *mut OrbitApp,
    server_id: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match docker::DockerManager::list_containers(&app.pool, &server, &app.db) {
        Ok(containers) => json_to_out(&containers, out_json),
        Err(e) => {
            error!(target: "orbit::ffi", server_id = %sid, error = %e, "Docker 容器列表获取失败");
            -4
        }
    }
}

#[no_mangle]
pub extern "C" fn orbit_docker_stats(
    app: *mut OrbitApp,
    server_id: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || out_json.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match docker::DockerManager::stats(&app.pool, &server, &app.db) {
        Ok(stats) => json_to_out(&stats, out_json),
        Err(e) => {
            error!(target: "orbit::ffi", server_id = %sid, error = %e, "Docker stats 获取失败");
            -4
        }
    }
}

#[no_mangle]
pub extern "C" fn orbit_docker_logs(
    app: *mut OrbitApp,
    server_id: *const c_char,
    container_id: *const c_char,
    tail: u32,
    out_logs: *mut *mut c_char,
) -> i32 {
    if app.is_null() || server_id.is_null() || container_id.is_null() || out_logs.is_null() {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let cid = match unsafe { CStr::from_ptr(container_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match docker::DockerManager::logs(&app.pool, &server, &app.db, cid, tail) {
        Ok(logs) => {
            let c_logs = CString::new(logs).unwrap_or_default();
            unsafe { *out_logs = c_logs.into_raw() };
            0
        }
        Err(e) => {
            error!(target: "orbit::ffi", server_id = %sid, container_id = %cid, error = %e, "Docker logs 获取失败");
            -4
        }
    }
}

#[no_mangle]
pub extern "C" fn orbit_docker_action(
    app: *mut OrbitApp,
    server_id: *const c_char,
    container_id: *const c_char,
    action: *const c_char,
    out_output: *mut *mut c_char,
) -> i32 {
    if app.is_null()
        || server_id.is_null()
        || container_id.is_null()
        || action.is_null()
        || out_output.is_null()
    {
        return -1;
    }
    let app = unsafe { &*app };
    let sid = match unsafe { CStr::from_ptr(server_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let cid = match unsafe { CStr::from_ptr(container_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let action_str = match unsafe { CStr::from_ptr(action) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let server = match app.db.get_server(sid) {
        Ok(s) => s,
        Err(_) => return -3,
    };
    match docker::DockerManager::action(&app.pool, &server, &app.db, cid, action_str) {
        Ok(output) => {
            let c_output = CString::new(output).unwrap_or_default();
            unsafe { *out_output = c_output.into_raw() };
            0
        }
        Err(e) => {
            error!(target: "orbit::ffi", server_id = %sid, container_id = %cid, action = %action_str, error = %e, "Docker 操作失败");
            -4
        }
    }
}

#[no_mangle]
pub extern "C" fn orbit_shutdown_pool(app: *mut OrbitApp) {
    if app.is_null() {
        return;
    }
    let app = unsafe { &*app };
    if let Ok(mut mgr) = app.ssh.lock() {
        mgr.shutdown();
    }
}

#[no_mangle]
pub extern "C" fn orbit_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

fn parse_json_input<T: serde::de::DeserializeOwned>(json: *const c_char) -> Result<T, ()> {
    let s = unsafe { CStr::from_ptr(json) }.to_str().map_err(|_| ())?;
    serde_json::from_str(s).map_err(|_| ())
}

fn json_to_out<T: serde::Serialize>(value: &T, out: *mut *mut c_char) -> i32 {
    match serde_json::to_string(value) {
        Ok(json) => {
            let c_str = CString::new(json).unwrap_or_default();
            unsafe { *out = c_str.into_raw() };
            0
        }
        Err(_) => -99,
    }
}
