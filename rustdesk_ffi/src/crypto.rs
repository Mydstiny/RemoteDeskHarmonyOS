// RustDesk FFI 使用的纯 Rust NaCl 兼容加密工具。

use rand::rngs::OsRng;
use rand::RngCore;
use salsa20::cipher::consts::U10;
use salsa20::cipher::generic_array::GenericArray;
use x25519_dalek::{PublicKey, StaticSecret};
use xsalsa20poly1305::{
    aead::{Aead, KeyInit},
    Nonce as XNonce, XSalsa20Poly1305,
};

pub const RUSTDESK_SERVER_PUBLIC_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";

pub struct KeyPair {
    pub public_key: [u8; 32],
    pub secret_key: [u8; 32],
}

pub fn generate_keypair() -> KeyPair {
    let secret = StaticSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&secret);
    KeyPair {
        secret_key: *secret.as_bytes(),
        public_key: *public.as_bytes(),
    }
}

pub fn keypair_from_secret(secret_key: &[u8; 32]) -> KeyPair {
    let secret = StaticSecret::from(*secret_key);
    let public = PublicKey::from(&secret);
    KeyPair {
        secret_key: *secret_key,
        public_key: *public.as_bytes(),
    }
}

pub fn random_nonce() -> [u8; 24] {
    use std::time::{SystemTime, UNIX_EPOCH};

    let mut nonce = [0u8; 24];
    let mut rng = OsRng;
    rng.fill_bytes(&mut nonce);

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let ns = now.as_nanos();
    for i in 0..24 {
        nonce[i] ^= ((ns >> (i * 3)) & 0xFF) as u8;
    }

    nonce
}

pub fn encrypt(
    plaintext: &[u8],
    nonce: &[u8; 24],
    peer_pk: &[u8; 32],
    my_sk: &[u8; 32],
) -> Option<Vec<u8>> {
    let box_key = crypto_box_precompute(peer_pk, my_sk);
    secretbox_encrypt(plaintext, nonce, &box_key)
}

pub fn decrypt(
    ciphertext: &[u8],
    nonce: &[u8; 24],
    peer_pk: &[u8; 32],
    my_sk: &[u8; 32],
) -> Option<Vec<u8>> {
    let box_key = crypto_box_precompute(peer_pk, my_sk);
    secretbox_decrypt(ciphertext, nonce, &box_key)
}

fn crypto_box_precompute(peer_pk: &[u8; 32], my_sk: &[u8; 32]) -> [u8; 32] {
    let peer_public = PublicKey::from(*peer_pk);
    let my_secret = StaticSecret::from(*my_sk);
    let shared_secret = my_secret.diffie_hellman(&peer_public);

    let zeros = [0u8; 16];
    let subkey = salsa20::hsalsa::<U10>(
        GenericArray::from_slice(shared_secret.as_bytes()),
        GenericArray::from_slice(&zeros),
    );

    let mut key = [0u8; 32];
    key.copy_from_slice(&subkey);
    key
}

pub fn secretbox_encrypt(plaintext: &[u8], nonce: &[u8; 24], key: &[u8; 32]) -> Option<Vec<u8>> {
    let cipher = XSalsa20Poly1305::new_from_slice(key).ok()?;
    let xnonce = XNonce::from_slice(nonce);
    cipher.encrypt(xnonce, plaintext).ok()
}

pub fn secretbox_decrypt(ciphertext: &[u8], nonce: &[u8; 24], key: &[u8; 32]) -> Option<Vec<u8>> {
    let cipher = XSalsa20Poly1305::new_from_slice(key).ok()?;
    let xnonce = XNonce::from_slice(nonce);
    cipher.decrypt(xnonce, ciphertext).ok()
}

pub fn decode_base64_key(encoded: &str) -> Option<[u8; 32]> {
    use base64::Engine;

    let decoded = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .ok()?;
    if decoded.len() != 32 {
        return None;
    }

    let mut key = [0u8; 32];
    key.copy_from_slice(&decoded);
    Some(key)
}

/// Normalize and validate a configured RustDesk rendezvous public key.
///
/// An empty value is intentional: it selects the built-in public-server key
/// for peer-signature verification and sends an empty licence_key to hbbs.
/// Any non-empty value must be the standard Base64 encoding of one Ed25519
/// public key (32 bytes).  Keeping this check at the FFI boundary prevents an
/// encrypted DataCrypto value or an arbitrary Pro token from being sent as a
/// protocol licence_key.
pub fn normalized_server_public_key(encoded: &str) -> Option<&str> {
    let trimmed = encoded.trim();
    if trimmed.is_empty() || decode_base64_key(trimmed).is_some() {
        Some(trimmed)
    } else {
        None
    }
}

pub fn verify_signed_message(signed: &[u8], public_key: &[u8; 32]) -> Option<Vec<u8>> {
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};

    if signed.len() < 64 {
        return None;
    }

    let verifying_key = VerifyingKey::from_bytes(public_key).ok()?;
    let signature = Signature::from_slice(&signed[..64]).ok()?;
    let message = &signed[64..];
    verifying_key.verify(message, &signature).ok()?;
    Some(message.to_vec())
}

pub fn create_symmetric_key_msg(their_pk: &[u8; 32]) -> Option<([u8; 32], Vec<u8>, [u8; 32])> {
    let our = generate_keypair();
    let mut key = [0u8; 32];
    OsRng.fill_bytes(&mut key);

    let nonce = [0u8; 24];
    let encrypted_key = encrypt(&key, &nonce, their_pk, &our.secret_key)?;
    Some((our.public_key, encrypted_key, key))
}

pub fn secretbox_nonce(seqnum: u64) -> [u8; 24] {
    let mut nonce = [0u8; 24];
    nonce[..8].copy_from_slice(&seqnum.to_le_bytes());
    nonce
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keypair_generation() {
        let kp = generate_keypair();
        assert_ne!(kp.public_key, [0u8; 32]);
        assert_ne!(kp.secret_key, [0u8; 32]);
    }

    #[test]
    fn test_crypto_box_roundtrip() {
        let alice = generate_keypair();
        let bob = generate_keypair();

        let plaintext = b"Hello, RustDesk encrypted channel!";
        let nonce = random_nonce();

        let ct =
            encrypt(plaintext, &nonce, &bob.public_key, &alice.secret_key).expect("encryption");
        assert_ne!(&ct[..], plaintext);

        let pt = decrypt(&ct, &nonce, &alice.public_key, &bob.secret_key).expect("decryption");
        assert_eq!(&pt[..], plaintext);
    }

    #[test]
    fn test_crypto_box_wrong_key_fails() {
        let alice = generate_keypair();
        let bob = generate_keypair();
        let eve = generate_keypair();

        let plaintext = b"secret message";
        let nonce = random_nonce();

        let ct =
            encrypt(plaintext, &nonce, &bob.public_key, &alice.secret_key).expect("encryption");

        let result = decrypt(&ct, &nonce, &alice.public_key, &eve.secret_key);
        assert!(result.is_none(), "Eve should not be able to decrypt");
    }

    #[test]
    fn test_secretbox_roundtrip() {
        let key = generate_keypair().secret_key;
        let plaintext = b"Symmetric encryption test";
        let nonce = random_nonce();

        let ct = secretbox_encrypt(plaintext, &nonce, &key).expect("secretbox encrypt");
        let pt = secretbox_decrypt(&ct, &nonce, &key).expect("secretbox decrypt");

        assert_eq!(&pt[..], plaintext);
    }

    #[test]
    fn test_nonce_uniqueness() {
        let n1 = random_nonce();
        std::thread::sleep(std::time::Duration::from_millis(1));
        let n2 = random_nonce();
        assert_ne!(n1, n2, "two nonces should differ");
    }

    #[test]
    fn test_keypair_from_secret() {
        let kp1 = generate_keypair();
        let kp2 = keypair_from_secret(&kp1.secret_key);
        assert_eq!(kp1.public_key, kp2.public_key);
        assert_eq!(kp1.secret_key, kp2.secret_key);
    }

    #[test]
    fn server_public_key_validation_accepts_empty_and_standard_key() {
        assert_eq!(normalized_server_public_key(""), Some(""));
        assert_eq!(
            normalized_server_public_key("  OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=  "),
            Some("OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=")
        );
    }

    #[test]
    fn server_public_key_validation_rejects_ciphertext_and_wrong_length() {
        assert!(normalized_server_public_key("1:encrypted-value").is_none());
        assert!(normalized_server_public_key("not-a-server-key").is_none());
    }
}
