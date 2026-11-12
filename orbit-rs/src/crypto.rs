use aes_gcm::aead::{rand_core::RngCore, Aead, KeyInit, OsRng};
use aes_gcm::{AeadCore, Aes256Gcm, Nonce};
use anyhow::{anyhow, bail, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use sha2::{Digest, Sha256};

pub struct CredentialCipher {
    key: [u8; 32],
}

impl Drop for CredentialCipher {
    fn drop(&mut self) {
        for byte in &mut self.key {
            unsafe { std::ptr::write_volatile(byte, 0) };
        }
    }
}

impl CredentialCipher {
    pub fn new(key: [u8; 32]) -> Self {
        Self { key }
    }

    pub fn encrypt(&self, plaintext: &str) -> Result<String> {
        if plaintext.is_empty() {
            return Ok(String::new());
        }
        let cipher = Aes256Gcm::new_from_slice(&self.key).map_err(|_| anyhow!("凭据密钥无效"))?;
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let encrypted = cipher
            .encrypt(&nonce, plaintext.as_bytes())
            .map_err(|_| anyhow!("凭据加密失败，未保存任何明文"))?;
        let mut bytes = nonce.to_vec();
        bytes.extend(encrypted);
        Ok(format!("ORB2:{}", STANDARD.encode(bytes)))
    }

    fn open(key: &[u8; 32], bytes: &[u8]) -> Result<String> {
        if bytes.len() < 28 {
            bail!("凭据密文损坏；原始数据已保留");
        }
        let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| anyhow!("凭据密钥无效"))?;
        let plaintext = cipher
            .decrypt(Nonce::from_slice(&bytes[..12]), &bytes[12..])
            .map_err(|_| anyhow!("凭据无法解密：密钥不匹配或密文损坏；原始数据已保留"))?;
        String::from_utf8(plaintext).map_err(|_| anyhow!("凭据编码损坏；原始数据已保留"))
    }

    pub fn decrypt(&self, value: &str) -> rusqlite::Result<String> {
        self.decrypt_current(value).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                0,
                rusqlite::types::Type::Text,
                Box::new(std::io::Error::other(error.to_string())),
            )
        })
    }

    fn decrypt_current(&self, value: &str) -> Result<String> {
        if value.is_empty() {
            return Ok(String::new());
        }
        let encoded = value
            .strip_prefix("ORB2:")
            .ok_or_else(|| anyhow!("凭据尚未完成安全迁移"))?;
        let bytes = STANDARD
            .decode(encoded)
            .map_err(|_| anyhow!("凭据密文损坏；原始数据已保留"))?;
        Self::open(&self.key, &bytes)
    }

    pub fn migrate(&self, value: &str) -> Result<String> {
        if value.is_empty() {
            return Ok(String::new());
        }
        if value.starts_with("ORB2:") {
            self.decrypt_current(value)?;
            return Ok(value.to_string());
        }
        let plaintext = match STANDARD.decode(value) {
            Ok(bytes) if bytes.starts_with(b"ORB1") => Self::open(&legacy_key(), &bytes[4..])?,
            _ if value.starts_with("T1JC") || value.starts_with("ORB") => {
                bail!("凭据格式损坏，迁移已回滚；请恢复原始数据库备份")
            }
            _ => value.to_string(),
        };
        let encrypted = self.encrypt(&plaintext)?;
        if self.decrypt_current(&encrypted)? != plaintext {
            bail!("凭据迁移校验失败");
        }
        Ok(encrypted)
    }
}

fn legacy_key() -> [u8; 32] {
    let salt = b"orbit-credential-encryption-salt-v1";
    let mut hasher = Sha256::new();
    hasher.update(salt);
    hasher.update(gethostname::gethostname().to_string_lossy().as_bytes());
    hasher.update(salt);
    hasher.finalize().into()
}

pub trait KeyStore {
    fn read(&self) -> Result<Option<Vec<u8>>>;
    fn create(&self, key: &[u8]) -> Result<bool>;
}

pub fn load_key(store: &impl KeyStore, required: bool) -> Result<[u8; 32]> {
    if let Some(key) = store.read()? {
        return key
            .try_into()
            .map_err(|_| anyhow!("Keychain 中的凭据密钥损坏，未覆盖密钥"));
    }
    if required {
        bail!(
            "Keychain 凭据密钥丢失。请恢复原 Keychain 密钥后重试；数据库未更改，不会生成替代密钥"
        );
    }
    let mut key = [0u8; 32];
    OsRng
        .try_fill_bytes(&mut key)
        .map_err(|_| anyhow!("无法生成安全随机密钥"))?;
    store.create(&key)?;
    let persisted = store
        .read()?
        .ok_or_else(|| anyhow!("无法验证 Keychain 密钥保存结果，迁移未开始"))?;
    persisted
        .try_into()
        .map_err(|_| anyhow!("Keychain 中的凭据密钥损坏"))
}

#[cfg(target_os = "macos")]
pub struct MacKeychain {
    pub account: String,
}

#[cfg(target_os = "macos")]
impl KeyStore for MacKeychain {
    fn read(&self) -> Result<Option<Vec<u8>>> {
        let service = b"com.orbit.terminal.credentials.v2";
        let mut length = 0u32;
        let mut data = std::ptr::null_mut();
        let status = unsafe {
            SecKeychainFindGenericPassword(
                std::ptr::null(),
                service.len() as u32,
                service.as_ptr(),
                self.account.len() as u32,
                self.account.as_ptr(),
                &mut length,
                &mut data,
                std::ptr::null_mut(),
            )
        };
        if status == -25300 {
            return Ok(None);
        }
        if status != 0 {
            bail!("无法访问 macOS Keychain（{}）。请解锁登录钥匙串并允许 Orbit 访问，然后重试；数据库未更改", status);
        }
        let bytes = if data.is_null() {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(data as *const u8, length as usize).to_vec() }
        };
        unsafe {
            SecKeychainItemFreeContent(std::ptr::null_mut(), data);
        }
        Ok(Some(bytes))
    }

    fn create(&self, key: &[u8]) -> Result<bool> {
        let service = b"com.orbit.terminal.credentials.v2";
        let status = unsafe {
            SecKeychainAddGenericPassword(
                std::ptr::null(),
                service.len() as u32,
                service.as_ptr(),
                self.account.len() as u32,
                self.account.as_ptr(),
                key.len() as u32,
                key.as_ptr() as *const _,
                std::ptr::null_mut(),
            )
        };
        match status {
            0 => Ok(true),
            -25299 => Ok(false),
            _ => bail!(
                "无法保存 macOS Keychain 凭据密钥（{}）；数据库未更改",
                status
            ),
        }
    }
}

#[cfg(target_os = "macos")]
#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecKeychainFindGenericPassword(
        keychain: *const std::ffi::c_void,
        service_len: u32,
        service: *const u8,
        account_len: u32,
        account: *const u8,
        length: *mut u32,
        data: *mut *mut std::ffi::c_void,
        item: *mut *mut std::ffi::c_void,
    ) -> i32;
    fn SecKeychainAddGenericPassword(
        keychain: *const std::ffi::c_void,
        service_len: u32,
        service: *const u8,
        account_len: u32,
        account: *const u8,
        length: u32,
        data: *const std::ffi::c_void,
        item: *mut *mut std::ffi::c_void,
    ) -> i32;
    fn SecKeychainItemFreeContent(
        attributes: *mut std::ffi::c_void,
        data: *mut std::ffi::c_void,
    ) -> i32;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct Store {
        value: RefCell<Option<Vec<u8>>>,
        fail: bool,
    }
    impl KeyStore for Store {
        fn read(&self) -> Result<Option<Vec<u8>>> {
            if self.fail {
                bail!("Keychain locked");
            }
            Ok(self.value.borrow().clone())
        }
        fn create(&self, key: &[u8]) -> Result<bool> {
            if self.fail {
                bail!("Keychain locked");
            }
            if self.value.borrow().is_some() {
                return Ok(false);
            }
            *self.value.borrow_mut() = Some(key.to_vec());
            Ok(true)
        }
    }

    pub fn legacy(value: &str) -> String {
        let cipher = Aes256Gcm::new_from_slice(&legacy_key()).unwrap();
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let mut bytes = b"ORB1".to_vec();
        bytes.extend(nonce.as_slice());
        bytes.extend(cipher.encrypt(&nonce, value.as_bytes()).unwrap());
        STANDARD.encode(bytes)
    }

    #[test]
    fn roundtrip_migration_is_idempotent_and_randomized() {
        let cipher = CredentialCipher::new([42; 32]);
        for value in ["", "密码🔑", "-----BEGIN PRIVATE KEY-----\nabc"] {
            let encrypted = cipher.encrypt(value).unwrap();
            assert_eq!(cipher.decrypt(&encrypted).unwrap(), value);
            assert_eq!(cipher.migrate(&encrypted).unwrap(), encrypted);
            assert_eq!(
                cipher
                    .decrypt(&cipher.migrate(&legacy(value)).unwrap())
                    .unwrap(),
                value
            );
            assert_eq!(
                cipher.decrypt(&cipher.migrate(value).unwrap()).unwrap(),
                value
            );
        }
        assert_ne!(
            cipher.encrypt("secret").unwrap(),
            cipher.encrypt("secret").unwrap()
        );
    }

    #[test]
    fn corruption_wrong_key_and_plaintext_never_fall_back() {
        let cipher = CredentialCipher::new([42; 32]);
        let encrypted = cipher.encrypt("secret").unwrap();
        assert!(CredentialCipher::new([43; 32]).decrypt(&encrypted).is_err());
        for value in ["ORB2:bad", "ORB2:", "T1JCbroken", "ORB3:secret"] {
            assert!(cipher.migrate(value).is_err());
        }
        assert!(cipher.decrypt("plaintext").is_err());
        let mut bytes = STANDARD.decode(legacy("secret")).unwrap();
        *bytes.last_mut().unwrap() ^= 1;
        assert!(cipher.migrate(&STANDARD.encode(bytes)).is_err());
    }

    #[test]
    fn missing_locked_and_malformed_keychain_do_not_replace_keys() {
        let store = Store {
            value: RefCell::new(None),
            fail: false,
        };
        assert!(load_key(&store, true).is_err());
        assert!(store.value.borrow().is_none());
        let key = load_key(&store, false).unwrap();
        assert_eq!(load_key(&store, true).unwrap(), key);
        assert!(load_key(
            &Store {
                value: RefCell::new(None),
                fail: true
            },
            false
        )
        .is_err());
        let malformed = Store {
            value: RefCell::new(Some(vec![1])),
            fail: false,
        };
        assert!(load_key(&malformed, false).is_err());
        assert_eq!(*malformed.value.borrow(), Some(vec![1]));
    }

    #[test]
    fn migration_rolls_back_all_tables_and_can_be_retried() {
        let db = crate::db::Database::new(":memory:").unwrap();
        let input = serde_json::from_value(
            serde_json::json!({"name":"test", "host":"host", "username":"u"}),
        )
        .unwrap();
        let server = db.add_server(&input).unwrap();
        let old = legacy("old-password");
        db.conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE servers SET password=?1, private_key='ORB2:broken' WHERE id=?2",
                (&old, &server.id),
            )
            .unwrap();
        db.conn.lock().unwrap().execute_batch("INSERT INTO credential_groups (id,name,username,password,created_at,updated_at) VALUES ('group','group','u','group-secret','',''); INSERT INTO database_connections (id,name,engine,password,created_at,updated_at) VALUES ('database','database','postgres','database-secret','','');").unwrap();
        assert!(db.migrate_encrypt().is_err());
        let password: String = db
            .conn
            .lock()
            .unwrap()
            .query_row("SELECT password FROM servers", [], |row| row.get(0))
            .unwrap();
        assert_eq!(password, old);
        db.conn
            .lock()
            .unwrap()
            .execute("UPDATE servers SET private_key=''", [])
            .unwrap();
        db.conn.lock().unwrap().execute_batch("CREATE TRIGGER fail_migration BEFORE UPDATE ON database_connections BEGIN SELECT RAISE(FAIL, 'injected write failure'); END;").unwrap();
        assert!(db.migrate_encrypt().is_err());
        {
            let conn = db.conn.lock().unwrap();
            let server_password: String = conn.query_row("SELECT password FROM servers", [], |row| row.get(0)).unwrap();
            let group_password: String = conn.query_row("SELECT password FROM credential_groups", [], |row| row.get(0)).unwrap();
            assert_eq!(server_password, old);
            assert_eq!(group_password, "group-secret");
            conn.execute_batch("DROP TRIGGER fail_migration").unwrap();
        }
        db.migrate_encrypt().unwrap();
        assert_eq!(db.get_server(&server.id).unwrap().password, "old-password");
        for (table, expected) in [("credential_groups", "group-secret"), ("database_connections", "database-secret")] {
            let encrypted: String = db.conn.lock().unwrap().query_row(&format!("SELECT password FROM {table}"), [], |row| row.get(0)).unwrap();
            assert!(encrypted.starts_with("ORB2:"));
            assert_eq!(db.cipher.decrypt(&encrypted).unwrap(), expected);
        }

        db.migrate_encrypt().unwrap();
        assert_eq!(db.get_server(&server.id).unwrap().password, "old-password");
    }
}

#[cfg(all(test, target_os = "macos"))]
mod keychain_tests {
    use super::*;
    #[link(name = "Security", kind = "framework")]
    extern "C" { fn SecKeychainItemDelete(item: *const std::ffi::c_void) -> i32; }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" { fn CFRelease(item: *const std::ffi::c_void); }
    struct TestKey(MacKeychain);
    impl Drop for TestKey {
        fn drop(&mut self) {
            let service = b"com.orbit.terminal.credentials.v2";
            let mut item = std::ptr::null_mut();
            let status = unsafe { SecKeychainFindGenericPassword(std::ptr::null(), service.len() as u32, service.as_ptr(), self.0.account.len() as u32, self.0.account.as_ptr(), std::ptr::null_mut(), std::ptr::null_mut(), &mut item) };
            if status == 0 && !item.is_null() {
                unsafe { SecKeychainItemDelete(item); CFRelease(item); }
            }
        }
    }
    #[test]
    #[ignore = "creates and deletes one uniquely named test key in the login Keychain"]
    fn native_keychain_roundtrip_never_overwrites_existing_key() {
        let store = TestKey(MacKeychain { account: format!("orbit-test-{}", uuid::Uuid::new_v4()) });
        assert!(store.0.read().unwrap().is_none());
        let key = load_key(&store.0, false).unwrap();
        assert_eq!(load_key(&store.0, true).unwrap(), key);
        assert!(!store.0.create(&[99; 32]).unwrap());
        assert_eq!(load_key(&store.0, true).unwrap(), key);
    }
}
