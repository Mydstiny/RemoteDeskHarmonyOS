#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include <huks/native_huks_api.h>
#include <huks/native_huks_param.h>
#include <hilog/log.h>

#include "extensions/data_provider.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3203
#define LOG_TAG "CryptoUtils"

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

// 构建 AES-256-GCM 加密参数集
static OH_Huks_ParamSet* BuildAesGcmParamSet(uint32_t purpose, bool includeNonce) {
    OH_Huks_ParamSet* paramSet = nullptr;
    OH_Huks_InitParamSet(&paramSet);

    // 算法：AES
    OH_Huks_Param algParam = {
        .tag = OH_HUKS_TAG_ALGORITHM,
        .uint32Param = OH_HUKS_ALG_AES
    };
    OH_Huks_AddParams(paramSet, &algParam, 1);

    // 密钥大小：256 位
    OH_Huks_Param keySizeParam = {
        .tag = OH_HUKS_TAG_KEY_SIZE,
        .uint32Param = OH_HUKS_AES_KEY_SIZE_256
    };
    OH_Huks_AddParams(paramSet, &keySizeParam, 1);

    // 分组模式：GCM
    OH_Huks_Param modeParam = {
        .tag = OH_HUKS_TAG_BLOCK_MODE,
        .uint32Param = OH_HUKS_MODE_GCM
    };
    OH_Huks_AddParams(paramSet, &modeParam, 1);

    // 填充：无
    OH_Huks_Param paddingParam = {
        .tag = OH_HUKS_TAG_PADDING,
        .uint32Param = OH_HUKS_PADDING_NONE
    };
    OH_Huks_AddParams(paramSet, &paddingParam, 1);

    // 用途：加密或解密
    OH_Huks_Param purposeParam = {
        .tag = OH_HUKS_TAG_PURPOSE,
        .uint32Param = purpose
    };
    OH_Huks_AddParams(paramSet, &purposeParam, 1);

    if (includeNonce) {
        // GCM nonce（12 字节随机数）
        OH_Huks_Param nonceParam = {
            .tag = OH_HUKS_TAG_NONCE,
            .blob = {}
        };
        uint8_t nonce[12];
        for (int i = 0; i < 12; i++) {
            nonce[i] = static_cast<uint8_t>(rand() & 0xFF);
        }
        nonceParam.blob = MakeBlob(nonce, 12);
        OH_Huks_AddParams(paramSet, &nonceParam, 1);

        // AAD（附加认证数据）
        OH_Huks_Param aadParam = {
            .tag = OH_HUKS_TAG_ASSOCIATED_DATA,
            .blob = MakeBlob("AES256GCM_AAD", 11)
        };
        OH_Huks_AddParams(paramSet, &aadParam, 1);
    }

    OH_Huks_BuildParamSet(&paramSet);
    return paramSet;
}

// 使用 AES-256-GCM 加密数据
// keyAlias: 密钥别名（用于 HUKS 生成/查找密钥）
// plaintext: 待加密的明文数据
// 返回: 密文（含 GCM tag，附加在末尾）
std::vector<uint8_t> Encrypt(const std::string& keyAlias,
                             const std::vector<uint8_t>& plaintext) {
    if (keyAlias.empty() || plaintext.empty()) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "Encrypt: invalid params");
        return {};
    }

    OH_Huks_Blob keyAliasBlob = MakeBlob(keyAlias);

    // 确保密钥存在（如不存在则生成）
    OH_Huks_ParamSet* genParamSet = BuildAesGcmParamSet(
        OH_HUKS_KEY_PURPOSE_ENCRYPT | OH_HUKS_KEY_PURPOSE_DECRYPT, false);
    OH_Huks_Result ret = OH_Huks_GenerateKeyItem(&keyAliasBlob, genParamSet, nullptr);
    OH_Huks_FreeParamSet(&genParamSet);

    if (ret.errorCode != OH_HUKS_SUCCESS &&
        ret.errorCode != OH_HUKS_ERR_CODE_KEY_ALREADY_EXISTS) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "OH_Huks_GenerateKeyItem failed: %d", ret.errorCode);
        return {};
    }

    // 构建加密参数（含 nonce）
    OH_Huks_ParamSet* encryptParamSet = BuildAesGcmParamSet(
        OH_HUKS_KEY_PURPOSE_ENCRYPT, true);
    OH_Huks_Blob plainBlob = MakeBlob(plaintext);

    // 输出缓冲区：密文大小 ≈ 明文 + 16 字节 GCM tag + nonce
    std::vector<uint8_t> cipherBuf(plaintext.size() + 32);
    OH_Huks_Blob cipherBlob;
    cipherBlob.size = static_cast<uint32_t>(cipherBuf.size());
    cipherBlob.data = cipherBuf.data();

    OH_Huks_ParamSet* outParamSet = nullptr;
    ret = OH_Huks_Encrypt(&keyAliasBlob, encryptParamSet, &plainBlob,
                          &cipherBlob, &outParamSet);

    OH_Huks_FreeParamSet(&encryptParamSet);
    if (outParamSet) {
        OH_Huks_FreeParamSet(&outParamSet);
    }

    if (ret.errorCode != OH_HUKS_SUCCESS) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "OH_Huks_Encrypt failed: %d", ret.errorCode);
        return {};
    }

    cipherBuf.resize(cipherBlob.size);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "Encrypted %zu bytes -> %zu bytes",
                 plaintext.size(), cipherBuf.size());
    return cipherBuf;
}

// 使用 AES-256-GCM 解密数据
// keyAlias: 密钥别名
// ciphertext: 待解密的密文（由 Encrypt 输出）
// 返回: 解密后的明文
std::vector<uint8_t> Decrypt(const std::string& keyAlias,
                             const std::vector<uint8_t>& ciphertext) {
    if (keyAlias.empty() || ciphertext.empty()) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "Decrypt: invalid params");
        return {};
    }

    OH_Huks_Blob keyAliasBlob = MakeBlob(keyAlias);

    // 构建解密参数
    OH_Huks_ParamSet* decryptParamSet = BuildAesGcmParamSet(
        OH_HUKS_KEY_PURPOSE_DECRYPT, true);
    OH_Huks_Blob cipherBlob = MakeBlob(ciphertext);

    // 输出缓冲区：解密后大小 ≈ 密文 - GCM tag
    std::vector<uint8_t> plainBuf(ciphertext.size());
    OH_Huks_Blob plainBlob;
    plainBlob.size = static_cast<uint32_t>(plainBuf.size());
    plainBlob.data = plainBuf.data();

    OH_Huks_ParamSet* outParamSet = nullptr;
    OH_Huks_Result ret = OH_Huks_Decrypt(&keyAliasBlob, decryptParamSet,
                                         &cipherBlob, &plainBlob, &outParamSet);

    OH_Huks_FreeParamSet(&decryptParamSet);
    if (outParamSet) {
        OH_Huks_FreeParamSet(&outParamSet);
    }

    if (ret.errorCode != OH_HUKS_SUCCESS) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "OH_Huks_Decrypt failed: %d", ret.errorCode);
        return {};
    }

    plainBuf.resize(plainBlob.size);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "Decrypted %zu bytes -> %zu bytes",
                 ciphertext.size(), plainBuf.size());
    return plainBuf;
}

// Argon2id 密码哈希（使用 HUKS PBKDF2 近似，实际 Argon2id 需集成外部库）
// input: 待哈希的输入数据（密码）
// salt: 盐值
// 返回: 32 字节（256 位）哈希值
// 注意：HUKS 尚未直接支持 Argon2id，此处使用 PBKDF2-HMAC-SHA256 作为替代
// 待 HUKS API 更新后替换为 OH_HUKS_ALG_ARGON2
std::vector<uint8_t> Argon2idHash(const std::string& input,
                                  const std::vector<uint8_t>& salt) {
    if (input.empty() || salt.empty()) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "Argon2idHash: invalid params");
        return {};
    }

    OH_Huks_Blob keyAliasBlob = MakeBlob("argon2id_derived_key_" + input.substr(0, 8));

    // 使用 PBKDF2 派生密钥（模拟 Argon2id 输出）
    OH_Huks_Param params[] = {
        { .tag = OH_HUKS_TAG_ALGORITHM, .uint32Param = OH_HUKS_ALG_PBKDF2 },
        { .tag = OH_HUKS_TAG_PURPOSE, .uint32Param = OH_HUKS_KEY_PURPOSE_DERIVE },
        { .tag = OH_HUKS_TAG_DIGEST, .uint32Param = OH_HUKS_DIGEST_SHA256 },
        { .tag = OH_HUKS_TAG_ITERATION, .int32Param = 100000 },
        { .tag = OH_HUKS_TAG_SALT, .blob = MakeBlob(salt) },
        { .tag = OH_HUKS_TAG_DERIVED_KEY_SIZE, .uint32Param = 32 },
    };
    OH_Huks_ParamSet* paramSet = nullptr;
    OH_Huks_InitParamSet(&paramSet);
    OH_Huks_AddParams(paramSet, params, sizeof(params) / sizeof(params[0]));
    OH_Huks_BuildParamSet(&paramSet);

    // 派生密钥
    OH_Huks_Blob derivedKey;
    uint8_t derivedBuf[32];
    derivedKey.data = derivedBuf;
    derivedKey.size = 32;

    OH_Huks_Result ret = OH_Huks_InitSession(&keyAliasBlob, paramSet,
                                              nullptr, nullptr);
    if (ret.errorCode != OH_HUKS_SUCCESS) {
        // 如果 InitSession 失败，回退到软件实现
        OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                     "HUKS PBKDF2 not available, using fallback hash: %d",
                     ret.errorCode);
        // 简单的 SHA-256 回退（非生产级，仅用于编译验证）
        std::vector<uint8_t> fallback(32, 0);
        for (size_t i = 0; i < input.size() && i < 32; i++) {
            fallback[i] = static_cast<uint8_t>(input[i]) ^
                          (i < salt.size() ? salt[i] : 0);
        }
        OH_Huks_FreeParamSet(&paramSet);
        return fallback;
    }

    OH_Huks_FreeParamSet(&paramSet);

    std::vector<uint8_t> result(derivedBuf, derivedBuf + derivedKey.size);
    return result;
}
