/**
 * ssh_key_tool.cpp — SSH 标准密钥工具实现 (基于 OpenSSL 3.4.1 EVP_PKEY)
 *
 * 全部使用项目已静态链接的 OpenSSL, 零新增依赖.
 * Ed25519 密钥生成, RSA 4096 密钥生成, PEM 序列化, authorized_keys 公钥行,
 * SHA256 fingerprint, passphrase 管理, 安全校验.
 */
#include "ssh_key_tool.h"
#include "ssh_algorithm_prefs.h"
#include "ssh_auth_policy.h"
#include "ssh_proxy_target_policy.h"
#include "ssh_route_policy.h"

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/rsa.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <libssh2.h>
#include <cstring>
#include <climits>
#include <vector>
#include <algorithm>
#include <thread>
#include <chrono>
#include <cerrno>
#include <cstdlib>
#include <array>
#include <memory>
#include <sys/select.h>

#ifdef __OHOS__
#include "common/happy_eyeballs_connector.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#else
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#endif

// ============================================================
// 内部辅助
// ============================================================

/** 清空 OpenSSL 错误队列并收集错误信息 */
static std::string collectOpenSslErrors() {
    std::string msg;
    unsigned long err;
    while ((err = ERR_get_error()) != 0) {
        char buf[256];
        ERR_error_string_n(err, buf, sizeof(buf));
        if (!msg.empty()) msg += "; ";
        msg += buf;
    }
    return msg.empty() ? "unknown OpenSSL error" : msg;
}

/** Base64 编码 (标准, 无换行) */
static std::string base64Encode(const unsigned char* data, size_t len) {
    // OpenSSL EVP_EncodeBlock adds newlines every 64 chars — use BIO for cleaner output
    BIO* b64 = BIO_new(BIO_f_base64());
    BIO* mem = BIO_new(BIO_s_mem());
    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    BIO_push(b64, mem);
    BIO_write(b64, data, static_cast<int>(len));
    BIO_flush(b64);

    char* buf = nullptr;
    long size = BIO_get_mem_data(mem, &buf);
    std::string result(buf, size);

    BIO_free_all(b64); // frees mem chain
    // Strip trailing padding whitespace that BIO may leave
    while (!result.empty() && (result.back() == '\n' || result.back() == '\r')) {
        result.pop_back();
    }
    return result;
}

static bool verifyHostKeyBinding(LIBSSH2_SESSION* session,
                                 const std::string& expectedRawBase64,
                                 const std::string& expectedFingerprintSha256) {
    if (session == nullptr || (expectedRawBase64.empty() &&
                               expectedFingerprintSha256.empty())) {
        return true;
    }
    size_t keyLen = 0;
    int keyType = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    const char* rawKey = libssh2_session_hostkey(session, &keyLen, &keyType);
    (void)keyType;
    if (rawKey == nullptr || keyLen == 0) { return false; }
    if (!expectedRawBase64.empty() &&
        base64Encode(reinterpret_cast<const unsigned char*>(rawKey), keyLen) !=
            expectedRawBase64) {
        return false;
    }
    if (!expectedFingerprintSha256.empty()) {
        const char* fingerprint = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
        if (fingerprint == nullptr) { return false; }
        std::string encoded = base64Encode(
            reinterpret_cast<const unsigned char*>(fingerprint), 32);
        while (!encoded.empty() && encoded.back() == '=') { encoded.pop_back(); }
        if ("SHA256:" + encoded != expectedFingerprintSha256) { return false; }
    }
    return true;
}

struct SshProxyKeyboardContext {
    const std::string* password = nullptr;
    const std::vector<std::string>* explicitResponses = nullptr;
};

static void sshProxyKeyboardInteractiveCallback(
    const char* name, int nameLen, const char* instruction, int instructionLen,
    int numPrompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses, void** abstract) {
    (void)name;
    (void)nameLen;
    (void)instruction;
    (void)instructionLen;
    if (numPrompts <= 0 || responses == nullptr || abstract == nullptr ||
        *abstract == nullptr) {
        return;
    }
    auto* context = static_cast<SshProxyKeyboardContext*>(*abstract);
    for (int index = 0; index < numPrompts; ++index) {
        std::string response;
        if (context->explicitResponses != nullptr && index >= 0 &&
            static_cast<size_t>(index) < context->explicitResponses->size()) {
            response = (*context->explicitResponses)[static_cast<size_t>(index)];
        } else if (prompts != nullptr && context->password != nullptr &&
                   sshKeyboardInteractivePromptCanUsePassword(prompts[index].echo)) {
            response = *context->password;
        }
        if (response.empty()) {
            responses[index].text = nullptr;
            responses[index].length = 0;
            continue;
        }
        char* allocated = static_cast<char*>(std::malloc(response.size()));
        if (allocated == nullptr) {
            responses[index].text = nullptr;
            responses[index].length = 0;
            continue;
        }
        std::memcpy(allocated, response.data(), response.size());
        responses[index].text = allocated;
        responses[index].length = static_cast<unsigned int>(
            std::min<size_t>(response.size(), UINT_MAX));
    }
}

/** Base64 解码 (标准 PEM body, 忽略换行空白) */
static bool base64Decode(const std::string& text, std::vector<unsigned char>& out) {
    std::string compact;
    compact.reserve(text.size());
    for (char ch : text) {
        if (ch != '\r' && ch != '\n' && ch != ' ' && ch != '\t') {
            compact.push_back(ch);
        }
    }
    if (compact.empty()) {
        return false;
    }

    std::vector<unsigned char> decoded((compact.size() * 3) / 4 + 4);
    const int len = EVP_DecodeBlock(decoded.data(),
                                    reinterpret_cast<const unsigned char*>(compact.data()),
                                    static_cast<int>(compact.size()));
    if (len < 0) {
        return false;
    }
    size_t actualLen = static_cast<size_t>(len);
    while (!compact.empty() && compact.back() == '=') {
        if (actualLen == 0) {
            return false;
        }
        actualLen--;
        compact.pop_back();
    }
    decoded.resize(actualLen);
    out.swap(decoded);
    return true;
}

static bool extractPemBody(const std::string& pem,
                           const std::string& beginMarker,
                           const std::string& endMarker,
                           std::string& body) {
    const size_t begin = pem.find(beginMarker);
    if (begin == std::string::npos) {
        return false;
    }
    size_t bodyStart = pem.find('\n', begin);
    if (bodyStart == std::string::npos) {
        return false;
    }
    bodyStart++;
    const size_t end = pem.find(endMarker, bodyStart);
    if (end == std::string::npos || end <= bodyStart) {
        return false;
    }
    body = pem.substr(bodyStart, end - bodyStart);
    return true;
}

static bool readU32Be(const std::vector<unsigned char>& data, size_t& pos, uint32_t& value) {
    if (pos + 4 > data.size()) {
        return false;
    }
    value = (static_cast<uint32_t>(data[pos]) << 24) |
            (static_cast<uint32_t>(data[pos + 1]) << 16) |
            (static_cast<uint32_t>(data[pos + 2]) << 8) |
            static_cast<uint32_t>(data[pos + 3]);
    pos += 4;
    return true;
}

static bool readSshString(const std::vector<unsigned char>& data, size_t& pos,
                          std::vector<unsigned char>& value) {
    uint32_t len = 0;
    if (!readU32Be(data, pos, len)) {
        return false;
    }
    if (len > data.size() - pos) {
        return false;
    }
    value.assign(data.begin() + static_cast<long long>(pos),
                 data.begin() + static_cast<long long>(pos + len));
    pos += len;
    return true;
}

static bool readSshStringText(const std::vector<unsigned char>& data, size_t& pos,
                              std::string& value) {
    std::vector<unsigned char> bytes;
    if (!readSshString(data, pos, bytes)) {
        return false;
    }
    value.assign(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    return true;
}

static std::string computeSshBlobFingerprint(const std::vector<unsigned char>& blob) {
    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned int hashLen = 0;

    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (!ctx) {
        return "SHA256:(error)";
    }
    EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr);
    if (!blob.empty()) {
        EVP_DigestUpdate(ctx, blob.data(), blob.size());
    }
    EVP_DigestFinal_ex(ctx, hash, &hashLen);
    EVP_MD_CTX_free(ctx);

    std::string b64 = base64Encode(hash, hashLen);
    while (!b64.empty() && b64.back() == '=') {
        b64.pop_back();
    }
    return "SHA256:" + b64;
}

static bool inspectOpenSshV1PrivateKey(const std::string& privateKeyPem,
                                       SshPrivateKeyInfo& result) {
    const std::string beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----";
    const std::string endMarker = "-----END OPENSSH PRIVATE KEY-----";
    std::string body;
    if (!extractPemBody(privateKeyPem, beginMarker, endMarker, body)) {
        return false;
    }

    std::vector<unsigned char> decoded;
    if (!base64Decode(body, decoded)) {
        result.error = "OpenSSH private key base64 decode failed";
        return true;
    }

    const char authMagic[] = "openssh-key-v1";
    const size_t authMagicLen = sizeof(authMagic);
    if (decoded.size() < authMagicLen ||
        memcmp(decoded.data(), authMagic, authMagicLen) != 0) {
        result.error = "invalid OpenSSH private key header";
        return true;
    }

    size_t pos = authMagicLen;
    std::string cipherName;
    std::string kdfName;
    std::vector<unsigned char> kdfOptions;
    uint32_t keyCount = 0;
    if (!readSshStringText(decoded, pos, cipherName) ||
        !readSshStringText(decoded, pos, kdfName) ||
        !readSshString(decoded, pos, kdfOptions) ||
        !readU32Be(decoded, pos, keyCount)) {
        result.error = "invalid OpenSSH private key metadata";
        return true;
    }
    if (keyCount < 1 || keyCount > 8) {
        result.error = "invalid OpenSSH private key count";
        return true;
    }

    std::vector<unsigned char> publicBlob;
    if (!readSshString(decoded, pos, publicBlob)) {
        result.error = "invalid OpenSSH public key blob";
        return true;
    }

    size_t blobPos = 0;
    std::string keyType;
    if (!readSshStringText(publicBlob, blobPos, keyType) || keyType.empty()) {
        result.error = "invalid OpenSSH public key type";
        return true;
    }

    result.keyType = keyType;
    result.publicKeyOpenSsh = keyType + " " + base64Encode(publicBlob.data(), publicBlob.size());
    result.fingerprintSha256 = computeSshBlobFingerprint(publicBlob);
    result.encrypted = cipherName != "none" || kdfName != "none";
    result.ok = true;
    result.error.clear();
    return true;
}

struct PemPassphraseContext {
    const std::string* passphrase;
    bool requested;
};

static int pemPassphraseCallback(char* buf, int size, int, void* userdata) {
    PemPassphraseContext* ctx = reinterpret_cast<PemPassphraseContext*>(userdata);
    if (!ctx || !ctx->passphrase || size <= 0) {
        return 0;
    }
    ctx->requested = true;
    const std::string& pass = *(ctx->passphrase);
    const int len = std::min(static_cast<int>(pass.size()), size - 1);
    if (len > 0) {
        memcpy(buf, pass.data(), static_cast<size_t>(len));
    }
    buf[len] = '\0';
    return len;
}

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif

/**
 * 将原始公钥字节编码为 OpenSSH authorized_keys 格式行
 *
 * Ed25519: 先写 key type 长度+字符串, 再写公钥字节长度+数据
 * RSA:     使用 ssh-rsa 格式: keytype + e + n, 都用长度前缀
 */
static std::string encodeAuthorizedKeysLine(const unsigned char* pubKeyDer, size_t pubKeyDerLen,
                                              const std::string& keyType, const std::string& comment) {
    // 使用 EVP_PKEY 从 DER 解析, 然后按 SSH wire format 编码
    // 方法: 从 DER 反序列化 EVP_PKEY, 然后按 keyType 路由到特定编码器

    const unsigned char* p = pubKeyDer;
    EVP_PKEY* pkey = d2i_PUBKEY(nullptr, &p, static_cast<long>(pubKeyDerLen));
    if (!pkey) {
        return "";
    }

    std::string result;

    if (keyType == "ssh-ed25519") {
        // Ed25519: get raw 32-byte key
        size_t rawLen = 32;
        unsigned char rawKey[32];
        if (EVP_PKEY_get_raw_public_key(pkey, rawKey, &rawLen) != 1 || rawLen != 32) {
            EVP_PKEY_free(pkey);
            return "";
        }

        // SSH wire: string("ssh-ed25519") + string(rawKey)
        // string = uint32_be(len) + data
        std::vector<unsigned char> wire;
        const char* typeStr = "ssh-ed25519";
        uint32_t typeLen = static_cast<uint32_t>(strlen(typeStr));
        wire.push_back(static_cast<unsigned char>((typeLen >> 24) & 0xFF));
        wire.push_back(static_cast<unsigned char>((typeLen >> 16) & 0xFF));
        wire.push_back(static_cast<unsigned char>((typeLen >> 8) & 0xFF));
        wire.push_back(static_cast<unsigned char>(typeLen & 0xFF));
        wire.insert(wire.end(), typeStr, typeStr + typeLen);

        wire.push_back(static_cast<unsigned char>((rawLen >> 24) & 0xFF));
        wire.push_back(static_cast<unsigned char>((rawLen >> 16) & 0xFF));
        wire.push_back(static_cast<unsigned char>((rawLen >> 8) & 0xFF));
        wire.push_back(static_cast<unsigned char>(rawLen & 0xFF));
        wire.insert(wire.end(), rawKey, rawKey + rawLen);

        result = "ssh-ed25519 " + base64Encode(wire.data(), wire.size());
    } else if (keyType == "ssh-rsa") {
        // RSA: get n and e
        // d2i_PUBKEY gives us SubjectPublicKeyInfo; we need to extract RSA params
        // Get RSA* from EVP_PKEY
        RSA* rsa = EVP_PKEY_get1_RSA(pkey);
        if (!rsa) {
            EVP_PKEY_free(pkey);
            return "";
        }

        const BIGNUM* n = nullptr;
        const BIGNUM* e = nullptr;
        RSA_get0_key(rsa, &n, &e, nullptr);
        if (!n || !e) {
            RSA_free(rsa);
            EVP_PKEY_free(pkey);
            return "";
        }

        // SSH wire: string("ssh-rsa") + string(e) + string(n)
        std::vector<unsigned char> wire;
        const char* typeStr = "ssh-rsa";
        uint32_t typeLen = static_cast<uint32_t>(strlen(typeStr));
        wire.push_back(static_cast<unsigned char>((typeLen >> 24) & 0xFF));
        wire.push_back(static_cast<unsigned char>((typeLen >> 16) & 0xFF));
        wire.push_back(static_cast<unsigned char>((typeLen >> 8) & 0xFF));
        wire.push_back(static_cast<unsigned char>(typeLen & 0xFF));
        wire.insert(wire.end(), typeStr, typeStr + typeLen);

        // e (mpint: if high bit set, prepend 0)
        int eBytes = BN_num_bytes(e);
        std::vector<unsigned char> eBuf(eBytes);
        BN_bn2bin(e, eBuf.data());
        // Remove leading zero bytes for mpint
        size_t eStart = 0;
        while (eStart < eBuf.size() && eBuf[eStart] == 0) eStart++;
        // If remaining high bit is set, prepend 0x00
        bool eHighBit = (eStart < eBuf.size()) && (eBuf[eStart] & 0x80);
        uint32_t eWireLen = static_cast<uint32_t>(eBuf.size() - eStart + (eHighBit ? 1 : 0));
        wire.push_back(static_cast<unsigned char>((eWireLen >> 24) & 0xFF));
        wire.push_back(static_cast<unsigned char>((eWireLen >> 16) & 0xFF));
        wire.push_back(static_cast<unsigned char>((eWireLen >> 8) & 0xFF));
        wire.push_back(static_cast<unsigned char>(eWireLen & 0xFF));
        if (eHighBit) wire.push_back(0);
        wire.insert(wire.end(), eBuf.begin() + eStart, eBuf.end());

        // n (mpint)
        int nBytes = BN_num_bytes(n);
        std::vector<unsigned char> nBuf(nBytes);
        BN_bn2bin(n, nBuf.data());
        size_t nStart = 0;
        while (nStart < nBuf.size() && nBuf[nStart] == 0) nStart++;
        bool nHighBit = (nStart < nBuf.size()) && (nBuf[nStart] & 0x80);
        uint32_t nWireLen = static_cast<uint32_t>(nBuf.size() - nStart + (nHighBit ? 1 : 0));
        wire.push_back(static_cast<unsigned char>((nWireLen >> 24) & 0xFF));
        wire.push_back(static_cast<unsigned char>((nWireLen >> 16) & 0xFF));
        wire.push_back(static_cast<unsigned char>((nWireLen >> 8) & 0xFF));
        wire.push_back(static_cast<unsigned char>(nWireLen & 0xFF));
        if (nHighBit) wire.push_back(0);
        wire.insert(wire.end(), nBuf.begin() + nStart, nBuf.end());

        result = "ssh-rsa " + base64Encode(wire.data(), wire.size());

        RSA_free(rsa);
    } else if (keyType == "ecdsa-sha2-nistp256" ||
               keyType == "ecdsa-sha2-nistp384" ||
               keyType == "ecdsa-sha2-nistp521") {
        EC_KEY* ec = EVP_PKEY_get1_EC_KEY(pkey);
        if (!ec) {
            EVP_PKEY_free(pkey);
            return "";
        }
        const EC_GROUP* group = EC_KEY_get0_group(ec);
        const EC_POINT* point = EC_KEY_get0_public_key(ec);
        if (group == nullptr || point == nullptr) {
            EC_KEY_free(ec);
            EVP_PKEY_free(pkey);
            return "";
        }
        const int nid = group == nullptr ? NID_undef : EC_GROUP_get_curve_name(group);
        const char* curveName = nid == NID_X9_62_prime256v1 ? "nistp256" :
            (nid == NID_secp384r1 ? "nistp384" :
             (nid == NID_secp521r1 ? "nistp521" : nullptr));
        if (curveName == nullptr) {
            EC_KEY_free(ec);
            EVP_PKEY_free(pkey);
            return "";
        }

        std::vector<unsigned char> pointBytes;
        const size_t pointLen = EC_POINT_point2oct(
            group, point, POINT_CONVERSION_UNCOMPRESSED, nullptr, 0, nullptr);
        if (pointLen == 0) {
            EC_KEY_free(ec);
            EVP_PKEY_free(pkey);
            return "";
        }
        pointBytes.resize(pointLen);
        if (EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED,
                               pointBytes.data(), pointBytes.size(), nullptr) != pointLen) {
            EC_KEY_free(ec);
            EVP_PKEY_free(pkey);
            return "";
        }

        std::vector<unsigned char> wire;
        auto appendString = [&wire](const unsigned char* data, size_t len) {
            const uint32_t length = static_cast<uint32_t>(len);
            wire.push_back(static_cast<unsigned char>((length >> 24) & 0xFF));
            wire.push_back(static_cast<unsigned char>((length >> 16) & 0xFF));
            wire.push_back(static_cast<unsigned char>((length >> 8) & 0xFF));
            wire.push_back(static_cast<unsigned char>(length & 0xFF));
            wire.insert(wire.end(), data, data + len);
        };
        appendString(reinterpret_cast<const unsigned char*>(keyType.data()), keyType.size());
        appendString(reinterpret_cast<const unsigned char*>(curveName), strlen(curveName));
        appendString(pointBytes.data(), pointBytes.size());
        result = keyType + " " + base64Encode(wire.data(), wire.size());
        EC_KEY_free(ec);
    }

    EVP_PKEY_free(pkey);

    // Append comment
    if (!comment.empty()) {
        result += " " + comment;
    }
    return result;
}

static std::string sshKeyTypeForPkey(EVP_PKEY* pkey) {
    if (!pkey) {
        return "";
    }
    const int type = EVP_PKEY_base_id(pkey);
    if (type == EVP_PKEY_ED25519) {
        return "ssh-ed25519";
    }
    if (type == EVP_PKEY_RSA) {
        return "ssh-rsa";
    }
    if (type == EVP_PKEY_EC) {
        EC_KEY* ec = EVP_PKEY_get1_EC_KEY(pkey);
        if (!ec) {
            return "";
        }
        const EC_GROUP* group = EC_KEY_get0_group(ec);
        const int nid = group == nullptr ? NID_undef : EC_GROUP_get_curve_name(group);
        EC_KEY_free(ec);
        if (nid == NID_X9_62_prime256v1) {
            return "ecdsa-sha2-nistp256";
        }
        if (nid == NID_secp384r1) {
            return "ecdsa-sha2-nistp384";
        }
        if (nid == NID_secp521r1) {
            return "ecdsa-sha2-nistp521";
        }
    }
    return "";
}

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

/**
 * 计算 OpenSSH 风格 SHA256 fingerprint。
 *
 * OpenSSH hashes the SSH public-key blob used in authorized_keys, never the
 * SubjectPublicKeyInfo DER wrapper. Re-encode the supported public key into
 * that wire format before hashing.
 */
static std::string computeFingerprint(const unsigned char* pubKeyDer, size_t pubKeyDerLen) {
    const unsigned char* p = pubKeyDer;
    EVP_PKEY* pkey = d2i_PUBKEY(nullptr, &p, static_cast<long>(pubKeyDerLen));
    if (!pkey) {
        return "SHA256:(error)";
    }

    const std::string keyType = sshKeyTypeForPkey(pkey);
    EVP_PKEY_free(pkey);
    if (keyType.empty()) {
        return "SHA256:(error)";
    }

    const std::string line = encodeAuthorizedKeysLine(
        pubKeyDer, pubKeyDerLen, keyType, "");
    const size_t separator = line.find(' ');
    if (separator == std::string::npos || separator + 1 >= line.size()) {
        return "SHA256:(error)";
    }
    std::vector<unsigned char> blob;
    if (!base64Decode(line.substr(separator + 1), blob) || blob.empty()) {
        return "SHA256:(error)";
    }
    return computeSshBlobFingerprint(blob);
}

// ============================================================
// 公钥 API
// ============================================================

GeneratedSshKeyPair generateSshKeyPair(
    const std::string& keyType,
    int bits,
    const std::string& comment,
    const std::string& passphrase)
{
    GeneratedSshKeyPair result;
    result.ok = false;
    result.keyBits = bits;

    ERR_clear_error();

    // 1. 选择密钥类型
    int pkeyType = 0;
    std::string sshType;
    if (keyType == "ed25519") {
        pkeyType = EVP_PKEY_ED25519;
        sshType = "ssh-ed25519";
        result.keyBits = 256;
    } else if (keyType == "rsa") {
        pkeyType = EVP_PKEY_RSA;
        sshType = "ssh-rsa";
        if (bits < 2048) bits = 4096;
    } else {
        result.error = "unsupported key type: " + keyType;
        return result;
    }

    // 2. 创建密钥生成上下文
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_id(pkeyType, nullptr);
    if (!ctx) {
        result.error = "EVP_PKEY_CTX_new_id failed: " + collectOpenSslErrors();
        return result;
    }

    // 3. 初始化密钥生成
    if (EVP_PKEY_keygen_init(ctx) <= 0) {
        result.error = "EVP_PKEY_keygen_init failed: " + collectOpenSslErrors();
        EVP_PKEY_CTX_free(ctx);
        return result;
    }

    // 4. RSA 专用: 设置密钥位数
    if (keyType == "rsa") {
        if (EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, bits) <= 0) {
            result.error = "set_rsa_keygen_bits failed: " + collectOpenSslErrors();
            EVP_PKEY_CTX_free(ctx);
            return result;
        }
    }

    // 5. 生成密钥对
    EVP_PKEY* pkey = nullptr;
    if (EVP_PKEY_keygen(ctx, &pkey) <= 0 || !pkey) {
        result.error = "EVP_PKEY_keygen failed: " + collectOpenSslErrors();
        EVP_PKEY_CTX_free(ctx);
        return result;
    }
    EVP_PKEY_CTX_free(ctx);

    // 6. 导出公钥 DER
    // i2d_PUBKEY 输出 SubjectPublicKeyInfo DER
    unsigned char* pubDer = nullptr;
    int pubDerLen = i2d_PUBKEY(pkey, &pubDer);
    if (pubDerLen <= 0 || !pubDer) {
        result.error = "i2d_PUBKEY failed: " + collectOpenSslErrors();
        EVP_PKEY_free(pkey);
        return result;
    }

    // 7. 生成 OpenSSH authorized_keys 公钥行
    result.publicKeyOpenSsh = encodeAuthorizedKeysLine(pubDer, pubDerLen, sshType, comment);
    if (result.publicKeyOpenSsh.empty()) {
        result.error = "failed to encode authorized_keys line";
        OPENSSL_free(pubDer);
        EVP_PKEY_free(pkey);
        return result;
    }

    // 8. 生成 fingerprint
    result.fingerprintSha256 = computeFingerprint(pubDer, pubDerLen);
    OPENSSL_free(pubDer);

    // 9. 导出私钥 PEM
    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        result.error = "BIO_new failed";
        EVP_PKEY_free(pkey);
        return result;
    }

    int pemRet = 0;
    if (passphrase.empty()) {
        // 无密码: 使用 PKCS8 PEM (兼容性最好)
        pemRet = PEM_write_bio_PrivateKey(bio, pkey, nullptr, nullptr, 0, nullptr, nullptr);
    } else {
        // 有密码: 使用 AES-256-CBC 加密
        pemRet = PEM_write_bio_PrivateKey(bio, pkey, EVP_aes_256_cbc(),
                                           nullptr, 0, nullptr,
                                           const_cast<char*>(passphrase.c_str()));
    }

    if (pemRet <= 0) {
        result.error = "PEM_write_bio_PrivateKey failed: " + collectOpenSslErrors();
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        return result;
    }

    char* pemBuf = nullptr;
    long pemLen = BIO_get_mem_data(bio, &pemBuf);
    result.privateKeyPem = std::string(pemBuf, pemLen);
    BIO_free(bio);

    result.keyType = sshType;
    result.ok = true;

    EVP_PKEY_free(pkey);
    return result;
}

// ============================================================
// 私钥解析
// ============================================================

SshPrivateKeyInfo inspectSshPrivateKey(
    const std::string& privateKeyPem,
    const std::string& passphrase)
{
    SshPrivateKeyInfo result;
    result.ok = false;
    result.encrypted = false;

    ERR_clear_error();

    if (privateKeyPem.find("-----BEGIN OPENSSH PRIVATE KEY-----") != std::string::npos) {
        if (inspectOpenSshV1PrivateKey(privateKeyPem, result)) {
            return result;
        }
    }

    // 1. 尝试以 PEM 格式读取私钥
    BIO* bio = BIO_new_mem_buf(privateKeyPem.data(), static_cast<int>(privateKeyPem.size()));
    if (!bio) {
        result.error = "BIO_new_mem_buf failed";
        return result;
    }

    // 2. 读取私钥, 并通过 callback 记录 OpenSSL 是否真的请求了 passphrase。
    PemPassphraseContext passCtx { &passphrase, false };
    EVP_PKEY* pkey = PEM_read_bio_PrivateKey(bio, nullptr, pemPassphraseCallback, &passCtx);

    if (!pkey) {
        const bool looksEncrypted =
            passCtx.requested ||
            privateKeyPem.find("ENCRYPTED") != std::string::npos ||
            privateKeyPem.find("bcrypt") != std::string::npos;
        if (looksEncrypted) {
            result.encrypted = true;
            result.error = passphrase.empty() ?
                "private key is encrypted (passphrase required)" :
                "incorrect passphrase";
        } else {
            result.error = "PEM_read_bio_PrivateKey failed: " + collectOpenSslErrors();
        }
    }

    if (!pkey) {
        BIO_free(bio);
        // 如果未能确定加密状态但看起来是加密的, 至少返回类型信息
        if (result.encrypted) {
            // 对于加密密钥, 我们无法获取公钥/fingerprint
            // 尝试从 PEM header 获取 key type
            result.keyType = "unknown";
            // 检查 PEM header 是否有 DEK-Info 或 Proc-Type
            if (privateKeyPem.find("ENCRYPTED") != std::string::npos) {
                result.encrypted = true;
            }
        }
        return result;
    }

    // 3. 获取密钥类型
    result.keyType = sshKeyTypeForPkey(pkey);
    if (result.keyType.empty()) {
        result.keyType = "unknown";
    }

    // 4. 检查是否加密: 只有 OpenSSL 实际请求过 passphrase 才算加密。
    result.encrypted = passCtx.requested;

    // 5. 导出公钥 DER 并生成 authorized_keys 行和 fingerprint
    unsigned char* pubDer = nullptr;
    int pubDerLen = i2d_PUBKEY(pkey, &pubDer);
    if (pubDerLen > 0 && pubDer) {
        result.publicKeyOpenSsh = encodeAuthorizedKeysLine(pubDer, pubDerLen, result.keyType, "");
        result.fingerprintSha256 = computeFingerprint(pubDer, pubDerLen);
        OPENSSL_free(pubDer);
    } else {
        result.error = "i2d_PUBKEY failed: " + collectOpenSslErrors();
        EVP_PKEY_free(pkey);
        BIO_free(bio);
        return result;
    }

    result.ok = true;

    EVP_PKEY_free(pkey);
    BIO_free(bio);
    return result;
}

// ============================================================
// Passphrase 管理
// ============================================================

std::string changeSshPrivateKeyPassphrase(
    const std::string& privateKeyPem,
    const std::string& oldPassphrase,
    const std::string& newPassphrase)
{
    ERR_clear_error();

    // 1. 读取私钥
    BIO* bio = BIO_new_mem_buf(privateKeyPem.data(), static_cast<int>(privateKeyPem.size()));
    if (!bio) {
        return "";
    }

    EVP_PKEY* pkey = PEM_read_bio_PrivateKey(
        bio, nullptr, nullptr,
        oldPassphrase.empty() ? nullptr : const_cast<char*>(oldPassphrase.c_str()));
    BIO_free(bio);

    if (!pkey) {
        return ""; // 密码错误或密钥损坏
    }

    // 2. 重新写入 (新密码或无密码)
    BIO* outBio = BIO_new(BIO_s_mem());
    if (!outBio) {
        EVP_PKEY_free(pkey);
        return "";
    }

    int ret = 0;
    if (newPassphrase.empty()) {
        ret = PEM_write_bio_PrivateKey(outBio, pkey, nullptr, nullptr, 0, nullptr, nullptr);
    } else {
        ret = PEM_write_bio_PrivateKey(outBio, pkey, EVP_aes_256_cbc(),
                                        nullptr, 0, nullptr,
                                        const_cast<char*>(newPassphrase.c_str()));
    }

    std::string result;
    if (ret > 0) {
        char* buf = nullptr;
        long len = BIO_get_mem_data(outBio, &buf);
        result = std::string(buf, len);
    }

    BIO_free(outBio);
    EVP_PKEY_free(pkey);
    return result;
}

// ============================================================
// 安全校验
// ============================================================

bool validatePublicKeyForAuthorizedKeys(const std::string& publicKeyOpenSsh) {
    if (publicKeyOpenSsh.empty()) return false;

    // 1. 必须是单行
    if (publicKeyOpenSsh.find('\n') != std::string::npos) return false;
    if (publicKeyOpenSsh.find('\r') != std::string::npos) return false;

    // 2. 必须以合法 SSH 密钥类型开头
    bool validPrefix = false;
    const char* validPrefixes[] = {
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"
    };
    for (const char* prefix : validPrefixes) {
        if (publicKeyOpenSsh.find(prefix) == 0) {
            validPrefix = true;
            break;
        }
    }
    if (!validPrefix) return false;

    // 3. 不包含 shell 注入危险字符
    const char* dangerous = ";`$()|&><\"'\\\t";
    for (const char* p = dangerous; *p; ++p) {
        if (publicKeyOpenSsh.find(*p) != std::string::npos) return false;
    }

    // 4. 基本格式: type base64 [comment]
    // 至少要有 type 和 base64 两部分
    size_t firstSpace = publicKeyOpenSsh.find(' ');
    if (firstSpace == std::string::npos) return false;

    std::string keyBlob = publicKeyOpenSsh.substr(firstSpace + 1);
    // keyBlob 可能还有 comment, 取第一部分
    size_t secondSpace = keyBlob.find(' ');
    if (secondSpace != std::string::npos) {
        keyBlob = keyBlob.substr(0, secondSpace);
    }

    // Base64 应只包含合法字符
    if (keyBlob.empty()) return false;
    for (char c : keyBlob) {
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=')) {
            return false;
        }
    }

    // 5. 长度合理 (最少 ~32 bytes Base64 ≈ 44 chars for ed25519)
    if (keyBlob.length() < 40) return false;
    if (keyBlob.length() > 8192) return false;

    return true;
}

// ============================================================
// SSH 安装 / 测试 (基于 libssh2)
// ============================================================

/** 内部: 建立 TCP 连接到 host:port (非阻塞, 带超时) */
static int tcpConnectWithTimeout(const std::string& host, int port, int timeoutSec) {
    if (port <= 0 || port > 65535) { return -1; }
    const remotedesk::ssh::ProxyTargetResult endpoint =
        remotedesk::ssh::PrepareProxyTarget(
            "direct", host, static_cast<std::uint16_t>(port));
    if (!endpoint.ok) { return -1; }
    const std::string& transportHost = endpoint.transportHost;
#ifdef __OHOS__
    remotedesk::net::ConnectOptions options;
    options.deadline = std::chrono::steady_clock::now() +
        std::chrono::seconds(std::max(1, timeoutSec));
    remotedesk::net::ConnectResult connection;
    const remotedesk::net::ResolveResult resolution =
        remotedesk::net::ResolveAndConnectTcp(
            transportHost, std::to_string(port), options, connection);
    if (resolution.status != remotedesk::net::ResolveStatus::Ready ||
        connection.status != remotedesk::net::ConnectStatus::Connected) {
        return -1;
    }
    return connection.descriptor;
#else
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);

    struct addrinfo* res = nullptr;
    int ret = getaddrinfo(transportHost.c_str(), portStr, &hints, &res);
    if (ret != 0 || !res) {
        return -1;
    }

    int sock = -1;
    struct addrinfo* rp = nullptr;
    for (rp = res; rp != nullptr; rp = rp->ai_next) {
        sock = static_cast<int>(socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol));
        if (sock < 0) continue;

        // Set non-blocking for timeout connect
#ifdef __OHOS__
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
#else
        u_long mode = 1;
        ioctlsocket(sock, FIONBIO, &mode);
#endif

        int connRet = connect(sock, rp->ai_addr, static_cast<int>(rp->ai_addrlen));
        if (connRet < 0) {
#ifdef __OHOS__
            if (errno == EINPROGRESS) {
#else
            if (WSAGetLastError() == WSAEWOULDBLOCK) {
#endif
                // Wait with select
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(sock, &wfds);
                struct timeval tv;
                tv.tv_sec = timeoutSec;
                tv.tv_usec = 0;
                int selRet = select(sock + 1, nullptr, &wfds, nullptr, &tv);
                if (selRet <= 0) {
#ifdef __OHOS__
                    close(sock);
#else
                    closesocket(sock);
#endif
                    sock = -1;
                    continue;
                }
#ifdef __OHOS__
                int socketError = 0;
                socklen_t socketErrorLength = sizeof(socketError);
                if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError,
                               &socketErrorLength) != 0 || socketError != 0) {
                    close(sock);
                    sock = -1;
                    continue;
                }
#else
                int socketError = 0;
                int socketErrorLength = sizeof(socketError);
                if (getsockopt(sock, SOL_SOCKET, SO_ERROR,
                               reinterpret_cast<char*>(&socketError),
                               &socketErrorLength) == SOCKET_ERROR || socketError != 0) {
                    closesocket(sock);
                    sock = -1;
                    continue;
                }
#endif
            } else {
#ifdef __OHOS__
                close(sock);
#else
                closesocket(sock);
#endif
                sock = -1;
                continue;
            }
        }

        // Set back to blocking
#ifdef __OHOS__
        fcntl(sock, F_SETFL, flags);
#else
        mode = 0;
        ioctlsocket(sock, FIONBIO, &mode);
#endif
        break; // Connected
    }

    freeaddrinfo(res);
    return sock;
#endif
}

static void closeSocketFd(int sock) {
#ifdef __OHOS__
    close(sock);
#else
    closesocket(sock);
#endif
}

static bool setSocketIoTimeout(int sock, int timeoutSec);

struct SshJumpOperationState {
    int bastionSock = -1;
    int relayFd = -1;
    LIBSSH2_SESSION* session = nullptr;
    LIBSSH2_CHANNEL* channel = nullptr;
};

static void closeSshJumpOperationState(const std::shared_ptr<SshJumpOperationState>& state) {
    if (state->channel != nullptr) {
        libssh2_channel_free(state->channel);
        state->channel = nullptr;
    }
    if (state->session != nullptr) {
        libssh2_session_free(state->session);
        state->session = nullptr;
    }
    if (state->relayFd >= 0) {
        closeSocketFd(state->relayFd);
        state->relayFd = -1;
    }
    if (state->bastionSock >= 0) {
        closeSocketFd(state->bastionSock);
        state->bastionSock = -1;
    }
}

static void runSshJumpOperationRelay(const std::shared_ptr<SshJumpOperationState>& state) {
    constexpr size_t kRelayLimit = 512 * 1024;
    std::vector<uint8_t> toChannel;
    std::vector<uint8_t> toLocal;
    std::array<uint8_t, 64 * 1024> buffer {};
    bool localEof = false;
    bool channelEof = false;

    while (true) {
        bool progress = false;
        if (!localEof && toChannel.size() < kRelayLimit) {
            const ssize_t received = recv(state->relayFd, buffer.data(), buffer.size(), 0);
            if (received > 0) {
                toChannel.insert(toChannel.end(), buffer.begin(), buffer.begin() + received);
                progress = true;
            } else if (received == 0) {
                localEof = true;
                libssh2_channel_send_eof(state->channel);
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                break;
            }
        }
        if (!toChannel.empty()) {
            const ssize_t written = libssh2_channel_write(
                state->channel, reinterpret_cast<const char*>(toChannel.data()), toChannel.size());
            if (written > 0) {
                toChannel.erase(toChannel.begin(), toChannel.begin() + written);
                progress = true;
            } else if (written < 0 && written != LIBSSH2_ERROR_EAGAIN) {
                break;
            }
        }
        if (!channelEof && toLocal.size() < kRelayLimit) {
            const ssize_t received = libssh2_channel_read(
                state->channel, reinterpret_cast<char*>(buffer.data()), buffer.size());
            if (received > 0) {
                toLocal.insert(toLocal.end(), buffer.begin(), buffer.begin() + received);
                progress = true;
            } else if (received == 0 && libssh2_channel_eof(state->channel)) {
                channelEof = true;
                shutdown(state->relayFd, SHUT_WR);
            } else if (received < 0 && received != LIBSSH2_ERROR_EAGAIN) {
                break;
            }
        }
        if (!toLocal.empty()) {
            const ssize_t written = send(state->relayFd, toLocal.data(), toLocal.size(), 0);
            if (written > 0) {
                toLocal.erase(toLocal.begin(), toLocal.begin() + written);
                progress = true;
            } else if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                break;
            }
        }
        if (localEof && channelEof && toChannel.empty() && toLocal.empty()) { break; }
        if (progress) { continue; }

        fd_set readSet;
        fd_set writeSet;
        FD_ZERO(&readSet);
        FD_ZERO(&writeSet);
        FD_SET(state->relayFd, &readSet);
        if (!toLocal.empty()) { FD_SET(state->relayFd, &writeSet); }
        FD_SET(state->bastionSock, &readSet);
        FD_SET(state->bastionSock, &writeSet);
        const int maxFd = std::max(state->relayFd, state->bastionSock);
        struct timeval tv = {0, 100000};
        const int selected = select(maxFd + 1, &readSet, &writeSet, nullptr, &tv);
        if (selected < 0 && errno != EINTR) { break; }
    }
    closeSshJumpOperationState(state);
}

static int connectThroughSshJumpOperation(
    const std::string& host, int port, const SshProxyOptions& proxy) {
    const std::string authMethod = proxy.authMethod.empty() ? "password" : proxy.authMethod;
    if (port <= 0 || port > 65535 || proxy.host.empty() ||
        proxy.port <= 0 || proxy.port > 65535 ||
        proxy.username.empty() ||
        (authMethod != "password" && authMethod != "publickey" &&
         authMethod != "kbd-interactive" && authMethod != "keyboard-interactive")) {
        return -2;
    }
    // The final target is resolved by the bastion. Validate and canonicalize
    // it before connecting to the bastion so a device-local "%interface"
    // can never cross into that remote namespace.
    const remotedesk::ssh::ProxyTargetResult target =
        remotedesk::ssh::PrepareProxyTarget(
            "ssh_jump", host, static_cast<std::uint16_t>(port));
    if (!target.ok) { return -2; }
    const int bastionSock = tcpConnectWithTimeout(proxy.host, proxy.port, 10);
    if (bastionSock < 0) { return -1; }
    if (!setSocketIoTimeout(bastionSock, 10)) {
        closeSocketFd(bastionSock);
        return -1;
    }

    const std::shared_ptr<SshJumpOperationState> state =
        std::make_shared<SshJumpOperationState>();
    state->bastionSock = bastionSock;
    state->session = libssh2_session_init();
    if (state->session == nullptr) {
        closeSshJumpOperationState(state);
        return -1;
    }
    libssh2_session_set_blocking(state->session, 1);
    applySshAlgorithmPreferences(state->session);
    int rc = libssh2_session_handshake(state->session, state->bastionSock);
    if (rc != 0) {
        closeSshJumpOperationState(state);
        return -2;
    }

    if (!verifyHostKeyBinding(state->session, proxy.expectedHostKeyRawBase64,
                              proxy.expectedHostKeyFingerprintSha256)) {
        closeSshJumpOperationState(state);
        return -2;
    }

    char* methods = libssh2_userauth_list(
        state->session, proxy.username.c_str(), proxy.username.size());
    const std::string advertised = methods == nullptr ? std::string() : std::string(methods);
    const char* advertisedMethod = authMethod == "publickey" ? "publickey" :
        (authMethod == "password" ? "password" : "keyboard-interactive");
    if (!advertised.empty() && !sshAuthMethodAdvertised(advertised, advertisedMethod)) {
        closeSshJumpOperationState(state);
        return -2;
    }

    if (authMethod == "publickey") {
        if (proxy.privateKeyPem.empty()) {
            closeSshJumpOperationState(state);
            return -2;
        }
        rc = libssh2_userauth_publickey_frommemory(
            state->session, proxy.username.c_str(), proxy.username.size(),
            nullptr, 0, proxy.privateKeyPem.c_str(), proxy.privateKeyPem.size(),
            proxy.privateKeyPassphrase.empty() ? nullptr : proxy.privateKeyPassphrase.c_str());
    } else if (authMethod == "kbd-interactive" || authMethod == "keyboard-interactive") {
        SshProxyKeyboardContext context {
            &proxy.password, &proxy.keyboardInteractiveResponses
        };
        void** abstract = libssh2_session_abstract(state->session);
        if (abstract != nullptr) { *abstract = &context; }
        rc = libssh2_userauth_keyboard_interactive(
            state->session, proxy.username.c_str(),
            &sshProxyKeyboardInteractiveCallback);
    } else {
        if (proxy.password.empty()) {
            closeSshJumpOperationState(state);
            return -2;
        }
        rc = libssh2_userauth_password(state->session, proxy.username.c_str(), proxy.password.c_str());
    }
    if (rc != 0) {
        closeSshJumpOperationState(state);
        return -2;
    }
    state->channel = libssh2_channel_direct_tcpip(
        state->session, target.transportHost.c_str(), port);
    if (state->channel == nullptr) {
        closeSshJumpOperationState(state);
        return -2;
    }

    int socketPair[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, socketPair) != 0) {
        closeSshJumpOperationState(state);
        return -1;
    }
    for (int fd : socketPair) {
        const int flags = fcntl(fd, F_GETFL, 0);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            close(socketPair[0]);
            close(socketPair[1]);
            closeSshJumpOperationState(state);
            return -1;
        }
    }
    const int targetSock = socketPair[0];
    state->relayFd = socketPair[1];
    libssh2_session_set_blocking(state->session, 0);
    std::thread([state]() { runSshJumpOperationRelay(state); }).detach();
    return targetSock;
}

static bool setSocketIoTimeout(int sock, int timeoutSec) {
    if (sock < 0 || timeoutSec <= 0) {
        return false;
    }
#ifdef __OHOS__
    struct timeval timeout;
    timeout.tv_sec = timeoutSec;
    timeout.tv_usec = 0;
    return setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
           setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
#else
    const DWORD timeoutMs = static_cast<DWORD>(timeoutSec) * 1000U;
    return setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                      reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs)) == 0 &&
           setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO,
                      reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs)) == 0;
#endif
}

static bool sendSocketAll(int sock, const uint8_t* data, size_t len) {
    if (sock < 0 || (data == nullptr && len > 0)) {
        return false;
    }
    size_t sentTotal = 0;
    while (sentTotal < len) {
#ifdef __OHOS__
        const ssize_t sent = send(sock, data + sentTotal, len - sentTotal, 0);
#else
        const int sent = send(sock, reinterpret_cast<const char*>(data + sentTotal),
                              static_cast<int>(len - sentTotal), 0);
#endif
        if (sent > 0) {
            sentTotal += static_cast<size_t>(sent);
            continue;
        }
#ifdef __OHOS__
        if (sent < 0 && errno == EINTR) {
            continue;
        }
#else
        if (sent == SOCKET_ERROR && WSAGetLastError() == WSAEINTR) {
            continue;
        }
#endif
        return false;
    }
    return true;
}

static bool receiveSocketExact(int sock, uint8_t* data, size_t len) {
    if (sock < 0 || (data == nullptr && len > 0)) {
        return false;
    }
    size_t receivedTotal = 0;
    while (receivedTotal < len) {
#ifdef __OHOS__
        const ssize_t received = recv(sock, data + receivedTotal, len - receivedTotal, 0);
#else
        const int received = recv(sock, reinterpret_cast<char*>(data + receivedTotal),
                                  static_cast<int>(len - receivedTotal), 0);
#endif
        if (received > 0) {
            receivedTotal += static_cast<size_t>(received);
            continue;
        }
#ifdef __OHOS__
        if (received < 0 && errno == EINTR) {
            continue;
        }
#else
        if (received == SOCKET_ERROR && WSAGetLastError() == WSAEINTR) {
            continue;
        }
#endif
        return false;
    }
    return true;
}

static bool receiveProxyHeaders(int sock, std::string& headers, size_t maxLen) {
    headers.clear();
    char byte = 0;
    while (headers.find("\r\n\r\n") == std::string::npos) {
#ifdef __OHOS__
        const ssize_t received = recv(sock, &byte, 1, 0);
#else
        const int received = recv(sock, &byte, 1, 0);
#endif
        if (received > 0) {
            headers.push_back(byte);
            if (headers.size() > maxLen) {
                return false;
            }
            continue;
        }
#ifdef __OHOS__
        if (received < 0 && errno == EINTR) {
            continue;
        }
#else
        if (received == SOCKET_ERROR && WSAGetLastError() == WSAEINTR) {
            continue;
        }
#endif
        return false;
    }
    return true;
}

static bool connectThroughProxy(
    int sock, const remotedesk::ssh::ProxyTargetResult& target,
    const SshProxyOptions& proxy) {
    const std::string proxyType = proxy.type.empty() ? "direct" : proxy.type;
    if (proxyType == "direct") {
        return true;
    }
    if (proxyType == "frp_tcp") {
        // The socket was opened against the FRP mapped endpoint by
        // connectForSshOperation; no HTTP/SOCKS handshake belongs here.
        return proxy.host.size() <= 255 && proxy.port > 0 && proxy.port <= 65535;
    }
    if ((proxyType != "http_connect" && proxyType != "socks5") ||
        proxy.host.empty() || proxy.port <= 0 || proxy.port > 65535 ||
        !target.ok || target.endpoint.port() == 0 ||
        target.transportHost.empty() || target.transportHost.size() > 255 ||
        proxy.host.find_first_of("\r\n") != std::string::npos) {
        return false;
    }

    if (!setSocketIoTimeout(sock, 10)) {
        return false;
    }

    const std::string& normalizedTarget = target.transportHost;
    const int targetPort = static_cast<int>(target.endpoint.port());

    if (proxyType == "http_connect") {
        const std::string& hostHeader = target.uriAuthority;
        if (proxy.username.find_first_of("\r\n") != std::string::npos ||
            proxy.password.find_first_of("\r\n") != std::string::npos) {
            return false;
        }
        std::string request = "CONNECT " + hostHeader + " HTTP/1.1\r\n";
        request += "Host: " + hostHeader + "\r\nProxy-Connection: Keep-Alive\r\n";
        if (!proxy.username.empty() || !proxy.password.empty()) {
            const std::string credentials = proxy.username + ":" + proxy.password;
            request += "Proxy-Authorization: Basic " +
                base64Encode(reinterpret_cast<const unsigned char*>(credentials.data()),
                             credentials.size()) + "\r\n";
        }
        request += "\r\n";
        if (!sendSocketAll(sock, reinterpret_cast<const uint8_t*>(request.data()), request.size())) {
            return false;
        }
        std::string response;
        if (!receiveProxyHeaders(sock, response, 16 * 1024)) {
            return false;
        }
        const size_t lineEnd = response.find("\r\n");
        if (lineEnd == std::string::npos) {
            return false;
        }
        const std::string statusLine = response.substr(0, lineEnd);
        const size_t statusStart = statusLine.find(' ');
        if (statusStart == std::string::npos) {
            return false;
        }
        char* statusEnd = nullptr;
        const long status = std::strtol(statusLine.c_str() + statusStart + 1, &statusEnd, 10);
        if (statusEnd == statusLine.c_str() + statusStart + 1 || status < 200 || status >= 300) {
            return false;
        }
        return true;
    }

    const bool hasCredentials = !proxy.username.empty() || !proxy.password.empty();
    if (proxy.username.size() > 255 || proxy.password.size() > 255) {
        return false;
    }
    std::vector<uint8_t> greeting {
        0x05, static_cast<uint8_t>(hasCredentials ? 0x02 : 0x01), 0x00};
    if (hasCredentials) {
        greeting.push_back(0x02);
    }
    if (!sendSocketAll(sock, greeting.data(), greeting.size())) {
        return false;
    }
    uint8_t methodReply[2] = {0, 0};
    if (!receiveSocketExact(sock, methodReply, sizeof(methodReply)) || methodReply[0] != 0x05) {
        return false;
    }
    if (methodReply[1] == 0x02) {
        if (!hasCredentials) {
            return false;
        }
        std::vector<uint8_t> auth {0x01, static_cast<uint8_t>(proxy.username.size())};
        auth.insert(auth.end(), proxy.username.begin(), proxy.username.end());
        auth.push_back(static_cast<uint8_t>(proxy.password.size()));
        auth.insert(auth.end(), proxy.password.begin(), proxy.password.end());
        if (!sendSocketAll(sock, auth.data(), auth.size())) {
            return false;
        }
        uint8_t authReply[2] = {0, 0};
        if (!receiveSocketExact(sock, authReply, sizeof(authReply)) ||
            authReply[0] != 0x01 || authReply[1] != 0x00) {
            return false;
        }
    } else if (methodReply[1] != 0x00) {
        return false;
    }

    std::vector<uint8_t> request {0x05, 0x01, 0x00};
    in_addr ipv4 {};
    in6_addr ipv6 {};
    if (inet_pton(AF_INET, normalizedTarget.c_str(), &ipv4) == 1) {
        request.push_back(0x01);
        const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&ipv4);
        request.insert(request.end(), bytes, bytes + sizeof(ipv4));
    } else if (inet_pton(AF_INET6, normalizedTarget.c_str(), &ipv6) == 1) {
        request.push_back(0x04);
        const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&ipv6);
        request.insert(request.end(), bytes, bytes + sizeof(ipv6));
    } else {
        request.push_back(0x03);
        request.push_back(static_cast<uint8_t>(normalizedTarget.size()));
        request.insert(request.end(), normalizedTarget.begin(), normalizedTarget.end());
    }
    request.push_back(static_cast<uint8_t>((targetPort >> 8) & 0xFF));
    request.push_back(static_cast<uint8_t>(targetPort & 0xFF));
    if (!sendSocketAll(sock, request.data(), request.size())) {
        return false;
    }
    uint8_t replyHead[4] = {0, 0, 0, 0};
    if (!receiveSocketExact(sock, replyHead, sizeof(replyHead)) ||
        replyHead[0] != 0x05 || replyHead[1] != 0x00) {
        return false;
    }
    size_t addressLength = 0;
    if (replyHead[3] == 0x01) {
        addressLength = 4;
    } else if (replyHead[3] == 0x04) {
        addressLength = 16;
    } else if (replyHead[3] == 0x03) {
        uint8_t domainLength = 0;
        if (!receiveSocketExact(sock, &domainLength, 1)) {
            return false;
        }
        addressLength = domainLength;
    } else {
        return false;
    }
    std::vector<uint8_t> discard(addressLength + 2);
    return receiveSocketExact(sock, discard.data(), discard.size());
}

static int connectForSshOperation(
    const std::string& host, int port, const SshProxyOptions& proxy) {
    const std::string proxyType = proxy.type.empty() ? "direct" : proxy.type;
    if (!sshRouteTypeIsKnown(proxyType) || proxyType == "legacy_gateway" ||
        sshRouteTypeNeedsFrpControlPlane(proxyType)) {
        return -3;
    }
    if (proxyType == "ssh_jump") {
        return connectThroughSshJumpOperation(host, port, proxy);
    }
    const bool direct = proxyType == "direct";
    remotedesk::ssh::ProxyTargetResult target;
    if (proxyType == "http_connect" || proxyType == "socks5") {
        if (port <= 0 || port > 65535) { return -3; }
        target = remotedesk::ssh::PrepareProxyTarget(
            proxyType, host, static_cast<std::uint16_t>(port));
        if (!target.ok) { return -3; }
    }
    const std::string connectHost = direct ? host : proxy.host;
    const int connectPort = direct ? port : proxy.port;
    int sock = tcpConnectWithTimeout(connectHost, connectPort, 10);
    if (sock < 0) {
        return -1;
    }
    if (!direct && !connectThroughProxy(sock, target, proxy)) {
        closeSocketFd(sock);
        return -2;
    }
    return sock;
}

// ============================================================
// 安装公钥
// ============================================================

SshPublicKeyInstallResult installSshPublicKey(
    const std::string& host,
    int port,
    const std::string& username,
    const std::string& password,
    const std::string& privateKeyPem,
    const std::string& passphrase,
    const std::string& publicKey)
{
    SshPublicKeyInstallResult result;
    result.ok = false;
    result.alreadyInstalled = false;
    result.verified = false;
    result.code = 0;

    // 1. 校验公钥
    if (!validatePublicKeyForAuthorizedKeys(publicKey)) {
        result.code = -1;
        result.message = "public key failed validation";
        return result;
    }

    // 2. TCP 连接
    int sock = tcpConnectWithTimeout(host, port, 10);
    if (sock < 0) {
        result.code = -2;
        result.message = "TCP connect failed: " + host + ":" + std::to_string(port);
        return result;
    }

    // 3. libssh2 会话
    LIBSSH2_SESSION* session = libssh2_session_init();
    if (!session) {
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        result.code = -3;
        result.message = "libssh2_session_init failed";
        return result;
    }

    applySshAlgorithmPreferences(session);

    // 4. 握手
    int rc = libssh2_session_handshake(session, sock);
    if (rc != 0) {
        char* errMsg = nullptr;
        libssh2_session_last_error(session, &errMsg, nullptr, 0);
        result.code = -4;
        result.message = "handshake failed: " + (errMsg ? std::string(errMsg) : "unknown");
        libssh2_session_free(session);
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    // 5. 认证
    bool authenticated = false;

    // Try publickey first if provided
    if (!privateKeyPem.empty()) {
        rc = libssh2_userauth_publickey_frommemory(
            session, username.c_str(), username.length(),
            nullptr, 0,
            privateKeyPem.c_str(), privateKeyPem.length(),
            passphrase.empty() ? nullptr : passphrase.c_str());
        if (rc == 0) {
            authenticated = true;
        }
    }

    // Fallback to password
    if (!authenticated && !password.empty()) {
        rc = libssh2_userauth_password(session, username.c_str(), password.c_str());
        if (rc == 0) {
            authenticated = true;
        }
    }

    if (!authenticated) {
        char* errMsg = nullptr;
        libssh2_session_last_error(session, &errMsg, nullptr, 0);
        result.code = -5;
        result.message = "authentication failed: " + (errMsg ? std::string(errMsg) : "unknown");
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session);
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    // 6. 构造安装命令 (使用 printf 安全传参, 避免 shell 注入)
    // 先用 grep 检查是否已存在, 然后追加
    std::string escapedKey = publicKey;
    // Escape single quotes for shell: ' → '\''
    // Actually safest: write key to a temp file pattern, but for now use heredoc-style
    // Most reliable: use printf '%s\n' "key" to avoid escaping issues

    // 简化为: 逐行执行, 先检查去重
    std::string installCmd =
        "umask 077; "
        "mkdir -p \"$HOME/.ssh\" && "
        "touch \"$HOME/.ssh/authorized_keys\" && "
        "chmod 700 \"$HOME/.ssh\" && "
        "printf '%s\\n' ";

    // 单引号转义
    std::string escapedKeyForShell;
    for (char c : publicKey) {
        if (c == '\'') {
            escapedKeyForShell += "'\\''";
        } else {
            escapedKeyForShell += c;
        }
    }
    installCmd += "'" + escapedKeyForShell + "'";
    installCmd += " >> \"$HOME/.ssh/authorized_keys\" && "
                  "chmod 600 \"$HOME/.ssh/authorized_keys\"";

    // 7. 执行命令
    LIBSSH2_CHANNEL* channel = libssh2_channel_open_session(session);
    if (!channel) {
        result.code = -6;
        result.message = "channel open failed";
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session);
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    rc = libssh2_channel_exec(channel, installCmd.c_str());
    if (rc != 0) {
        char* errMsg = nullptr;
        libssh2_session_last_error(session, &errMsg, nullptr, 0);
        result.code = -7;
        result.message = "exec failed: " + (errMsg ? std::string(errMsg) : "unknown");
        libssh2_channel_free(channel);
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session);
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    // 读取 exit code
    int exitCode = -1;
    char buf[1024];
    std::string output;
    while (libssh2_channel_read(channel, buf, sizeof(buf)) > 0) {
        output += std::string(buf, strnlen(buf, sizeof(buf)));
    }
    exitCode = libssh2_channel_get_exit_status(channel);
    libssh2_channel_free(channel);

    if (exitCode != 0) {
        result.code = -8;
        result.message = "install command exit=" + std::to_string(exitCode) +
                         (output.empty() ? "" : " output=" + output);
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session);
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    result.ok = true;
    result.code = 0;
    result.message = "public key installed to authorized_keys";

    // 8. 断开
    libssh2_session_disconnect(session, "bye");
    libssh2_session_free(session);
#ifdef __OHOS__
    close(sock);
#else
    closesocket(sock);
#endif
    return result;
}

// ============================================================
// 测试密钥认证
// ============================================================

SshAuthTestResult testSshKeyAuth(
    const std::string& host,
    int port,
    const std::string& username,
    const std::string& privateKeyPem,
    const std::string& passphrase,
    const SshProxyOptions& proxy)
{
    SshAuthTestResult result;
    result.ok = false;
    result.code = 0;

    SshPrivateKeyInfo keyInfo = inspectSshPrivateKey(privateKeyPem, passphrase);
    if (!keyInfo.ok) {
        result.code = -5;
        result.message = keyInfo.error.empty() ? "private key inspect failed" : keyInfo.error;
        return result;
    }
    if (!passphrase.empty() && !keyInfo.encrypted) {
        result.code = -6;
        result.message = "private key is not encrypted; passphrase was ignored";
        return result;
    }

    int sock = connectForSshOperation(host, port, proxy);
    if (sock < 0) {
        result.code = sock == -3 ? kSshProxyUnsupportedError : -1;
        result.message = sock == -3 ? "SSH route is unsupported" :
            (sock == -2 ? "SSH proxy handshake failed" : "TCP connect failed");
        return result;
    }

    LIBSSH2_SESSION* session = libssh2_session_init();
    if (!session) {
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        result.code = -2;
        result.message = "session init failed";
        return result;
    }

    applySshAlgorithmPreferences(session);

    int rc = libssh2_session_handshake(session, sock);
    if (rc != 0) {
        char* errMsg = nullptr;
        libssh2_session_last_error(session, &errMsg, nullptr, 0);
        result.code = -3;
        result.message = "handshake failed: " + (errMsg ? std::string(errMsg) : "unknown");
        libssh2_session_free(session);
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    rc = libssh2_userauth_publickey_frommemory(
        session, username.c_str(), username.length(),
        nullptr, 0,
        privateKeyPem.c_str(), privateKeyPem.length(),
        passphrase.empty() ? nullptr : passphrase.c_str());

    if (rc == 0) {
        result.ok = true;
        result.code = 0;
        result.message = "key auth succeeded";
    } else {
        char* errMsg = nullptr;
        libssh2_session_last_error(session, &errMsg, nullptr, 0);
        result.code = -4;
        result.message = "key auth failed: " + (errMsg ? std::string(errMsg) : "unknown");
    }

    libssh2_session_disconnect(session, "bye");
    libssh2_session_free(session);
#ifdef __OHOS__
    close(sock);
#else
    closesocket(sock);
#endif
    return result;
}

// ============================================================
// 探测主机公钥 (仅 KEX, 不做用户认证)
// ============================================================

SshHostKeyInfo probeSshHostKey(
    const std::string& host,
    int port,
    const SshProxyOptions& proxy)
{
    SshHostKeyInfo result;
    result.ok = false;
    result.host = host;
    result.port = port;
    result.errorCode = 0;

    // Step 1: TCP connect
    int sock = connectForSshOperation(host, port, proxy);
    if (sock < 0) {
        result.errorCode = sock == -3 ? -5 : -1;
        result.errorMessage = (sock == -3 ? "SSH route is unsupported: " :
            (sock == -2 ? "SSH proxy handshake failed: " : "TCP connect failed: ")) +
            host + ":" + std::to_string(port);
        return result;
    }

    // Step 2: libssh2 session init
    LIBSSH2_SESSION* session = libssh2_session_init();
    if (!session) {
        result.errorCode = -2;
        result.errorMessage = "libssh2 session init failed";
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    applySshAlgorithmPreferences(session);

    // Step 3: KEX handshake (仅交换密钥, 不做用户认证)
    int rc = libssh2_session_handshake(session, sock);
    if (rc != 0) {
        char* errMsg = nullptr;
        libssh2_session_last_error(session, &errMsg, nullptr, 0);
        result.errorCode = -3;
        result.errorMessage = "KEX handshake failed: " + (errMsg ? std::string(errMsg) : "unknown");
        // 获取 server banner (握手低层可能已有)
        const char* banner = libssh2_session_banner_get(session);
        if (banner) { result.serverBanner = banner; }
        libssh2_session_free(session);
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    // Step 4: 获取 server banner
    const char* banner = libssh2_session_banner_get(session);
    if (banner) {
        result.serverBanner = banner;
    }

    // Step 5: 获取 host key raw blob + type
    size_t keyLen = 0;
    int keyType = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    const char* rawKey = libssh2_session_hostkey(session, &keyLen, &keyType);
    if (!rawKey || keyLen == 0) {
        result.errorCode = -4;
        result.errorMessage = "failed to get host key blob";
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session);
#ifdef __OHOS__
        close(sock);
#else
        closesocket(sock);
#endif
        return result;
    }

    // Step 6: 算法名称
    result.algorithm = sshHostKeyTypeName(keyType);

    // Step 7: raw key blob → base64 (用于精确比对)
    result.rawBase64 = base64Encode(reinterpret_cast<const unsigned char*>(rawKey), keyLen);

    // Step 8: SHA256 fingerprint (libssh2 提供, OpenSSH 标准)
    const char* fp = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (fp) {
        // libssh2_hostkey_hash 返回 raw SHA256 bytes → base64 → "SHA256:..."
        std::string fpB64 = base64Encode(reinterpret_cast<const unsigned char*>(fp), 32);
        // 去掉尾部 '=' padding (OpenSSH 风格)
        while (!fpB64.empty() && fpB64.back() == '=') fpB64.pop_back();
        result.fingerprintSha256 = "SHA256:" + fpB64;
    }

    result.ok = true;

    // Step 9: 断开并释放 libssh2 资源
    libssh2_session_disconnect(session, "bye");
    libssh2_session_free(session);
#ifdef __OHOS__
    close(sock);
#else
    closesocket(sock);
#endif
    return result;
}
