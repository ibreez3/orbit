use orbit_core::desktop::DesktopCore;
use std::{fs, path::PathBuf};

struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}

#[test]
fn database_reopens_with_file_key_and_preserves_data_on_key_damage() {
    let fixture = Fixture(std::env::temp_dir().join(format!("orbit-vault-integration-{}", uuid::Uuid::new_v4())));
    fs::create_dir(&fixture.0).unwrap();
    let path = fixture.0.join("orbit.db");
    let key_path = fixture.0.join("orbit.key");
    let core = DesktopCore::new(path.to_str().unwrap()).unwrap();
    core.save_private_setting("test", "private-test-value").unwrap();
    drop(core);
    let key = fs::read(&key_path).unwrap();
    assert_eq!(key.len(), 32);
    let encrypted: String = rusqlite::Connection::open(&path).unwrap().query_row("SELECT value FROM desktop_private_settings WHERE name='test'", [], |row| row.get(0)).unwrap();
    assert!(encrypted.starts_with("ORB2:"));
    assert!(!encrypted.contains("private-test-value"));
    let reopened = DesktopCore::new(path.to_str().unwrap()).unwrap();
    assert_eq!(reopened.private_setting("test").unwrap().as_deref(), Some("private-test-value"));
    drop(reopened);
    fs::write(&key_path, [0; 1]).unwrap();
    assert!(DesktopCore::new(path.to_str().unwrap()).is_err());
    assert_eq!(fs::read(&key_path).unwrap(), [0]);
    let after: String = rusqlite::Connection::open(&path).unwrap().query_row("SELECT value FROM desktop_private_settings WHERE name='test'", [], |row| row.get(0)).unwrap();
    assert_eq!(after, encrypted);
    fs::write(&key_path, key).unwrap();
    assert_eq!(DesktopCore::new(path.to_str().unwrap()).unwrap().private_setting("test").unwrap().as_deref(), Some("private-test-value"));
}
