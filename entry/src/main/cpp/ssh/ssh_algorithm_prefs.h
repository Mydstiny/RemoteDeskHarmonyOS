/**
 * ssh_algorithm_prefs.h — libssh2 SSH algorithm preferences shared by probe/auth/connect.
 */
#ifndef SSH_ALGORITHM_PREFS_H
#define SSH_ALGORITHM_PREFS_H

#include <libssh2.h>

static inline const char* sshHostKeyTypeName(int type) {
    switch (type) {
        case LIBSSH2_HOSTKEY_TYPE_RSA: return "ssh-rsa";
        case LIBSSH2_HOSTKEY_TYPE_DSS: return "ssh-dss";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521";
        case LIBSSH2_HOSTKEY_TYPE_ED25519: return "ssh-ed25519";
        default: return "unknown";
    }
}

static inline void applySshAlgorithmPreferences(LIBSSH2_SESSION* session) {
    if (!session) {
        return;
    }

    // KEX: ECDH + DH-group-exchange + DH-group16/18/14 优先, curve25519 回退.
    libssh2_session_method_pref(session, LIBSSH2_METHOD_KEX,
        "ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,"
        "diffie-hellman-group-exchange-sha256,"
        "diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,"
        "diffie-hellman-group14-sha256,diffie-hellman-group14-sha1");

    // Host key: Ed25519 + ECDSA + RSA. Probe/auth/connect must keep this identical.
    libssh2_session_method_pref(session, LIBSSH2_METHOD_HOSTKEY,
        "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,"
        "rsa-sha2-512,rsa-sha2-256,ssh-rsa");

    // Encryption: AES-GCM + AES-CTR + ChaCha20.
    libssh2_session_method_pref(session, LIBSSH2_METHOD_CRYPT_CS,
        "aes256-gcm@openssh.com,aes128-gcm@openssh.com,"
        "aes256-ctr,aes192-ctr,aes128-ctr,"
        "chacha20-poly1305@openssh.com");
    libssh2_session_method_pref(session, LIBSSH2_METHOD_CRYPT_SC,
        "aes256-gcm@openssh.com,aes128-gcm@openssh.com,"
        "aes256-ctr,aes192-ctr,aes128-ctr,"
        "chacha20-poly1305@openssh.com");

    // MAC: HMAC-SHA2 + ETM.
    libssh2_session_method_pref(session, LIBSSH2_METHOD_MAC_CS,
        "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,"
        "hmac-sha2-256,hmac-sha2-512,hmac-sha1");
    libssh2_session_method_pref(session, LIBSSH2_METHOD_MAC_SC,
        "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,"
        "hmac-sha2-256,hmac-sha2-512,hmac-sha1");

    libssh2_session_method_pref(session, LIBSSH2_METHOD_COMP_CS, "none");
    libssh2_session_method_pref(session, LIBSSH2_METHOD_COMP_SC, "none");
}

#endif // SSH_ALGORITHM_PREFS_H
