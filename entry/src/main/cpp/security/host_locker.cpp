/**
 * host_locker.cpp — 主机安全锁 Mock 实现
 *
 * TODO: 集成 HUKS API 实现 TEE 内 AES-256-GCM 加解密
 *   OH_Huks_GenerateKeyItem(&alias, paramSet, nullptr, nullptr);
 *   OH_Huks_Encrypt(&alias, paramSet, &plainText, &cipherText);
 */

#include "host_locker.h"
#include "crypto_utils.h"
#include <hilog/log.h>
#include <algorithm>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0021
#define LOG_TAG "HOST_LOCKER"

HostLocker& HostLocker::instance() {
    static HostLocker locker;
    return locker;
}

bool HostLocker::initialize() {
    if (initialized_) return true;
    masterKeySalt_ = CryptoUtils::generateRandom(32);
    initialized_ = true;
    OH_LOG_INFO(LOG_APP, "[Locker] HUKS 上下文已初始化");
    return true;
}

bool HostLocker::setLock(const std::string& hostId, LockType lockType,
                          const std::string& credential) {
    if (!initialized_) initialize();

    // 生成随机盐
    auto salt = CryptoUtils::generateRandom(16);

    // 派生密钥 (基于凭证 + 盐)
    auto key = CryptoUtils::deriveKey(credential, salt, 32);

    // Mock 加密: 将凭证哈希 + 盐存储
    auto credentialHash = CryptoUtils::sha256(credential);

    LockInfo info;
    info.hostId = hostId;
    info.lockType = lockType;
    info.encryptedCredential = std::vector<uint8_t>(credentialHash.begin(), credentialHash.end());
    info.iv = salt;
    info.attemptCount = 0;
    info.lockoutUntil = 0;

    // 移除已有锁 (如有)
    removeLock(hostId);

    lockStore_.push_back(info);
    saveLockInfo(info);

    OH_LOG_INFO(LOG_APP, "[Locker] 锁已设置: %{public}s, type=%{public}d",
                hostId.c_str(), static_cast<int>(lockType));
    return true;
}

bool HostLocker::verifyLock(const std::string& hostId, const std::string& credential) {
    auto* info = loadLockInfo(hostId);
    if (!info) {
        OH_LOG_INFO(LOG_APP, "[Locker] 主机 %{public}s 未加锁，无需验证", hostId.c_str());
        return true; // 未加锁, 通过 (正确行为: 无锁的主机无需验证即可访问)
    }

    // 检查锁定期
    // if (info->lockoutUntil > 0 && currentTimeMs() < info->lockoutUntil) return false;

    // Mock 验证: 比较凭证哈希
    auto inputHash = CryptoUtils::sha256(credential);
    std::vector<uint8_t> inputHashBytes(inputHash.begin(), inputHash.end());

    if (CryptoUtils::secureCompare(inputHashBytes, info->encryptedCredential)) {
        info->attemptCount = 0;
        OH_LOG_INFO(LOG_APP, "[Locker] 验证成功: %{public}s", hostId.c_str());
        return true;
    }

    info->attemptCount++;
    OH_LOG_WARN(LOG_APP, "[Locker] 验证失败: %{public}s, 尝试次数: %{public}d",
                hostId.c_str(), info->attemptCount);
    return false;
}

bool HostLocker::removeLock(const std::string& hostId) {
    auto it = std::find_if(lockStore_.begin(), lockStore_.end(),
        [&](const LockInfo& info) { return info.hostId == hostId; });
    if (it != lockStore_.end()) {
        lockStore_.erase(it);
        OH_LOG_INFO(LOG_APP, "[Locker] 锁已移除: %{public}s", hostId.c_str());
        return true;
    }
    return false;
}

bool HostLocker::isLocked(const std::string& hostId) {
    return loadLockInfo(const_cast<std::string&>(hostId)) != nullptr;
}

LockType HostLocker::getLockType(const std::string& hostId) {
    auto* info = loadLockInfo(const_cast<std::string&>(hostId));
    return info ? info->lockType : LockType::NONE;
}

bool HostLocker::huksEncrypt(const std::vector<uint8_t>& plaintext,
                              const std::vector<uint8_t>& keyAlias,
                              std::vector<uint8_t>& ciphertext,
                              std::vector<uint8_t>& iv,
                              std::vector<uint8_t>& tag) {
    // TODO: OH_Huks_Encrypt()
    ciphertext = plaintext;
    iv = CryptoUtils::generateRandom(12);      // GCM 推荐 12 字节 IV
    tag = CryptoUtils::generateRandom(16);     // GCM 标签
    return true;
}

bool HostLocker::huksDecrypt(const std::vector<uint8_t>& ciphertext,
                              const std::vector<uint8_t>& keyAlias,
                              const std::vector<uint8_t>& iv,
                              const std::vector<uint8_t>& tag,
                              std::vector<uint8_t>& plaintext) {
    // TODO: OH_Huks_Decrypt()
    plaintext = ciphertext;
    return true;
}

bool HostLocker::saveLockInfo(const LockInfo& info) {
    // TODO: 使用 Preferences 持久化
    return true;
}

LockInfo* HostLocker::loadLockInfo(const std::string& hostId) {
    for (auto& info : lockStore_) {
        if (info.hostId == hostId) return &info;
    }
    return nullptr;
}

std::vector<uint8_t> HostLocker::deriveMasterKey() {
    return CryptoUtils::generateRandom(32);
}
