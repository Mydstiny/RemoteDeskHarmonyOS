/**
 * ssh_key_tool.h — SSH 标准密钥生成/解析/指纹工具 (基于 OpenSSL 3.4.1 EVP_PKEY)
 *
 * 提供:
 *   - 生成标准 Ed25519 / RSA 4096 OpenSSH 密钥对
 *   - 解析/检测现有 OpenSSH 私钥 (fingerprint, passphrase, 类型)
 *   - 修改/移除私钥 passphrase
 *   - authorized_keys 公钥行安全校验
 *
 * 全部使用项目已静态链接的 OpenSSL 3.4.1, 零新增依赖.
 */
#ifndef SSH_KEY_TOOL_H
#define SSH_KEY_TOOL_H

#include <string>
#include <cstdint>
#include <libssh2.h>

// ============================================================
// 返回结构体
// ============================================================

struct GeneratedSshKeyPair {
    std::string privateKeyPem;       // OpenSSH 私钥 PEM (PKCS8 或 OpenSSH 原生格式)
    std::string publicKeyOpenSsh;    // "ssh-ed25519 AAAA... comment" — 可直接追加到 authorized_keys
    std::string fingerprintSha256;   // "SHA256:Base64String"
    std::string keyType;             // "ssh-ed25519" | "ssh-rsa"
    int         keyBits;             // 256 (ed25519) | 4096 (rsa)
    bool        ok;
    std::string error;
};

struct SshPrivateKeyInfo {
    bool        ok;
    std::string keyType;             // "ssh-ed25519" | "ssh-rsa" | "unknown"
    std::string publicKeyOpenSsh;    // 推导出的 authorized_keys 格式公钥行
    std::string fingerprintSha256;   // "SHA256:Base64String"
    bool        encrypted;           // 是否有 passphrase 加密
    std::string error;
};

struct SshPublicKeyInstallResult {
    bool ok;
    bool alreadyInstalled;
    bool verified;
    int  code;
    std::string message;
};

struct SshAuthTestResult {
    bool ok;
    int  code;
    std::string message;
};

struct SshHostKeyInfo {
    bool        ok;
    std::string host;
    int         port;
    std::string algorithm;          // "ssh-ed25519" / "ecdsa-sha2-nistp256" / "ssh-rsa" / "ssh-dss"
    std::string fingerprintSha256;  // "SHA256:Base64String"
    std::string rawBase64;          // raw host key blob base64 — 用于精确比对, 防 SHA256 碰撞
    std::string serverBanner;
    int         errorCode;
    std::string errorMessage;
};

// ============================================================
// API 函数
// ============================================================

/**
 * 生成标准 SSH 密钥对 (Ed25519 或 RSA 4096)
 *
 * @param keyType    "ed25519" 或 "rsa"
 * @param bits       256 (ed25519) 或 4096 (rsa)
 * @param comment    公钥注释 (如 "user@host")
 * @param passphrase 私钥加密密码 ("" = 无密码)
 * @return GeneratedSshKeyPair
 */
GeneratedSshKeyPair generateSshKeyPair(
    const std::string& keyType,
    int bits,
    const std::string& comment,
    const std::string& passphrase
);

/**
 * 解析/检测 OpenSSH 私钥, 提取公钥和 fingerprint
 *
 * @param privateKeyPem  PEM 格式私钥
 * @param passphrase     解密密码 ("" = 尝试无密码解密; 如果加密则返回 encrypted=true)
 * @return SshPrivateKeyInfo
 */
SshPrivateKeyInfo inspectSshPrivateKey(
    const std::string& privateKeyPem,
    const std::string& passphrase
);

/**
 * 修改或移除私钥 passphrase
 *
 * @param privateKeyPem  当前 PEM 格式私钥
 * @param oldPassphrase  当前密码 ("" = 无密码)
 * @param newPassphrase  新密码 ("" = 移除密码)
 * @return 新的 PEM 字符串; 失败返回空字符串
 */
std::string changeSshPrivateKeyPassphrase(
    const std::string& privateKeyPem,
    const std::string& oldPassphrase,
    const std::string& newPassphrase
);

/**
 * 校验 authorized_keys 公钥行安全性
 */
bool validatePublicKeyForAuthorizedKeys(const std::string& publicKeyOpenSsh);

/**
 * 安装公钥到远端服务器 (同步阻塞, 应在独立线程中调用)
 *
 * 使用 libssh2 建立独立 SSH 连接, 执行:
 *   mkdir -p ~/.ssh && chmod 700 ~/.ssh
 *   grep -q '<key>' ~/.ssh/authorized_keys || echo '<key>' >> ~/.ssh/authorized_keys
 *   chmod 600 ~/.ssh/authorized_keys
 *
 * @param host          服务器地址
 * @param port          SSH 端口
 * @param username      用户名
 * @param password      密码 (空 = 使用密钥认证)
 * @param privateKeyPem 私钥 PEM (空 = 只用密码)
 * @param passphrase    私钥密码
 * @param publicKey     authorized_keys 公钥行
 * @return SshPublicKeyInstallResult
 */
SshPublicKeyInstallResult installSshPublicKey(
    const std::string& host,
    int port,
    const std::string& username,
    const std::string& password,
    const std::string& privateKeyPem,
    const std::string& passphrase,
    const std::string& publicKey
);

/**
 * 测试 SSH 密钥认证是否可用 (同步阻塞, 应在独立线程中调用)
 *
 * @param host          服务器地址
 * @param port          SSH 端口
 * @param username      用户名
 * @param privateKeyPem 待测试的私钥 PEM
 * @param passphrase    私钥密码
 * @return SshAuthTestResult
 */
SshAuthTestResult testSshKeyAuth(
    const std::string& host,
    int port,
    const std::string& username,
    const std::string& privateKeyPem,
    const std::string& passphrase
);

/**
 * 探测 SSH 主机公钥 (仅 TCP + KEX, 不做用户认证)
 *
 * 用于连接前安全预检: 获取主机指纹供用户确认, 防止 MITM.
 * 同步阻塞, 建议在独立线程中调用.
 *
 * @param host  服务器地址
 * @param port  SSH 端口
 * @return SshHostKeyInfo (ok=true 含 algorithm + fingerprintSha256 + rawBase64)
 */
SshHostKeyInfo probeSshHostKey(
    const std::string& host,
    int port
);

#endif // SSH_KEY_TOOL_H
