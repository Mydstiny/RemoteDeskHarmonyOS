/**
 * crypto_utils.h — 加密工具类
 *
 * 提供密码学基础操作：随机数生成、密钥派生、常量时间比较、Base64 编解码。
 */

#ifndef CRYPTO_UTILS_H
#define CRYPTO_UTILS_H

#include <cstdint>
#include <string>
#include <vector>

class CryptoUtils {
public:
    /** 生成加密安全的随机字节 */
    static std::vector<uint8_t> generateRandom(size_t size);

    /** PBKDF2-SHA256 密钥派生 */
    static std::vector<uint8_t> deriveKey(const std::string& password,
                                          const std::vector<uint8_t>& salt,
                                          size_t keyLength = 32,
                                          uint32_t iterations = 100000);

    /** 常量时间比较 (防止时序攻击) */
    static bool secureCompare(const std::string& a, const std::string& b);
    static bool secureCompare(const std::vector<uint8_t>& a,
                              const std::vector<uint8_t>& b);

    /** Base64 编解码 */
    static std::string base64Encode(const std::vector<uint8_t>& data);
    static std::vector<uint8_t> base64Decode(const std::string& encoded);

    /** SHA-256 哈希 (mock 使用简化版) */
    static std::string sha256(const std::string& input);

    /** 字节数组转十六进制字符串 */
    static std::string toHex(const std::vector<uint8_t>& data);
    static std::vector<uint8_t> fromHex(const std::string& hex);
};

#endif // CRYPTO_UTILS_H
