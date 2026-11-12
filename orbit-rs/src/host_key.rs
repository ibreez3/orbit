use std::collections::HashMap;
use std::ffi::CString;
#[cfg(test)]
use std::os::raw::c_char;
use std::sync::Mutex;

use anyhow::{anyhow, bail, Result};
use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine};
use rusqlite::OptionalExtension;
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::db::Database;
use crate::models::Server;

use crate::ffi::OrbitHostKeyCallback;

#[derive(Clone, Serialize)]
struct HostKeyRequest {
    id: String,
    host: String,
    port: u16,
    role: String,
    algorithm: String,
    fingerprint: String,
    previous_fingerprint: Option<String>,
    #[serde(skip)]
    key: Vec<u8>,
    #[serde(skip)]
    previous_key: Option<Vec<u8>>,
}

#[derive(Default)]
pub struct HostKeyVerifier {
    callback: Mutex<Option<OrbitHostKeyCallback>>,
    pending: Mutex<HashMap<String, HostKeyRequest>>,
}

fn fingerprint(key: &[u8]) -> String {
    format!("SHA256:{}", STANDARD_NO_PAD.encode(Sha256::digest(key)))
}

impl HostKeyVerifier {
    pub fn set_callback(&self, callback: Option<OrbitHostKeyCallback>) -> Result<()> {
        *self
            .callback
            .lock()
            .map_err(|_| anyhow!("主机指纹回调锁定失败"))? = callback;
        Ok(())
    }

    pub fn verify(
        &self,
        db: &Database,
        server: &Server,
        session: &ssh2::Session,
        role: &str,
    ) -> Result<()> {
        let (key, algorithm) = session
            .host_key()
            .ok_or_else(|| anyhow!("服务器未提供 SSH 主机公钥"))?;
        self.verify_key(
            db,
            &server.host,
            server.port,
            key,
            &format!("{:?}", algorithm),
            role,
        )
    }

    fn verify_key(
        &self,
        db: &Database,
        host: &str,
        port: u16,
        key: &[u8],
        algorithm: &str,
        role: &str,
    ) -> Result<()> {
        if key.is_empty() {
            bail!("服务器未提供 SSH 主机公钥");
        }
        let host = host.to_ascii_lowercase();
        let previous_key: Option<Vec<u8>> = db
            .conn
            .lock()
            .map_err(|_| anyhow!("数据库锁定失败"))?
            .query_row(
                "SELECT public_key FROM ssh_known_hosts WHERE host = ?1 AND port = ?2",
                (&host, port),
                |row| row.get(0),
            )
            .optional()?;
        if previous_key.as_deref() == Some(key) {
            return Ok(());
        }
        let current_fingerprint = fingerprint(key);
        let message = if previous_key.is_some() {
            format!("SSH 主机指纹已变化，连接已阻止：{}:{}（{}）。请核对新旧指纹后在 Orbit 中确认，确认后重试连接。", host, port, current_fingerprint)
        } else {
            format!("SSH 主机指纹尚未信任，连接已阻止：{}:{}（{}）。请在 Orbit 中核对并确认指纹，然后重试连接。", host, port, current_fingerprint)
        };
        let callback = *self
            .callback
            .lock()
            .map_err(|_| anyhow!("主机指纹回调锁定失败"))?;
        if let Some(callback) = callback {
            let request = {
                let mut pending = self
                    .pending
                    .lock()
                    .map_err(|_| anyhow!("主机指纹请求锁定失败"))?;
                if let Some(existing) = pending.values().find(|request| {
                    request.host == host
                        && request.port == port
                        && request.key == key
                        && request.previous_key == previous_key
                }) {
                    existing.clone()
                } else {
                    if pending.len() >= 128 {
                        bail!("待确认的 SSH 主机指纹过多，请先处理 Orbit 中的确认请求");
                    }
                    let request = HostKeyRequest {
                        id: uuid::Uuid::new_v4().to_string(),
                        host,
                        port,
                        role: role.to_string(),
                        algorithm: algorithm.to_string(),
                        fingerprint: current_fingerprint,
                        previous_fingerprint: previous_key.as_deref().map(fingerprint),
                        key: key.to_vec(),
                        previous_key,
                    };
                    pending.insert(request.id.clone(), request.clone());
                    request
                }
            };
            let json = CString::new(serde_json::to_string(&request)?)?;
            callback(json.as_ptr());
        }
        bail!(message)
    }

    pub fn resolve(&self, db: &Database, id: &str, trust: bool) -> Result<()> {
        let request = self
            .pending
            .lock()
            .map_err(|_| anyhow!("主机指纹请求锁定失败"))?
            .remove(id)
            .ok_or_else(|| anyhow!("主机指纹确认请求已失效，请重新连接"))?;
        if !trust {
            return Ok(());
        }
        let conn = db.conn.lock().map_err(|_| anyhow!("数据库锁定失败"))?;
        let tx = conn.unchecked_transaction()?;
        let current: Option<Vec<u8>> = tx
            .query_row(
                "SELECT public_key FROM ssh_known_hosts WHERE host = ?1 AND port = ?2",
                (&request.host, request.port),
                |row| row.get(0),
            )
            .optional()?;
        if current.as_ref() == Some(&request.key) {
            return Ok(());
        }
        if current != request.previous_key {
            bail!("已保存的 SSH 主机指纹发生变化，请重新连接并核对");
        }
        tx.execute(
            "INSERT INTO ssh_known_hosts (host, port, public_key) VALUES (?1, ?2, ?3)
             ON CONFLICT(host, port) DO UPDATE SET public_key = excluded.public_key",
            (&request.host, request.port, &request.key),
        )?;
        tx.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn notified(_json: *const c_char) {}

    fn db() -> Database {
        let db = Database::new(":memory:").unwrap();
        db.host_keys.set_callback(Some(notified)).unwrap();
        db
    }

    fn request(db: &Database, host: &str, port: u16, key: &[u8], role: &str) -> String {
        assert!(db
            .host_keys
            .verify_key(db, host, port, key, "Ed25519", role)
            .is_err());
        db.host_keys
            .pending
            .lock()
            .unwrap()
            .values()
            .find(|r| r.host == host.to_ascii_lowercase() && r.port == port && r.key == key)
            .unwrap()
            .id
            .clone()
    }

    #[test]
    fn unknown_host_fails_closed_without_callback() {
        let db = Database::new(":memory:").unwrap();
        assert!(db
            .host_keys
            .verify_key(&db, "host", 22, b"key", "Ed25519", "direct")
            .is_err());
        assert!(db.host_keys.pending.lock().unwrap().is_empty());
        assert!(db.host_keys.resolve(&db, "invented-request", true).is_err());
    }

    #[test]
    fn trust_reuses_endpoint_across_names_and_users_but_not_ports() {
        let db = db();
        let id = request(&db, "Host", 22, b"key", "direct");
        db.host_keys.resolve(&db, &id, true).unwrap();
        assert!(db
            .host_keys
            .verify_key(&db, "HOST", 22, b"key", "Ed25519", "target")
            .is_ok());
        assert!(db
            .host_keys
            .verify_key(&db, "host", 2222, b"key", "Ed25519", "direct")
            .is_err());
        assert!(db
            .host_keys
            .verify_key(&db, "other", 22, b"key", "Ed25519", "direct")
            .is_err());
        assert!(db.host_keys.resolve(&db, &id, true).is_err());
    }

    #[test]
    fn cancellation_does_not_trust_and_can_be_retried() {
        let db = db();
        let id = request(&db, "host", 22, b"key", "direct");
        db.host_keys.resolve(&db, &id, false).unwrap();
        let retry = request(&db, "host", 22, b"key", "direct");
        assert_ne!(id, retry);
        assert!(db.host_keys.resolve(&db, &id, true).is_err());
    }

    #[test]
    fn changed_key_requires_explicit_replacement_and_keeps_old_on_cancel() {
        let db = db();
        let id = request(&db, "host", 22, b"old", "direct");
        db.host_keys.resolve(&db, &id, true).unwrap();
        let changed = request(&db, "host", 22, b"new", "direct");
        let json =
            serde_json::to_value(db.host_keys.pending.lock().unwrap().get(&changed).unwrap())
                .unwrap();
        assert_eq!(json["previous_fingerprint"], fingerprint(b"old"));
        assert_eq!(json["fingerprint"], fingerprint(b"new"));
        assert!(json.get("key").is_none());
        db.host_keys.resolve(&db, &changed, false).unwrap();
        assert!(db
            .host_keys
            .verify_key(&db, "host", 22, b"old", "Ed25519", "direct")
            .is_ok());
        let changed = request(&db, "host", 22, b"new", "direct");
        db.host_keys.resolve(&db, &changed, true).unwrap();
        assert!(db
            .host_keys
            .verify_key(&db, "host", 22, b"new", "Ed25519", "direct")
            .is_ok());
        assert!(db
            .host_keys
            .verify_key(&db, "host", 22, b"old", "Ed25519", "direct")
            .is_err());
    }

    #[test]
    fn jump_and_target_trust_are_independent() {
        let db = db();
        let jump = request(&db, "jump", 22, b"jump-key", "jump");
        db.host_keys.resolve(&db, &jump, true).unwrap();
        let target = request(&db, "target", 22, b"target-key", "target");
        assert_eq!(
            db.host_keys
                .pending
                .lock()
                .unwrap()
                .get(&target)
                .unwrap()
                .role,
            "target"
        );
        db.host_keys.resolve(&db, &target, false).unwrap();
        assert!(db
            .host_keys
            .verify_key(&db, "jump", 22, b"jump-key", "Ed25519", "jump")
            .is_ok());
        assert!(db
            .host_keys
            .verify_key(&db, "target", 22, b"target-key", "Ed25519", "target")
            .is_err());
    }

    #[test]
    fn duplicate_requests_are_coalesced_and_stale_approvals_cannot_overwrite() {
        let db = db();
        let a = request(&db, "host", 22, b"a", "direct");
        assert_eq!(a, request(&db, "host", 22, b"a", "direct"));
        let b = request(&db, "host", 22, b"b", "direct");
        db.host_keys.resolve(&db, &a, true).unwrap();
        assert!(db.host_keys.resolve(&db, &b, true).is_err());
        let b = request(&db, "host", 22, b"b", "direct");
        let c = request(&db, "host", 22, b"c", "direct");
        db.host_keys.resolve(&db, &b, true).unwrap();
        assert!(db.host_keys.resolve(&db, &c, true).is_err());
        assert!(db
            .host_keys
            .verify_key(&db, "host", 22, b"b", "Ed25519", "direct")
            .is_ok());
    }

    #[test]
    fn trust_survives_database_reopen_and_legacy_data_is_preserved() {
        let path = std::env::temp_dir().join(format!("orbit-host-key-{}.db", uuid::Uuid::new_v4()));
        {
            let db = Database::new(path.to_str().unwrap()).unwrap();
            db.host_keys.set_callback(Some(notified)).unwrap();
            let input: crate::models::ServerInput = serde_json::from_value(serde_json::json!({"name":"Existing", "host":"host", "username":"user", "password":"secret"})).unwrap();
            db.add_server(&input).unwrap();
            db.conn
                .lock()
                .unwrap()
                .execute_batch("DROP TABLE ssh_known_hosts")
                .unwrap();
        }
        {
            let db = Database::new(path.to_str().unwrap()).unwrap();
            db.host_keys.set_callback(Some(notified)).unwrap();
            let id = request(&db, "host", 22, b"key", "direct");
            db.host_keys.resolve(&db, &id, true).unwrap();
        }
        {
            let db = Database::new(path.to_str().unwrap()).unwrap();
            assert!(db
                .host_keys
                .verify_key(&db, "host", 22, b"key", "Ed25519", "direct")
                .is_ok());
            let servers = db.list_servers().unwrap();
            assert_eq!(servers.len(), 1);
            assert_eq!(servers[0].name, "Existing");
            assert_eq!(servers[0].password, "secret");
        }
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn empty_key_is_never_accepted_and_fingerprint_uses_openssh_format() {
        let db = db();
        assert!(db
            .host_keys
            .verify_key(&db, "host", 22, b"", "Unknown", "direct")
            .is_err());
        assert!(db.host_keys.pending.lock().unwrap().is_empty());
        assert_eq!(
            fingerprint(b"abc"),
            "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0"
        );
    }
}

#[cfg(all(test, target_os = "macos"))]
mod sshd_tests {
    use super::*;
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};

    struct Fixture {
        directory: std::path::PathBuf,
        children: Vec<Child>,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            for child in &mut self.children {
                let _ = child.kill();
                let _ = child.wait();
            }
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    impl Fixture {
        fn new() -> Self {
            let directory =
                std::env::temp_dir().join(format!("orbit-host-key-sshd-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&directory).unwrap();
            let fixture = Self {
                directory,
                children: Vec::new(),
            };
            fixture.key("client");
            fixture
        }

        fn key(&self, name: &str) {
            assert!(Command::new("/usr/bin/ssh-keygen")
                .args(["-q", "-t", "ed25519", "-N", "", "-f"])
                .arg(self.directory.join(name))
                .status()
                .unwrap()
                .success());
        }

        fn start(&mut self, name: &str) -> u16 {
            self.key(name);
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            drop(listener);
            let config = self.directory.join(format!("{name}.conf"));
            std::fs::write(&config, format!(
                "HostKey {}\nListenAddress 127.0.0.1\nPort {}\nPidFile {}\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nStrictModes no\nAuthorizedKeysFile {}\nAllowTcpForwarding yes\nSubsystem sftp internal-sftp\n",
                self.directory.join(name).display(), port,
                self.directory.join(format!("{name}.pid")).display(),
                self.directory.join("client.pub").display()
            )).unwrap();
            self.children.push(
                Command::new("/usr/sbin/sshd")
                    .args(["-D", "-e", "-f"])
                    .arg(config)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            );
            let started = Instant::now();
            loop {
                if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                    break;
                }
                assert!(
                    started.elapsed() < Duration::from_secs(5),
                    "test sshd failed to start"
                );
                std::thread::sleep(Duration::from_millis(20));
            }
            port
        }

        fn server(&self, db: &Database, name: &str, port: u16, jump: Option<&str>) -> Server {
            let username = String::from_utf8(
                Command::new("/usr/bin/id")
                    .arg("-un")
                    .output()
                    .unwrap()
                    .stdout,
            )
            .unwrap();
            let input = serde_json::from_value(serde_json::json!({
                "name": name, "host": "127.0.0.1", "port": port, "username": username.trim(),
                "auth_type": "key", "key_source": "file", "key_file_path": self.directory.join("client"),
                "jump_server_id": jump
            })).unwrap();
            let saved = db.add_server(&input).unwrap();
            db.get_server(&saved.id).unwrap()
        }
    }

    extern "C" fn notified(_json: *const c_char) {}

    fn pending(db: &Database, role: &str) -> HostKeyRequest {
        let pending = db.host_keys.pending.lock().unwrap();
        assert_eq!(pending.len(), 1);
        let request = pending.values().next().unwrap().clone();
        assert_eq!(request.role, role);
        request
    }

    fn blocked(db: &Database, server: &Server) {
        match crate::transport::create_session(server, db) {
            Ok(_) => panic!("untrusted host must not connect"),
            Err(error) => assert!(error.to_string().contains("主机指纹"), "{error}"),
        }
    }

    #[test]
    #[ignore = "starts isolated loopback sshd fixtures; requires local networking and /usr/sbin/sshd"]
    fn direct_and_jump_handshakes_enforce_trust_before_authentication() {
        let mut fixture = Fixture::new();
        let jump_port = fixture.start("jump");
        let target_port = fixture.start("target");
        let db = Database::new(":memory:").unwrap();
        db.host_keys.set_callback(Some(notified)).unwrap();
        let jump = fixture.server(&db, "jump", jump_port, None);
        let target = fixture.server(&db, "target", target_port, Some(&jump.id));
        let direct = fixture.server(&db, "direct", target_port, None);

        let mut invalid_auth = direct.clone();
        invalid_auth.key_file_path = "/does-not-exist".to_string();
        blocked(&db, &invalid_auth);
        let request = pending(&db, "direct");
        db.host_keys.resolve(&db, &request.id, false).unwrap();

        blocked(&db, &target);
        let request = pending(&db, "jump");
        assert_eq!(request.port, jump_port);
        db.host_keys.resolve(&db, &request.id, true).unwrap();
        blocked(&db, &target);
        let request = pending(&db, "target");
        assert_eq!(request.host, "127.0.0.1");
        assert_eq!(request.port, target_port);
        db.host_keys.resolve(&db, &request.id, false).unwrap();
        blocked(&db, &target);
        let request = pending(&db, "target");
        db.host_keys.resolve(&db, &request.id, true).unwrap();
        drop(crate::transport::create_session(&target, &db).unwrap());
        drop(crate::transport::create_session(&direct, &db).unwrap());

        for (port, role) in [(target_port, "target"), (jump_port, "jump")] {
            db.conn
                .lock()
                .unwrap()
                .execute(
                    "UPDATE ssh_known_hosts SET public_key = ?1 WHERE port = ?2",
                    (b"old-key".as_slice(), port),
                )
                .unwrap();
            blocked(&db, &target);
            let request = pending(&db, role);
            assert!(request.previous_fingerprint.is_some());
            db.host_keys.resolve(&db, &request.id, true).unwrap();
            drop(crate::transport::create_session(&target, &db).unwrap());
        }
    }
    #[test]
    #[ignore = "starts isolated loopback sshd fixtures"]
    fn sftp_safe_transfers_preserve_originals_on_conflict_and_cancellation() {
        use crate::sftp_transfer::{transfer, TransferControl, TransferFailure, TransferRequest};
        use std::sync::atomic::Ordering;
        let mut fixture = Fixture::new();
        let port = fixture.start("sftp");
        let db = Database::new(":memory:").unwrap();
        db.host_keys.set_callback(Some(notified)).unwrap();
        let server = fixture.server(&db, "sftp", port, None);
        blocked(&db, &server);
        db.host_keys.resolve(&db, &pending(&db, "direct").id, true).unwrap();
        let source = fixture.directory.join("source.bin");
        let destination = fixture.directory.join("远程 file 'name.bin");
        let download = fixture.directory.join("download.bin");
        let content = vec![0x42u8; 512 * 1024];
        std::fs::write(&source, &content).unwrap();
        std::fs::write(&destination, b"original").unwrap();
        let mut request = TransferRequest { id: String::new(), server_id: server.id.clone(), local_path: source.to_string_lossy().into_owned(), remote_path: destination.to_string_lossy().into_owned(), upload: true, overwrite: false };
        let result = transfer(&db, &server, &request, &TransferControl::default(), None);
        assert!(matches!(result.unwrap_err().downcast_ref::<TransferFailure>(), Some(TransferFailure::Conflict)));
        assert_eq!(std::fs::read(&destination).unwrap(), b"original");
        request.overwrite = true;
        let control = std::sync::Arc::new(TransferControl::default());
        let cancelled = control.clone();
        let progress: crate::sftp::ProgressCallback = Box::new(move |_, _| { cancelled.cancelled.store(true, Ordering::Release); });
        assert!(transfer(&db, &server, &request, &control, Some(&progress)).is_err());
        assert_eq!(std::fs::read(&destination).unwrap(), b"original");
        transfer(&db, &server, &request, &TransferControl::default(), None).unwrap();
        assert_eq!(std::fs::read(&destination).unwrap(), content);
        request.upload = false;
        request.local_path = download.to_string_lossy().into_owned();
        std::fs::write(&download, b"local original").unwrap();
        request.overwrite = false;
        assert!(transfer(&db, &server, &request, &TransferControl::default(), None).is_err());
        assert_eq!(std::fs::read(&download).unwrap(), b"local original");
        request.overwrite = true;
        let control = std::sync::Arc::new(TransferControl::default());
        let cancelled = control.clone();
        let progress: crate::sftp::ProgressCallback = Box::new(move |_, _| { cancelled.cancelled.store(true, Ordering::Release); });
        assert!(transfer(&db, &server, &request, &control, Some(&progress)).is_err());
        assert_eq!(std::fs::read(&download).unwrap(), b"local original");
        transfer(&db, &server, &request, &TransferControl::default(), None).unwrap();
        assert_eq!(std::fs::read(&download).unwrap(), content);
        std::fs::remove_file(&download).unwrap();
        request.overwrite = false;
        transfer(&db, &server, &request, &TransferControl::default(), None).unwrap();
        assert_eq!(std::fs::read(&download).unwrap(), content);
        request.upload = true;
        request.local_path = source.to_string_lossy().into_owned();
        std::fs::remove_file(&destination).unwrap();
        transfer(&db, &server, &request, &TransferControl::default(), None).unwrap();
        assert_eq!(std::fs::read(&destination).unwrap(), content);
        assert!(!std::fs::read_dir(&fixture.directory).unwrap().any(|entry| entry.unwrap().file_name().to_string_lossy().starts_with(".orbit-transfer-")));
    }

}
