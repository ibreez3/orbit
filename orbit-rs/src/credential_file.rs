use crate::crypto::{load_key, KeyStore};
use anyhow::{bail, Context, Result};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

pub(crate) struct FileKeyStore(pub PathBuf);

impl KeyStore for FileKeyStore {
    fn read(&self) -> Result<Option<Vec<u8>>> {
        match fs::symlink_metadata(&self.0) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
            Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => bail!("密钥路径必须是普通文件"),
            Ok(_) => {}
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
            let file = fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(&self.0)?;
            if file.metadata()?.uid() != unsafe { libc::geteuid() } { bail!("密钥文件不属于当前用户"); }
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
            let mut key = Vec::new();
            file.take(33).read_to_end(&mut key)?;
            Ok(Some(key))
        }
        #[cfg(windows)]
        {
            secure_windows(&self.0, false)?;
            let mut key = Vec::new();
            File::open(&self.0)?.take(33).read_to_end(&mut key)?;
            Ok(Some(key))
        }
    }

    fn create(&self, key: &[u8]) -> Result<bool> {
        if key.len() != 32 { bail!("凭据密钥长度无效"); }
        let temporary = self.0.with_extension(format!("key-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> Result<bool> {
            #[cfg(unix)]
            let mut file = {
                use std::os::unix::fs::OpenOptionsExt;
                fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?
            };
            #[cfg(windows)]
            let mut file = secure_windows(&temporary, true)?.context("无法创建密钥文件")?;
            file.write_all(key)?;
            file.sync_all()?;
            drop(file);
            match fs::hard_link(&temporary, &self.0) {
                Ok(()) => {
                    #[cfg(unix)]
                    File::open(self.0.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new(".")))?.sync_all()?;
                    Ok(true)
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
                Err(error) => Err(error.into()),
            }
        })();
        let _ = fs::remove_file(&temporary);
        result
    }
}

pub(crate) fn load_or_migrate(path: &Path, required: bool, legacy: impl FnOnce() -> Result<Option<Vec<u8>>>) -> Result<[u8; 32]> {
    let store = FileKeyStore(path.to_path_buf());
    if store.read()?.is_some() { return load_key(&store, true); }
    if required {
        let key = legacy()?.context("本地密钥文件及旧系统密钥均不可用；请恢复原密钥，数据库凭据未更改")?;
        if key.len() != 32 { bail!("旧系统密钥损坏，未创建替代密钥"); }
        store.create(&key)?;
        let saved = load_key(&store, true)?;
        if saved.as_slice() != key { bail!("密钥迁移冲突，数据库凭据未更改"); }
        Ok(saved)
    } else {
        load_key(&store, false)
    }
}

#[cfg(windows)]
fn secure_windows(path: &Path, create: bool) -> Result<Option<File>> {
    use std::os::windows::{ffi::OsStrExt, io::FromRawHandle};
    use windows_sys::Win32::Foundation::{LocalFree, GENERIC_WRITE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::{Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW, SetFileSecurityW, DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, SECURITY_ATTRIBUTES};
    use windows_sys::Win32::Storage::FileSystem::{CreateFileW, CREATE_NEW, FILE_ATTRIBUTE_NORMAL};
    let sddl: Vec<u16> = "D:P(A;;FA;;;OW)(A;;FA;;;SY)\0".encode_utf16().collect();
    let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut descriptor = std::ptr::null_mut();
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), 1, &mut descriptor, std::ptr::null_mut()) } == 0 { return Err(std::io::Error::last_os_error().into()); }
    let result = if create {
        let attributes = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: descriptor, bInheritHandle: 0 };
        let handle = unsafe { CreateFileW(name.as_ptr(), GENERIC_WRITE, 0, &attributes, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, std::ptr::null_mut()) };
        if handle == INVALID_HANDLE_VALUE { Err(std::io::Error::last_os_error().into()) } else { Ok(Some(unsafe { File::from_raw_handle(handle) })) }
    } else if unsafe { SetFileSecurityW(name.as_ptr(), DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, descriptor) } == 0 {
        Err(std::io::Error::last_os_error().into())
    } else { Ok(None) };
    unsafe { LocalFree(descriptor); }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Directory(PathBuf);
    impl Directory {
        fn new() -> Self { let path = std::env::temp_dir().join(format!("orbit-key-test-{}", uuid::Uuid::new_v4())); fs::create_dir(&path).unwrap(); Self(path) }
        fn key(&self) -> PathBuf { self.0.join("orbit.key") }
    }
    impl Drop for Directory { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    #[test]
    fn fresh_install_and_reopen_do_not_access_system_store() {
        let dir = Directory::new();
        let key = load_or_migrate(&dir.key(), false, || panic!("must not read system store")).unwrap();
        assert_eq!(key, load_or_migrate(&dir.key(), true, || panic!("must not read system store")).unwrap());
        assert_eq!(fs::metadata(dir.key()).unwrap().len(), 32);
        #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; assert_eq!(fs::metadata(dir.key()).unwrap().permissions().mode() & 0o777, 0o600); }
    }
    #[test]
    fn old_key_is_migrated_without_reencrypting_credentials() {
        let dir = Directory::new(); let old = [13; 32];
        let encrypted = crate::crypto::CredentialCipher::new(old).encrypt("迁移密码").unwrap();
        let key = load_or_migrate(&dir.key(), true, || Ok(Some(old.to_vec()))).unwrap();
        assert_eq!(crate::crypto::CredentialCipher::new(key).decrypt(&encrypted).unwrap(), "迁移密码");
        assert_eq!(load_or_migrate(&dir.key(), true, || bail!("locked")).unwrap(), old);
    }
    #[test]
    fn missing_corrupt_and_unavailable_keys_never_get_replaced() {
        let dir = Directory::new();
        assert!(load_or_migrate(&dir.key(), true, || Ok(None)).is_err());
        assert!(load_or_migrate(&dir.key(), true, || bail!("locked")).is_err());
        assert!(load_or_migrate(&dir.key(), true, || Ok(Some(vec![1]))).is_err());
        assert!(!dir.key().exists());
        fs::write(dir.key(), [1]).unwrap();
        assert!(load_or_migrate(&dir.key(), true, || panic!("must not fall back")).is_err());
        assert_eq!(fs::read(dir.key()).unwrap(), vec![1]);
    }
    #[test]
    fn competing_creators_share_one_complete_key() {
        let dir = Directory::new(); let path = dir.key();
        let threads: Vec<_> = (0..8).map(|_| { let path = path.clone(); std::thread::spawn(move || load_or_migrate(&path, false, || panic!("unexpected migration")).unwrap()) }).collect();
        let keys: Vec<_> = threads.into_iter().map(|thread| thread.join().unwrap()).collect();
        assert!(keys.iter().all(|key| key == &keys[0]));
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_are_rejected() {
        let dir = Directory::new(); let target = dir.0.join("target"); fs::write(&target, [4;32]).unwrap();
        std::os::unix::fs::symlink(&target, dir.key()).unwrap();
        assert!(load_or_migrate(&dir.key(), false, || Ok(None)).is_err());
        assert_eq!(fs::read(target).unwrap(), [4;32]);
    }
}
