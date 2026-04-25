use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, AeadCore, Nonce};
use base64::{Engine, engine::general_purpose::STANDARD};
use sha2::{Sha256, Digest};

const SALT: &[u8] = b"orbit-credential-encryption-salt-v1";

fn derive_key() -> [u8; 32] {
    let hostname = gethostname::gethostname().to_string_lossy().to_string();
    let mut hasher = Sha256::new();
    hasher.update(SALT);
    hasher.update(hostname.as_bytes());
    hasher.update(SALT);
    let result = hasher.finalize();
    let mut key = [0u8; 32];
    key.copy_from_slice(&result);
    key
}

pub fn encrypt(plaintext: &str) -> String {
    if plaintext.is_empty() {
        return String::new();
    }
    let key = derive_key();
    let cipher = Aes256Gcm::new_from_slice(&key).expect("AES key init failed");
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    match cipher.encrypt(&nonce, plaintext.as_bytes()) {
        Ok(ciphertext) => {
            let mut combined = nonce.to_vec();
            combined.extend_from_slice(&ciphertext);
            STANDARD.encode(&combined)
        }
        Err(_) => plaintext.to_string(),
    }
}

pub fn decrypt(ciphertext: &str) -> String {
    if ciphertext.is_empty() {
        return String::new();
    }
    let bytes = match STANDARD.decode(ciphertext) {
        Ok(b) => b,
        Err(_) => return ciphertext.to_string(),
    };
    if bytes.len() < 13 {
        return ciphertext.to_string();
    }
    let (nonce_bytes, encrypted) = bytes.split_at(12);
    let key = derive_key();
    let cipher = Aes256Gcm::new_from_slice(&key).expect("AES key init failed");
    let nonce = Nonce::from_slice(nonce_bytes);
    match cipher.decrypt(nonce, encrypted) {
        Ok(plaintext) => String::from_utf8_lossy(&plaintext).to_string(),
        Err(_) => ciphertext.to_string(),
    }
}

pub fn is_encrypted(value: &str) -> bool {
    if value.is_empty() {
        return false;
    }
    STANDARD.decode(value).map_or(false, |bytes| bytes.len() >= 13)
}
