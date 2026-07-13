/**
 * host_locker.h — 主机安全锁
 *
 * 基于 HUKS (Harmony Universal Keystore) 的 AES-256-GCM 加密存储。
 * 密钥存储在 TEE 安全环境中。
 */

#ifndef HOST_LOCKER_H
#define HOST_LOCKER_H

#include "extensions/data_provider.h"
#include <string>
#include <vector>

struct LockInfo {
    std::string hostId;
    LockType lockType;
    std::vector<uint8_t> encryptedCredential; // AES-256-GCM 加密的凭证
    std::vector<uint8_t> iv;                  // 初始化向量
    std::vector<uint8_t> tag;                 // 认证标签 (GCM)
    int attemptCount;
    int64_t lockoutUntil;
};

class HostLocker {
public:
    static HostLocker& instance();

    /** 初始化 HUKS 上下文 */
    bool initialize();

    /** 设置主机锁 (加密凭证并存储) */
    bool setLock(const std::string& hostId, LockType lockType,
                 const std::string& credential);

    /** 验证主机锁 (解密并比较凭证) */
    bool verifyLock(const std::string& hostId, const std::string& credential);

    /** 移除主机锁 */
    bool removeLock(const std::string& hostId);

    /** 检查是否已加锁 */
    bool isLocked(const std::string& hostId);

    /** 获取锁类型 */
    LockType getLockType(const std::string& hostId);

private:
    HostLocker() = default;
    bool initialized_ = false;

    /** HUKS AES-256-GCM 加密 (TEE 内执行) */
    bool huksEncrypt(const std::vector<uint8_t>& plaintext,
                     const std::vector<uint8_t>& keyAlias,
                     std::vector<uint8_t>& ciphertext,
                     std::vector<uint8_t>& iv,
                     std::vector<uint8_t>& tag);

    /** HUKS AES-256-GCM 解密 (TEE 内执行) */
    bool huksDecrypt(const std::vector<uint8_t>& ciphertext,
                     const std::vector<uint8_t>& keyAlias,
                     const std::vector<uint8_t>& iv,
                     const std::vector<uint8_t>& tag,
                     std::vector<uint8_t>& plaintext);

    /** 存储锁信息到本地 */
    bool saveLockInfo(const LockInfo& info);

    /** 从本地加载锁信息 */
    LockInfo* loadLockInfo(const std::string& hostId);

    /** 生成本地主密钥 (存储在 TEE 内) */
    std::vector<uint8_t> deriveMasterKey();

    std::vector<LockInfo> lockStore_;
    std::vector<uint8_t> masterKeySalt_;
};

#endif // HOST_LOCKER_H
