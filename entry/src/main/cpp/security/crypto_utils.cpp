/**
 * crypto_utils.cpp — 加密工具类 (基于 CryptoArchitectureKit C API)
 *
 * 提供密码学基础操作：随机数生成 (OH_CryptoRand)、
 * 密钥派生 PBKDF2 (OH_CryptoKdf)、SHA256 摘要 (OH_CryptoDigest)、
 * 常量时间比较、Base64 编解码。
 */

#include "crypto_utils.h"
#include <hilog/log.h>
#include <cstring>
#include <sstream>
#include <iomanip>

// CryptoArchitectureKit C API
#include <CryptoArchitectureKit/crypto_common.h>
#include <CryptoArchitectureKit/crypto_kdf.h>
#include <CryptoArchitectureKit/crypto_digest.h>
#include <CryptoArchitectureKit/crypto_rand.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0020
#define LOG_TAG "CRYPTO"

std::vector<uint8_t> CryptoUtils::generateRandom(size_t size) {
    std::vector<uint8_t> result(size);

    OH_CryptoRand* ctx = nullptr;
    OH_Crypto_ErrCode rc = OH_CryptoRand_Create(&ctx);
    if (rc != CRYPTO_SUCCESS || !ctx) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoRand_Create failed: %{public}d — retrying once",
                     LOG_TAG, rc);
        // 重试一次
        rc = OH_CryptoRand_Create(&ctx);
        if (rc != CRYPTO_SUCCESS || !ctx) {
            OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoRand_Create retry also failed: %{public}d — returning empty",
                         LOG_TAG, rc);
            return {}; // 返回空 vector 表示失败, 调用者必须检查
        }
    }

    Crypto_DataBlob outBlob;
    outBlob.data = nullptr;
    outBlob.len = 0;
    rc = OH_CryptoRand_GenerateRandom(ctx, static_cast<int>(size), &outBlob);
    if (rc == CRYPTO_SUCCESS && outBlob.data && outBlob.len >= size) {
        std::memcpy(result.data(), outBlob.data, size);
    } else {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoRand_GenerateRandom failed: %{public}d — returning empty",
                     LOG_TAG, rc);
        // 返回空 vector 表示失败, 调用者必须检查
        if (outBlob.data) {
            OH_Crypto_FreeDataBlob(&outBlob);
        }
        OH_CryptoRand_Destroy(ctx);
        return {};
    }

    if (outBlob.data) {
        OH_Crypto_FreeDataBlob(&outBlob);
    }
    OH_CryptoRand_Destroy(ctx);
    return result;
}

std::vector<uint8_t> CryptoUtils::deriveKey(const std::string& password,
                                             const std::vector<uint8_t>& salt,
                                             size_t keyLength, uint32_t iterations) {
    std::vector<uint8_t> key(keyLength);

    // 1. 创建 KDF 参数
    OH_CryptoKdfParams* params = nullptr;
    OH_Crypto_ErrCode rc = OH_CryptoKdfParams_Create("PBKDF2", &params);
    if (rc != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoKdfParams_Create failed: %{public}d",
                     LOG_TAG, rc);
        return key; // 返回零填充 key
    }

    // 2. 设置密码 (key data)
    Crypto_DataBlob keyBlob;
    keyBlob.data = const_cast<uint8_t*>(reinterpret_cast<const uint8_t*>(password.data()));
    keyBlob.len = password.size();
    rc = OH_CryptoKdfParams_SetParam(params, CRYPTO_KDF_KEY_DATABLOB, &keyBlob);
    if (rc != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] SetParam KEY failed: %{public}d", LOG_TAG, rc);
        OH_CryptoKdfParams_Destroy(params);
        return key;
    }

    // 3. 设置盐值
    Crypto_DataBlob saltBlob;
    saltBlob.data = const_cast<uint8_t*>(salt.data());
    saltBlob.len = salt.size();
    rc = OH_CryptoKdfParams_SetParam(params, CRYPTO_KDF_SALT_DATABLOB, &saltBlob);
    if (rc != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] SetParam SALT failed: %{public}d", LOG_TAG, rc);
        OH_CryptoKdfParams_Destroy(params);
        return key;
    }

    // 4. 设置迭代次数
    Crypto_DataBlob iterBlob;
    iterBlob.data = reinterpret_cast<uint8_t*>(&iterations);
    iterBlob.len = sizeof(iterations);
    rc = OH_CryptoKdfParams_SetParam(params, CRYPTO_KDF_ITER_COUNT_INT, &iterBlob);
    if (rc != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] SetParam ITER failed: %{public}d", LOG_TAG, rc);
        OH_CryptoKdfParams_Destroy(params);
        return key;
    }

    // 5. 创建 KDF 实例 (PBKDF2|SHA256)
    OH_CryptoKdf* kdf = nullptr;
    rc = OH_CryptoKdf_Create("PBKDF2|SHA256", &kdf);
    if (rc != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoKdf_Create failed: %{public}d",
                     LOG_TAG, rc);
        OH_CryptoKdfParams_Destroy(params);
        return key;
    }

    // 6. 派生密钥
    Crypto_DataBlob derivedKeyBlob;
    derivedKeyBlob.data = nullptr;
    derivedKeyBlob.len = 0;
    rc = OH_CryptoKdf_Derive(kdf, params, static_cast<int>(keyLength), &derivedKeyBlob);
    if (rc != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoKdf_Derive failed: %{public}d",
                     LOG_TAG, rc);
        OH_CryptoKdf_Destroy(kdf);
        OH_CryptoKdfParams_Destroy(params);
        return key;
    }

    // 7. 复制结果
    if (derivedKeyBlob.data && derivedKeyBlob.len >= keyLength) {
        std::memcpy(key.data(), derivedKeyBlob.data, keyLength);
    }

    // 8. 清理
    OH_Crypto_FreeDataBlob(&derivedKeyBlob);
    OH_CryptoKdf_Destroy(kdf);
    OH_CryptoKdfParams_Destroy(params);

    OH_LOG_INFO(LOG_APP, "[%{public}s] PBKDF2|SHA256 派生完成: keyLen=%{public}zu iter=%{public}u",
                LOG_TAG, keyLength, iterations);
    return key;
}

bool CryptoUtils::secureCompare(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    int result = 0;
    for (size_t i = 0; i < a.size(); ++i) result |= (a[i] ^ b[i]);
    return result == 0;
}

bool CryptoUtils::secureCompare(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    if (a.size() != b.size()) return false;
    int result = 0;
    for (size_t i = 0; i < a.size(); ++i) result |= (a[i] ^ b[i]);
    return result == 0;
}

// ============================================================
// Base64 编解码 (独立实现，不依赖 CryptoArchitectureKit)
// ============================================================

static const char BASE64_CHARS[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string CryptoUtils::base64Encode(const std::vector<uint8_t>& data) {
    std::string result;
    int val = 0, valb = -6;
    for (uint8_t c : data) {
        val = (val << 8) + c;
        valb += 8;
        while (valb >= 0) {
            result.push_back(BASE64_CHARS[(val >> valb) & 0x3F]);
            valb -= 6;
        }
    }
    if (valb > -6) result.push_back(BASE64_CHARS[((val << 8) >> (valb + 8)) & 0x3F]);
    while (result.size() % 4) result.push_back('=');
    return result;
}

std::vector<uint8_t> CryptoUtils::base64Decode(const std::string& encoded) {
    std::vector<uint8_t> result;
    static const int DECODE_TABLE[256] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
    };
    const size_t len = encoded.size();
    for (size_t i = 0; i < len; i += 4) {
        int b0 = DECODE_TABLE[static_cast<uint8_t>(encoded[i])];
        int b1 = (i + 1 < len && encoded[i + 1] != '=') ? DECODE_TABLE[static_cast<uint8_t>(encoded[i + 1])] : -1;
        int b2 = (i + 2 < len && encoded[i + 2] != '=') ? DECODE_TABLE[static_cast<uint8_t>(encoded[i + 2])] : -1;
        int b3 = (i + 3 < len && encoded[i + 3] != '=') ? DECODE_TABLE[static_cast<uint8_t>(encoded[i + 3])] : -1;
        if (b0 >= 0 && b1 >= 0) {
            result.push_back(static_cast<uint8_t>((b0 << 2) | (b1 >> 4)));
        }
        if (b2 >= 0) {
            result.push_back(static_cast<uint8_t>(((b1 & 0x0F) << 4) | (b2 >> 2)));
        }
        if (b3 >= 0) {
            result.push_back(static_cast<uint8_t>(((b2 & 0x03) << 6) | b3));
        }
    }
    return result;
}

std::string CryptoUtils::sha256(const std::string& input) {
    std::string hash(32, '\0');

    // 1. 创建 SHA256 摘要实例
    OH_CryptoDigest* ctx = nullptr;
    OH_Crypto_ErrCode rc = OH_CryptoDigest_Create("SHA256", &ctx);
    if (rc != CRYPTO_SUCCESS || !ctx) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoDigest_Create(SHA256) failed: %{public}d",
                     LOG_TAG, rc);
        return hash;
    }

    // 2. 更新数据
    Crypto_DataBlob inBlob;
    inBlob.data = const_cast<uint8_t*>(reinterpret_cast<const uint8_t*>(input.data()));
    inBlob.len = input.size();
    rc = OH_CryptoDigest_Update(ctx, &inBlob);
    if (rc != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoDigest_Update failed: %{public}d",
                     LOG_TAG, rc);
        OH_DigestCrypto_Destroy(ctx);
        return hash;
    }

    // 3. 完成摘要
    Crypto_DataBlob outBlob;
    outBlob.data = nullptr;
    outBlob.len = 0;
    rc = OH_CryptoDigest_Final(ctx, &outBlob);
    if (rc != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_CryptoDigest_Final failed: %{public}d",
                     LOG_TAG, rc);
        OH_DigestCrypto_Destroy(ctx);
        return hash;
    }

    // 4. 复制结果
    if (outBlob.data && outBlob.len > 0) {
        hash.assign(reinterpret_cast<char*>(outBlob.data), outBlob.len);
        OH_Crypto_FreeDataBlob(&outBlob);
    }

    OH_DigestCrypto_Destroy(ctx);
    return hash;
}

std::string CryptoUtils::toHex(const std::vector<uint8_t>& data) {
    std::stringstream ss;
    ss << std::hex << std::setfill('0');
    for (uint8_t b : data) ss << std::setw(2) << static_cast<int>(b);
    return ss.str();
}

std::vector<uint8_t> CryptoUtils::fromHex(const std::string& hex) {
    std::vector<uint8_t> result;
    for (size_t i = 0; i + 1 < hex.length(); i += 2) {
        unsigned int byte;
        std::stringstream ss;
        ss << std::hex << hex.substr(i, 2);
        ss >> byte;
        result.push_back(static_cast<uint8_t>(byte));
    }
    return result;
}
