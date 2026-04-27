use std::ffi::{CStr, CString, c_void};
use std::os::raw::c_char;
use std::ptr;

use crate::{OrbitApp, init_logging};
use crate::models::*;
use crate::ssh;
use crate::sftp;
use crate::monitor;
use crate::sftp::SftpManager;

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
pub extern "C" fn orbit_add_server(app: *mut OrbitApp, json_input: *const c_char, out_json: *mut *mut c_char) -> i32 {
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
pub extern "C" fn orbit_update_server(app: *mut OrbitApp, id: *const c_char, json_input: *const c_char, out_json: *mut *mut c_char) -> i32 {
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
pub extern "C" fn orbit_list_credential_groups(app: *mut OrbitApp, out_json: *mut *mut c_char) -> i32 {
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
pub extern "C" fn orbit_add_credential_group(app: *mut OrbitApp, json_input: *const c_char, out_json: *mut *mut c_char) -> i32 {
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
pub extern "C" fn orbit_update_credential_group(app: *mut OrbitApp, id: *const c_char, json_input: *const c_char, out_json: *mut *mut c_char) -> i32 {
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
        Ok(guard) => if guard.session.authenticated() { 1 } else { 0 },
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
        Err(_) => return -4,
    };
    match mgr.connect(&session_id, &server, &app.db, data_cb, closed_cb) {
        Ok(_) => {
            let c_id = CString::new(sid_for_cb).unwrap_or_default();
            unsafe { *out_session_id = c_id.into_raw() };
            0
        }
        Err(_) => -5,
    }
}

#[no_mangle]
pub extern "C" fn orbit_write_ssh(app: *mut OrbitApp, session_id: *const c_char, data: *const u8, data_len: usize) -> i32 {
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
pub extern "C" fn orbit_resize_ssh(app: *mut OrbitApp, session_id: *const c_char, cols: u32, rows: u32) -> i32 {
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
pub extern "C" fn orbit_get_ssh_traffic(app: *mut OrbitApp, session_id: *const c_char, out_read: *mut u64, out_written: *mut u64) -> i32 {
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
pub extern "C" fn orbit_sftp_list(app: *mut OrbitApp, server_id: *const c_char, path: *const c_char, out_json: *mut *mut c_char) -> i32 {
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
    match sftp::SftpManager::list_dir(&app.pool, &server, &app.db, path_str) {
        Ok(entries) => json_to_out(&entries, out_json),
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_list_fast(app: *mut OrbitApp, server_id: *const c_char, path: *const c_char, out_json: *mut *mut c_char) -> i32 {
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
    match SftpManager::list_dir_fast(&app.pool, &server, &app.db, path_str) {
        Ok(entries) => json_to_out(&entries, out_json),
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_stat_dir_entries(app: *mut OrbitApp, server_id: *const c_char, path: *const c_char, out_json: *mut *mut c_char) -> i32 {
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
    match SftpManager::stat_dir_entries(&app.pool, &server, &app.db, path_str) {
        Ok(stats) => json_to_out(&stats, out_json),
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
pub extern "C" fn orbit_sftp_mkdir(app: *mut OrbitApp, server_id: *const c_char, path: *const c_char) -> i32 {
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
pub extern "C" fn orbit_sftp_remove(app: *mut OrbitApp, server_id: *const c_char, path: *const c_char, is_dir: bool) -> i32 {
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
pub extern "C" fn orbit_get_server_stats(app: *mut OrbitApp, server_id: *const c_char, out_json: *mut *mut c_char) -> i32 {
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
    match ssh::SshManager::exec_command(&app.pool, &server, &app.db, monitor::get_monitor_script()) {
        Ok(output) => match monitor::collect_stats(&output) {
            Ok(stats) => json_to_out(&stats, out_json),
            Err(_) => -5,
        },
        Err(_) => -4,
    }
}

#[no_mangle]
pub extern "C" fn orbit_get_server_home(app: *mut OrbitApp, server_id: *const c_char, out_home: *mut *mut c_char) -> i32 {
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
