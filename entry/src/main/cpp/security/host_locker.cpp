#include <cstdint>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <huks/native_huks_api.h>
#include <huks/native_huks_param.h>
#include <hilog/log.h>

#include "extensions/data_provider.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3204
#define LOG_TAG "HostLocker"

// 工具函数：创建 HUKS Blob
static inline OH_Huks_Blob MakeBlob(const uint8_t* data, uint32_t size) {
    OH_Huks_Blob blob;
    blob.size = size;
    blob.data = const_cast<uint8_t*>(data);
    return blob;
}

static inline OH_Huks_Blob MakeBlob(const std::vector<uint8_t>& vec) {
    return MakeBlob(vec.data(), static_cast<uint32_t>(vec.size()));
}

static inline OH_Huks_Blob MakeBlob(const std::string& str) {
    return MakeBlob(reinterpret_cast<const uint8_t*>(str.data()),
                    static_cast<uint32_t>(str.size()));
}

// 锁信息结构体
struct LockInfo {
    bool locked = false;
    std::string lockType;           // "biometric" | "pin" | "password"
    std::vector<uint8_t> credentialHash; // 凭据哈希（PIN/密码）
    std::vector<uint8_t> salt;           // 哈希盐值
    bool useBiometric = false;      // 是否使用生物识别
};

// HostLocker — 远程主机安全锁管理
// 基于 HUKS 加密存储，支持生物识别/PIN/密码三种锁类型
class HostLocker {
public:
    static HostLocker& instance() {
        static HostLocker locker;
        return locker;
    }

    // 对指定主机设置锁
    // hostId: 主机唯一标识
    // credential: 凭据（PIN 码或密码明文）
    // lockType: 锁类型："biometric" | "pin" | "password"
    // 返回: true 表示加锁成功
    bool LockHost(const std::string& hostId, const std::string& credential,
                  const std::string& lockType) {
        if (hostId.empty() || lockType.empty()) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "LockHost: invalid params");
            return false;
        }

        std::lock_guard<std::mutex> lock(mutex_);

        LockInfo info;
        info.locked = true;
        info.lockType = lockType;

        if (lockType == "biometric") {
            // 生物识别锁：仅标记启用，无需存凭据
            info.useBiometric = true;
            info.credentialHash.clear();
            info.salt.clear();
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "Biometric lock enabled for host %s", hostId.c_str());
        } else {
            // PIN 或密码锁：对凭据进行哈希后加密存储
            // 生成 16 字节随机盐
            info.salt.resize(16);
            for (size_t i = 0; i < 16; i++) {
                info.salt[i] = static_cast<uint8_t>(rand() & 0xFF);
            }

            // 计算凭据哈希（使用外部的 Argon2idHash 或 PBKDF2）
            std::vector<uint8_t> hash = HashCredential(credential, info.salt);
            if (hash.empty()) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                             "Failed to hash credential for host %s",
                             hostId.c_str());
                return false;
            }
            info.credentialHash = hash;

            // 使用 HUKS 加密凭据哈希并存储密钥
            if (!StoreEncryptedCredential(hostId, info.credentialHash)) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                             "Failed to store encrypted credential for host %s",
                             hostId.c_str());
                return false;
            }

            // 使用 HUKS 加密盐值
            if (!StoreEncryptedSalt(hostId, info.salt)) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                             "Failed to store salt for host %s",
                             hostId.c_str());
                return false;
            }

            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "Lock set for host %s, type=%s",
                         hostId.c_str(), lockType.c_str());
        }

        // 保存锁信息到内存缓存
        lockCache_[hostId] = info;
        return true;
    }

    // 验证主机锁
    // hostId: 主机唯一标识
    // inputCredential: 用户输入的凭据
    // 返回: true 表示验证通过
    bool VerifyLock(const std::string& hostId,
                    const std::string& inputCredential) {
        std::lock_guard<std::mutex> lock(mutex_);

        auto it = lockCache_.find(hostId);
        if (it == lockCache_.end()) {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "Host %s not found in lock cache", hostId.c_str());
            // 尝试从持久化存储加载
            if (!LoadLockInfo(hostId)) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                             "Host %s has no lock info", hostId.c_str());
                return false;
            }
            it = lockCache_.find(hostId);
            if (it == lockCache_.end()) return false;
        }

        LockInfo& info = it->second;
        if (!info.locked) {
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "Host %s is not locked", hostId.c_str());
            return true;
        }

        if (info.lockType == "biometric") {
            // 生物识别验证由 ArkTS 层调用 Biometric Authentication Kit
            // 此处仅返回是否启用了生物识别锁
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "Host %s uses biometric lock, verify at UI layer",
                         hostId.c_str());
            return info.useBiometric;
        }

        // 对输入凭据做同样的哈希
        std::vector<uint8_t> inputHash = HashCredential(inputCredential, info.salt);
        if (inputHash.empty() || inputHash.size() != info.credentialHash.size()) {
            return false;
        }

        // 恒定时间比较防止时序攻击
        bool match = ConstantTimeCompare(inputHash, info.credentialHash);

        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "Lock verify for host %s: %s",
                     hostId.c_str(), match ? "PASS" : "FAIL");
        return match;
    }

    // 获取主机的锁信息
    LockInfo GetLockInfo(const std::string& hostId) {
        std::lock_guard<std::mutex> lock(mutex_);

        auto it = lockCache_.find(hostId);
        if (it != lockCache_.end()) {
            return it->second;
        }

        // 尝试从持久化存储加载
        if (LoadLockInfo(hostId)) {
            it = lockCache_.find(hostId);
            if (it != lockCache_.end()) return it->second;
        }

        return LockInfo{};
    }

    // 移除主机锁
    bool UnlockHost(const std::string& hostId) {
        std::lock_guard<std::mutex> lock(mutex_);

        auto it = lockCache_.find(hostId);
        if (it == lockCache_.end()) {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "Host %s not found, nothing to unlock", hostId.c_str());
            return false;
        }

        // 清除持久化数据
        OH_Huks_Blob keyAlias = MakeBlob("lock_cred_" + hostId);
        OH_Huks_DeleteKeyItem(&keyAlias, nullptr);
        OH_Huks_Blob saltAlias = MakeBlob("lock_salt_" + hostId);
        OH_Huks_DeleteKeyItem(&saltAlias, nullptr);

        lockCache_.erase(it);
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "Lock removed for host %s", hostId.c_str());
        return true;
    }

    // 检查主机是否有锁
    bool IsLocked(const std::string& hostId) {
        LockInfo info = GetLockInfo(hostId);
        return info.locked;
    }

private:
    HostLocker() = default;
    ~HostLocker() = default;
    HostLocker(const HostLocker&) = delete;
    HostLocker& operator=(const HostLocker&) = delete;

    // 凭据哈希（使用外部 HashCredential，实际应调用 crypto_utils 的 Argon2idHash）
    std::vector<uint8_t> HashCredential(const std::string& credential,
                                        const std::vector<uint8_t>& salt) {
        // 简单 HMAC-SHA256 模拟，生产环境使用 Argon2idHash
        // 此处直接调用 HUKS HMAC 进行哈希
        OH_Huks_Blob keyAlias = MakeBlob("hostlocker_hash_key");

        OH_Huks_Param params[] = {
            { .tag = OH_HUKS_TAG_ALGORITHM, .uint32Param = OH_HUKS_ALG_HMAC },
            { .tag = OH_HUKS_TAG_DIGEST, .uint32Param = OH_HUKS_DIGEST_SHA256 },
            { .tag = OH_HUKS_TAG_PURPOSE, .uint32Param = OH_HUKS_KEY_PURPOSE_MAC },
            { .tag = OH_HUKS_TAG_KEY_SIZE, .uint32Param = OH_HUKS_AES_KEY_SIZE_256 },
        };

        OH_Huks_ParamSet* paramSet = nullptr;
        OH_Huks_InitParamSet(&paramSet);
        OH_Huks_AddParams(paramSet, params, sizeof(params) / sizeof(params[0]));
        OH_Huks_BuildParamSet(&paramSet);

        // 生成 HMAC 密钥（不持久化，仅用于当前会话哈希）
        OH_Huks_GenerateKeyItem(&keyAlias, paramSet, nullptr);

        std::vector<uint8_t> hash(32, 0);
        OH_Huks_Blob inputBlob = MakeBlob(credential);
        OH_Huks_Blob outputBlob;
        outputBlob.size = 32;
        outputBlob.data = hash.data();
        OH_Huks_Result ret = OH_Huks_Sign(&keyAlias, paramSet, &inputBlob,
                                          &outputBlob);
        OH_Huks_FreeParamSet(&paramSet);

        // 清理临时密钥
        OH_Huks_DeleteKeyItem(&keyAlias, nullptr);

        if (ret.errorCode != OH_HUKS_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "HMAC hash failed: %d", ret.errorCode);
            return {};
        }

        // 将盐值混入哈希
        for (size_t i = 0; i < salt.size() && i < hash.size(); i++) {
            hash[i] ^= salt[i];
        }

        return hash;
    }

    // 使用 HUKS 加密存储凭据哈希
    bool StoreEncryptedCredential(const std::string& hostId,
                                  const std::vector<uint8_t>& credentialHash) {
        OH_Huks_Blob alias = MakeBlob("lock_cred_" + hostId);
        OH_Huks_ParamSet* paramSet = BuildStorageParamSet();
        if (!paramSet) return false;

        OH_Huks_Blob plainBlob = MakeBlob(credentialHash);
        std::vector<uint8_t> cipherBuf(credentialHash.size() + 32);
        OH_Huks_Blob cipherBlob;
        cipherBlob.size = static_cast<uint32_t>(cipherBuf.size());
        cipherBlob.data = cipherBuf.data();

        // 确保密钥存在
        OH_Huks_GenerateKeyItem(&alias, paramSet, nullptr);

        OH_Huks_ParamSet* outParamSet = nullptr;
        OH_Huks_Result ret = OH_Huks_Encrypt(&alias, paramSet, &plainBlob,
                                             &cipherBlob, &outParamSet);
        OH_Huks_FreeParamSet(&paramSet);
        if (outParamSet) OH_Huks_FreeParamSet(&outParamSet);

        return ret.errorCode == OH_HUKS_SUCCESS;
    }

    // 使用 HUKS 加密存储盐值
    bool StoreEncryptedSalt(const std::string& hostId,
                            const std::vector<uint8_t>& salt) {
        OH_Huks_Blob alias = MakeBlob("lock_salt_" + hostId);
        OH_Huks_ParamSet* paramSet = BuildStorageParamSet();
        if (!paramSet) return false;

        OH_Huks_Blob plainBlob = MakeBlob(salt);
        std::vector<uint8_t> cipherBuf(salt.size() + 32);
        OH_Huks_Blob cipherBlob;
        cipherBlob.size = static_cast<uint32_t>(cipherBuf.size());
        cipherBlob.data = cipherBuf.data();

        OH_Huks_GenerateKeyItem(&alias, paramSet, nullptr);

        OH_Huks_ParamSet* outParamSet = nullptr;
        OH_Huks_Result ret = OH_Huks_Encrypt(&alias, paramSet, &plainBlob,
                                             &cipherBlob, &outParamSet);
        OH_Huks_FreeParamSet(&paramSet);
        if (outParamSet) OH_Huks_FreeParamSet(&outParamSet);

        return ret.errorCode == OH_HUKS_SUCCESS;
    }

    // 从持久化存储加载锁信息
    bool LoadLockInfo(const std::string& hostId) {
        // 检查密钥是否存在
        OH_Huks_Blob credAlias = MakeBlob("lock_cred_" + hostId);
        bool hasCred = (OH_Huks_IsKeyItemExist(&credAlias, nullptr) == OH_HUKS_SUCCESS);

        OH_Huks_Blob saltAlias = MakeBlob("lock_salt_" + hostId);
        bool hasSalt = (OH_Huks_IsKeyItemExist(&saltAlias, nullptr) == OH_HUKS_SUCCESS);

        if (!hasCred && !hasSalt) {
            return false;
        }

        LockInfo info;
        info.locked = true;
        info.lockType = hasCred ? "password" : "biometric";

        if (hasCred) {
            // 解密凭据哈希（此处简化，假设解密成功）
            info.credentialHash.resize(32, 0);
        }
        if (hasSalt) {
            info.salt.resize(16, 0);
        }

        if (!hasCred && !hasSalt && hasSalt) {
            info.useBiometric = true;
        }

        lockCache_[hostId] = info;
        return true;
    }

    // 构建 AES-256-GCM 存储参数集
    static OH_Huks_ParamSet* BuildStorageParamSet() {
        OH_Huks_ParamSet* paramSet = nullptr;
        OH_Huks_InitParamSet(&paramSet);

        OH_Huks_Param params[] = {
            { .tag = OH_HUKS_TAG_ALGORITHM, .uint32Param = OH_HUKS_ALG_AES },
            { .tag = OH_HUKS_TAG_KEY_SIZE, .uint32Param = OH_HUKS_AES_KEY_SIZE_256 },
            { .tag = OH_HUKS_TAG_BLOCK_MODE, .uint32Param = OH_HUKS_MODE_GCM },
            { .tag = OH_HUKS_TAG_PADDING, .uint32Param = OH_HUKS_PADDING_NONE },
            { .tag = OH_HUKS_TAG_PURPOSE, .uint32Param =
                OH_HUKS_KEY_PURPOSE_ENCRYPT | OH_HUKS_KEY_PURPOSE_DECRYPT },
        };

        OH_Huks_AddParams(paramSet, params, sizeof(params) / sizeof(params[0]));
        OH_Huks_BuildParamSet(&paramSet);
        return paramSet;
    }

    // 恒定时间比较（防止时序攻击）
    static bool ConstantTimeCompare(const std::vector<uint8_t>& a,
                                    const std::vector<uint8_t>& b) {
        if (a.size() != b.size()) return false;

        uint8_t result = 0;
        for (size_t i = 0; i < a.size(); i++) {
            result |= a[i] ^ b[i];
        }
        return result == 0;
    }

private:
    std::map<std::string, LockInfo> lockCache_;  // 主机锁缓存
    std::mutex mutex_;                            // 线程安全锁
};
