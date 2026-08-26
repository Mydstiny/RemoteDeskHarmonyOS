#include "MoonlightSecureIdentity.h"

#include <asset/asset_api.h>
#include <huks/native_huks_api.h>
#include <huks/native_huks_type.h>

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace remotedesk::moonlight {
namespace {

constexpr char ASSET_DOMAIN[] = "rdml.identity.asset.v1";
constexpr char ASSET_KIND_MANIFEST[] = "manifest";
constexpr char ASSET_KIND_CHUNK[] = "chunk";
constexpr char ASSET_KIND_PROBE[] = "probe";
constexpr char ASSET_ALIAS_PREFIX[] = "rdml1:";
constexpr char PROBE_OWNER_LEGACY[] = "runtime-contract";
constexpr char PROBE_OWNER_PREFIX[] = "runtime-contract:v2:";
constexpr std::array<std::uint8_t, 8> MANIFEST_MAGIC {
    'R', 'D', 'M', 'L', 'A', 'S', '2', 0,
};
constexpr std::array<std::uint8_t, 4> CHUNK_MAGIC {
    'R', 'D', 'C', '2',
};
constexpr std::uint16_t FORMAT_VERSION = 1;
constexpr std::size_t SHA256_SIZE = 32;
constexpr std::size_t CHUNK_PAYLOAD_MAX = 896;
constexpr std::size_t CERTIFICATE_DER_MAX = 8U * 1024U;
constexpr std::size_t CERTIFICATE_PEM_MAX = 12U * 1024U;
constexpr std::size_t PRIVATE_KEY_PKCS8_MAX = 16U * 1024U;
constexpr std::size_t INVENTORY_MAX = 256;
constexpr std::size_t ASSET_ALIAS_MAX = 192;
constexpr std::uint64_t PROBE_STALE_AFTER_MS = 5U * 60U * 1000U;

enum class ChunkKind : std::uint8_t {
    CertificateDer = 1,
    CertificatePem = 2,
    PrivateKeyPkcs8 = 3,
};

static_assert(OH_HUKS_MAX_KEY_ALIAS_LEN == MOONLIGHT_HUKS_ALIAS_LIMIT,
              "Moonlight identity aliases must fit the API-23 HUKS limit");
static_assert(MOONLIGHT_ASSET_SECRET_LIMIT < 1024U,
              "Asset Store accepts only sensitive data shorter than 1024 bytes");
static_assert(CHUNK_PAYLOAD_MAX + 24U + SHA256_SIZE <=
                  MOONLIGHT_ASSET_SECRET_LIMIT,
              "Chunk framing must remain below the Asset Store secret limit");
static_assert(ASSET_SYNC_TYPE_NEVER == 0,
              "Moonlight identities must never enter device synchronization");
static_assert(ASSET_TAG_SECRET != 0 && ASSET_TAG_ALIAS != 0 &&
                  ASSET_TAG_RETURN_TYPE != 0 &&
                  ASSET_TAG_REQUIRE_ATTR_ENCRYPTED != 0 &&
                  ASSET_TAG_WRAP_TYPE != 0,
              "API-23 Asset Store security tags are required");

template <typename Function>
bool linked(Function* function) noexcept {
    return function != nullptr;
}

void secureClear(void* data, std::size_t size) noexcept {
    if (data != nullptr && size != 0U) {
        OPENSSL_cleanse(data, size);
    }
}

class SecureBytes final {
public:
    SecureBytes() = default;
    ~SecureBytes() {
        clear();
    }

    SecureBytes(const SecureBytes&) = delete;
    SecureBytes& operator=(const SecureBytes&) = delete;
    SecureBytes(SecureBytes&&) = delete;
    SecureBytes& operator=(SecureBytes&&) = delete;

    void clear() noexcept {
        secureClear(bytes.data(), bytes.size());
        bytes.clear();
    }

    std::vector<std::uint8_t> release() noexcept {
        return std::move(bytes);
    }

    std::vector<std::uint8_t> bytes;
};

class AssetResults final {
public:
    AssetResults() = default;
    ~AssetResults() {
        if (results_.results != nullptr) {
            for (std::uint32_t index = 0; index < results_.count; ++index) {
                Asset_Attr* secret = OH_Asset_ParseAttr(
                    &results_.results[index], ASSET_TAG_SECRET);
                if (secret != nullptr && secret->value.blob.data != nullptr) {
                    secureClear(secret->value.blob.data,
                                secret->value.blob.size);
                }
            }
            OH_Asset_FreeResultSet(&results_);
        }
    }

    AssetResults(const AssetResults&) = delete;
    AssetResults& operator=(const AssetResults&) = delete;

    Asset_ResultSet* get() noexcept {
        return &results_;
    }

    const Asset_ResultSet& value() const noexcept {
        return results_;
    }

private:
    Asset_ResultSet results_ {};
};

struct Manifest final {
    MoonlightIdentityMetadata metadata {};
    std::uint64_t generation = 0;
    std::uint32_t certificateDerSize = 0;
    std::uint32_t certificatePemSize = 0;
    std::uint32_t privateKeySize = 0;
    std::uint16_t certificateDerChunks = 0;
    std::uint16_t certificatePemChunks = 0;
    std::uint16_t privateKeyChunks = 0;
    std::array<std::uint8_t, SHA256_SIZE> certificateDerDigest {};
    std::array<std::uint8_t, SHA256_SIZE> certificatePemDigest {};
    std::array<std::uint8_t, SHA256_SIZE> privateKeyDigest {};
};

class ByteReader final {
public:
    ByteReader(const std::uint8_t* data, std::size_t size) noexcept
        : data_(data), size_(size) {}

    bool readU8(std::uint8_t& value) noexcept {
        return read(&value, sizeof(value));
    }

    bool readU16(std::uint16_t& value) noexcept {
        std::array<std::uint8_t, 2> bytes {};
        if (!read(bytes.data(), bytes.size())) {
            return false;
        }
        value = static_cast<std::uint16_t>(bytes[0]) |
                static_cast<std::uint16_t>(bytes[1] << 8U);
        return true;
    }

    bool readU32(std::uint32_t& value) noexcept {
        std::array<std::uint8_t, 4> bytes {};
        if (!read(bytes.data(), bytes.size())) {
            return false;
        }
        value = static_cast<std::uint32_t>(bytes[0]) |
                (static_cast<std::uint32_t>(bytes[1]) << 8U) |
                (static_cast<std::uint32_t>(bytes[2]) << 16U) |
                (static_cast<std::uint32_t>(bytes[3]) << 24U);
        return true;
    }

    bool readU64(std::uint64_t& value) noexcept {
        std::array<std::uint8_t, 8> bytes {};
        if (!read(bytes.data(), bytes.size())) {
            return false;
        }
        value = 0;
        for (std::size_t index = 0; index < bytes.size(); ++index) {
            value |= static_cast<std::uint64_t>(bytes[index]) <<
                     (index * 8U);
        }
        return true;
    }

    bool read(void* output, std::size_t size) noexcept {
        if (output == nullptr || size > size_ - offset_) {
            return false;
        }
        std::memcpy(output, data_ + offset_, size);
        offset_ += size;
        return true;
    }

    bool readString(std::size_t size, std::string& output) {
        if (size > size_ - offset_) {
            return false;
        }
        output.assign(reinterpret_cast<const char*>(data_ + offset_), size);
        offset_ += size;
        return true;
    }

    const std::uint8_t* current() const noexcept {
        return data_ + offset_;
    }

    std::size_t remaining() const noexcept {
        return size_ - offset_;
    }

    bool finished() const noexcept {
        return offset_ == size_;
    }

private:
    const std::uint8_t* data_ = nullptr;
    std::size_t size_ = 0;
    std::size_t offset_ = 0;
};

void appendU8(std::vector<std::uint8_t>& output, std::uint8_t value) {
    output.push_back(value);
}

void appendU16(std::vector<std::uint8_t>& output, std::uint16_t value) {
    output.push_back(static_cast<std::uint8_t>(value & 0xffU));
    output.push_back(static_cast<std::uint8_t>((value >> 8U) & 0xffU));
}

void appendU32(std::vector<std::uint8_t>& output, std::uint32_t value) {
    for (std::size_t index = 0; index < 4U; ++index) {
        output.push_back(static_cast<std::uint8_t>(
            (value >> (index * 8U)) & 0xffU));
    }
}

void appendU64(std::vector<std::uint8_t>& output, std::uint64_t value) {
    for (std::size_t index = 0; index < 8U; ++index) {
        output.push_back(static_cast<std::uint8_t>(
            (value >> (index * 8U)) & 0xffU));
    }
}

void appendBytes(std::vector<std::uint8_t>& output,
                 const void* data,
                 std::size_t size) {
    const auto* bytes = static_cast<const std::uint8_t*>(data);
    output.insert(output.end(), bytes, bytes + size);
}

bool sha256(const std::uint8_t* data,
            std::size_t size,
            std::array<std::uint8_t, SHA256_SIZE>& digest) noexcept {
    if (data == nullptr || size == 0U ||
        size > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return false;
    }
    unsigned int digestSize = 0;
    return EVP_Digest(data, size, digest.data(), &digestSize, EVP_sha256(),
                      nullptr) == 1 && digestSize == digest.size();
}

bool sameDigest(const std::array<std::uint8_t, SHA256_SIZE>& left,
                const std::array<std::uint8_t, SHA256_SIZE>& right) noexcept {
    return CRYPTO_memcmp(left.data(), right.data(), left.size()) == 0;
}

bool isLowerHex(char value) noexcept {
    return (value >= '0' && value <= '9') ||
           (value >= 'a' && value <= 'f');
}

bool validFingerprint(const std::string& value) noexcept {
    return value.size() == 64U &&
           std::all_of(value.begin(), value.end(), isLowerHex);
}

bool validMetadata(const MoonlightIdentityMetadata& metadata) noexcept {
    return metadata.identityVersion >= 1U &&
           metadata.identityVersion <= 1000U &&
           validFingerprint(metadata.certificateSha256) &&
           validFingerprint(metadata.ownerScopeFingerprint) &&
           metadata.storageMode ==
               MoonlightIdentityStorageMode::HuksWrappedPkcs8 &&
           MoonlightSecureIdentity::validAlias(metadata.localSecureStoreRef) &&
           metadata.createdAtMs != 0U &&
           ((metadata.identityVersion == 1U && metadata.rotatedAtMs == 0U) ||
            (metadata.identityVersion > 1U &&
             metadata.rotatedAtMs >= metadata.createdAtMs));
}

bool validRecord(const MoonlightIdentityStoredRecord& record) noexcept {
    return validMetadata(record.metadata) &&
           !record.certificateDer.empty() &&
           record.certificateDer.size() <= CERTIFICATE_DER_MAX &&
           !record.certificatePem.empty() &&
           record.certificatePem.size() <= CERTIFICATE_PEM_MAX &&
           record.certificatePem.find('\r') == std::string::npos &&
           !record.privateKeyPkcs8.empty() &&
           record.privateKeyPkcs8.size() <= PRIVATE_KEY_PKCS8_MAX;
}

std::uint16_t chunkCount(std::size_t size) noexcept {
    if (size == 0U || size > PRIVATE_KEY_PKCS8_MAX) {
        return 0;
    }
    return static_cast<std::uint16_t>(
        (size + CHUNK_PAYLOAD_MAX - 1U) / CHUNK_PAYLOAD_MAX);
}

char hexDigit(std::uint8_t value) noexcept {
    return "0123456789abcdef"[value & 0x0fU];
}

std::string fixedHex(std::uint64_t value, std::size_t digits) {
    std::string output(digits, '0');
    for (std::size_t index = 0; index < digits; ++index) {
        const std::size_t target = digits - index - 1U;
        output[target] = hexDigit(static_cast<std::uint8_t>(value));
        value >>= 4U;
    }
    return output;
}

bool parseFixedHex(const std::string& value,
                   std::size_t offset,
                   std::size_t digits,
                   std::uint64_t& output) noexcept {
    if (digits == 0U || digits > 16U || offset > value.size() ||
        digits > value.size() - offset) {
        return false;
    }
    output = 0U;
    for (std::size_t index = 0; index < digits; ++index) {
        const char current = value[offset + index];
        std::uint8_t nibble = 0U;
        if (current >= '0' && current <= '9') {
            nibble = static_cast<std::uint8_t>(current - '0');
        } else if (current >= 'a' && current <= 'f') {
            nibble = static_cast<std::uint8_t>(current - 'a' + 10);
        } else {
            return false;
        }
        output = (output << 4U) | nibble;
    }
    return true;
}

std::uint64_t wallClockMilliseconds() noexcept {
    const auto count = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    return count > 0 ? static_cast<std::uint64_t>(count) : 0U;
}

std::string manifestAlias(const std::string& identityAlias) {
    return std::string(ASSET_ALIAS_PREFIX) + "m:" + identityAlias;
}

std::string chunkAlias(const std::string& identityAlias,
                       std::uint64_t generation,
                       ChunkKind kind,
                       std::uint16_t index) {
    return std::string(ASSET_ALIAS_PREFIX) + "c:" + identityAlias + ":" +
           fixedHex(generation, 16U) + ":" +
           fixedHex(static_cast<std::uint8_t>(kind), 2U) + ":" +
           fixedHex(index, 4U);
}

std::uint8_t* mutableBytes(const void* data) noexcept {
    return const_cast<std::uint8_t*>(
        static_cast<const std::uint8_t*>(data));
}

Asset_Attr blobAttr(Asset_Tag tag, const void* data, std::size_t size) noexcept {
    Asset_Attr attribute {};
    attribute.tag = static_cast<std::uint32_t>(tag);
    attribute.value.blob.size = static_cast<std::uint32_t>(size);
    attribute.value.blob.data = mutableBytes(data);
    return attribute;
}

Asset_Attr numberAttr(Asset_Tag tag, std::uint32_t value) noexcept {
    Asset_Attr attribute {};
    attribute.tag = static_cast<std::uint32_t>(tag);
    attribute.value.u32 = value;
    return attribute;
}

Asset_Attr boolAttr(Asset_Tag tag, bool value) noexcept {
    Asset_Attr attribute {};
    attribute.tag = static_cast<std::uint32_t>(tag);
    attribute.value.boolean = value;
    return attribute;
}

Asset_Attr textAttr(Asset_Tag tag, const std::string& value) noexcept {
    return blobAttr(tag, value.data(), value.size());
}

Asset_Attr literalAttr(Asset_Tag tag, const char* value) noexcept {
    return blobAttr(tag, value, std::strlen(value));
}

MoonlightIdentityBackendCode mapAssetCode(int32_t code,
                                          bool mutating) noexcept {
    switch (code) {
        case ASSET_SUCCESS:
            return MoonlightIdentityBackendCode::Ok;
        case ASSET_NOT_FOUND:
            return MoonlightIdentityBackendCode::NotFound;
        case ASSET_DUPLICATED:
            return MoonlightIdentityBackendCode::Conflict;
        case ASSET_SERVICE_UNAVAILABLE:
        case ASSET_PERMISSION_DENIED:
        case ASSET_ACCESS_DENIED:
        case ASSET_STATUS_MISMATCH:
        case ASSET_UNSUPPORTED:
            return MoonlightIdentityBackendCode::Unavailable;
        case ASSET_LIMIT_EXCEEDED:
        case ASSET_OUT_OF_MEMORY:
            return MoonlightIdentityBackendCode::Busy;
        case ASSET_DATA_CORRUPTED:
        case ASSET_CRYPTO_ERROR:
            return MoonlightIdentityBackendCode::Corrupt;
        case ASSET_IPC_ERROR:
        case ASSET_DATABASE_ERROR:
        case ASSET_FILE_OPERATION_ERROR:
            return mutating ? MoonlightIdentityBackendCode::OutcomeUnknown
                            : MoonlightIdentityBackendCode::IoFailure;
        default:
            return MoonlightIdentityBackendCode::IoFailure;
    }
}

bool blobEquals(const Asset_Attr* attribute,
                const void* expected,
                std::size_t size) noexcept {
    return attribute != nullptr && attribute->value.blob.size == size &&
           (size == 0U ||
            (attribute->value.blob.data != nullptr &&
             CRYPTO_memcmp(attribute->value.blob.data, expected, size) == 0));
}

bool resultLabelsValid(const Asset_Result& result,
                       const std::string& assetAlias,
                       const std::string& identityAlias,
                       const char* kind,
                       const std::string* owner) noexcept {
    if (!blobEquals(OH_Asset_ParseAttr(&result, ASSET_TAG_ALIAS),
                    assetAlias.data(), assetAlias.size()) ||
        !blobEquals(OH_Asset_ParseAttr(
                        &result, ASSET_TAG_DATA_LABEL_CRITICAL_1),
                    ASSET_DOMAIN, sizeof(ASSET_DOMAIN) - 1U) ||
        !blobEquals(OH_Asset_ParseAttr(
                        &result, ASSET_TAG_DATA_LABEL_CRITICAL_2),
                    identityAlias.data(), identityAlias.size()) ||
        !blobEquals(OH_Asset_ParseAttr(
                        &result, ASSET_TAG_DATA_LABEL_CRITICAL_3),
                    kind, std::strlen(kind))) {
        return false;
    }
    if (owner != nullptr &&
        !blobEquals(OH_Asset_ParseAttr(
                        &result, ASSET_TAG_DATA_LABEL_CRITICAL_4),
                    owner->data(), owner->size())) {
        return false;
    }
    const Asset_Attr* sync =
        OH_Asset_ParseAttr(&result, ASSET_TAG_SYNC_TYPE);
    const Asset_Attr* wrap =
        OH_Asset_ParseAttr(&result, ASSET_TAG_WRAP_TYPE);
    return sync != nullptr && sync->value.u32 == ASSET_SYNC_TYPE_NEVER &&
           wrap != nullptr && wrap->value.u32 == ASSET_WRAP_TYPE_NEVER;
}

MoonlightIdentityBackendCode addAsset(
    const std::string& assetAlias,
    const std::uint8_t* secret,
    std::size_t secretSize,
    const std::string& identityAlias,
    const char* kind,
    const std::string& owner,
    Asset_ConflictResolution conflict) noexcept {
    if (assetAlias.empty() || assetAlias.size() > ASSET_ALIAS_MAX ||
        secret == nullptr || secretSize == 0U ||
        secretSize > MOONLIGHT_ASSET_SECRET_LIMIT || identityAlias.empty() ||
        owner.empty()) {
        return MoonlightIdentityBackendCode::Corrupt;
    }
    std::array<Asset_Attr, 11> attributes {
        textAttr(ASSET_TAG_ALIAS, assetAlias),
        blobAttr(ASSET_TAG_SECRET, secret, secretSize),
        numberAttr(ASSET_TAG_ACCESSIBILITY,
                   ASSET_ACCESSIBILITY_DEVICE_FIRST_UNLOCKED),
        numberAttr(ASSET_TAG_SYNC_TYPE, ASSET_SYNC_TYPE_NEVER),
        numberAttr(ASSET_TAG_CONFLICT_RESOLUTION, conflict),
        literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_1, ASSET_DOMAIN),
        textAttr(ASSET_TAG_DATA_LABEL_CRITICAL_2, identityAlias),
        literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_3, kind),
        textAttr(ASSET_TAG_DATA_LABEL_CRITICAL_4, owner),
        boolAttr(ASSET_TAG_REQUIRE_ATTR_ENCRYPTED, true),
        numberAttr(ASSET_TAG_WRAP_TYPE, ASSET_WRAP_TYPE_NEVER),
    };
    return mapAssetCode(
        OH_Asset_Add(attributes.data(),
                     static_cast<std::uint32_t>(attributes.size())),
        true);
}

MoonlightIdentityBackendCode queryExactAsset(
    const std::string& assetAlias,
    const std::string& identityAlias,
    const char* kind,
    const std::string* owner,
    std::vector<std::uint8_t>& secret) {
    // Asset Store selects the credential-encrypted (CE) database from this
    // query flag. addAsset() always writes there, so every later operation
    // must select the same database rather than silently querying DE.
    std::array<Asset_Attr, 8> query {};
    std::size_t count = 0;
    query[count++] = boolAttr(ASSET_TAG_REQUIRE_ATTR_ENCRYPTED, true);
    query[count++] = textAttr(ASSET_TAG_ALIAS, assetAlias);
    query[count++] = literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_1,
                                 ASSET_DOMAIN);
    query[count++] = textAttr(ASSET_TAG_DATA_LABEL_CRITICAL_2,
                              identityAlias);
    query[count++] = literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_3, kind);
    if (owner != nullptr) {
        query[count++] = textAttr(ASSET_TAG_DATA_LABEL_CRITICAL_4, *owner);
    }
    query[count++] = numberAttr(ASSET_TAG_RETURN_TYPE, ASSET_RETURN_ALL);
    query[count++] = numberAttr(ASSET_TAG_RETURN_LIMIT, 2U);

    AssetResults results;
    const MoonlightIdentityBackendCode code = mapAssetCode(
        OH_Asset_Query(query.data(), static_cast<std::uint32_t>(count),
                       results.get()),
        false);
    if (code != MoonlightIdentityBackendCode::Ok) {
        return code;
    }
    if (results.value().count != 1U || results.value().results == nullptr) {
        return MoonlightIdentityBackendCode::Corrupt;
    }
    const Asset_Result& result = results.value().results[0];
    if (!resultLabelsValid(result, assetAlias, identityAlias, kind, owner)) {
        return MoonlightIdentityBackendCode::Corrupt;
    }
    const Asset_Attr* storedSecret =
        OH_Asset_ParseAttr(&result, ASSET_TAG_SECRET);
    if (storedSecret == nullptr || storedSecret->value.blob.data == nullptr ||
        storedSecret->value.blob.size == 0U ||
        storedSecret->value.blob.size > MOONLIGHT_ASSET_SECRET_LIMIT) {
        return MoonlightIdentityBackendCode::Corrupt;
    }
    secret.assign(storedSecret->value.blob.data,
                  storedSecret->value.blob.data +
                      storedSecret->value.blob.size);
    return MoonlightIdentityBackendCode::Ok;
}

MoonlightIdentityBackendCode removeExactAsset(
    const std::string& assetAlias,
    const std::string& identityAlias) noexcept {
    const std::array<Asset_Attr, 4> query {
        boolAttr(ASSET_TAG_REQUIRE_ATTR_ENCRYPTED, true),
        textAttr(ASSET_TAG_ALIAS, assetAlias),
        literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_1, ASSET_DOMAIN),
        textAttr(ASSET_TAG_DATA_LABEL_CRITICAL_2, identityAlias),
    };
    return mapAssetCode(
        OH_Asset_Remove(query.data(),
                        static_cast<std::uint32_t>(query.size())),
        true);
}

MoonlightIdentityBackendCode removeIdentityAssets(
    const std::string& identityAlias) noexcept {
    const std::array<Asset_Attr, 3> query {
        boolAttr(ASSET_TAG_REQUIRE_ATTR_ENCRYPTED, true),
        literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_1, ASSET_DOMAIN),
        textAttr(ASSET_TAG_DATA_LABEL_CRITICAL_2, identityAlias),
    };
    return mapAssetCode(
        OH_Asset_Remove(query.data(),
                        static_cast<std::uint32_t>(query.size())),
        true);
}

MoonlightIdentityBackendCode removeLegacyRuntimeProbeAssets() noexcept {
    const std::array<Asset_Attr, 4> query {
        boolAttr(ASSET_TAG_REQUIRE_ATTR_ENCRYPTED, true),
        literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_1, ASSET_DOMAIN),
        literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_3, ASSET_KIND_PROBE),
        literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_4, PROBE_OWNER_LEGACY),
    };
    return mapAssetCode(
        OH_Asset_Remove(query.data(),
                        static_cast<std::uint32_t>(query.size())),
        true);
}

MoonlightIdentityBackendCode removeStaleRuntimeProbeAssets(
    std::uint64_t nowMs) {
    if (nowMs == 0U) {
        return MoonlightIdentityBackendCode::IoFailure;
    }
    const MoonlightIdentityBackendCode legacy =
        removeLegacyRuntimeProbeAssets();
    if (legacy != MoonlightIdentityBackendCode::Ok &&
        legacy != MoonlightIdentityBackendCode::NotFound) {
        return legacy;
    }

    for (;;) {
        std::vector<std::pair<std::string, std::string>> stale;
        const std::array<Asset_Attr, 5> query {
            boolAttr(ASSET_TAG_REQUIRE_ATTR_ENCRYPTED, true),
            literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_1, ASSET_DOMAIN),
            literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_3, ASSET_KIND_PROBE),
            // Asset Store rejects plaintext-return queries without an exact
            // alias. Cleanup only needs labels, so enumerate attributes and
            // keep secret access confined to exact-alias queries.
            numberAttr(ASSET_TAG_RETURN_TYPE, ASSET_RETURN_ATTRIBUTES),
            numberAttr(ASSET_TAG_RETURN_LIMIT,
                       static_cast<std::uint32_t>(INVENTORY_MAX + 1U)),
        };
        AssetResults results;
        const MoonlightIdentityBackendCode queried = mapAssetCode(
            OH_Asset_Query(query.data(),
                           static_cast<std::uint32_t>(query.size()),
                           results.get()),
            false);
        if (queried == MoonlightIdentityBackendCode::NotFound) {
            return MoonlightIdentityBackendCode::Ok;
        }
        if (queried != MoonlightIdentityBackendCode::Ok) {
            return queried;
        }
        if (results.value().count > INVENTORY_MAX + 1U ||
            (results.value().count != 0U &&
             results.value().results == nullptr)) {
            return MoonlightIdentityBackendCode::Corrupt;
        }

        const std::string ownerPrefix(PROBE_OWNER_PREFIX);
        for (std::uint32_t index = 0U; index < results.value().count;
             ++index) {
            const Asset_Result& result = results.value().results[index];
            const Asset_Attr* aliasAttr =
                OH_Asset_ParseAttr(&result, ASSET_TAG_ALIAS);
            const Asset_Attr* identityAttr = OH_Asset_ParseAttr(
                &result, ASSET_TAG_DATA_LABEL_CRITICAL_2);
            const Asset_Attr* ownerAttr = OH_Asset_ParseAttr(
                &result, ASSET_TAG_DATA_LABEL_CRITICAL_4);
            if (aliasAttr == nullptr || identityAttr == nullptr ||
                ownerAttr == nullptr || aliasAttr->value.blob.data == nullptr ||
                identityAttr->value.blob.data == nullptr ||
                ownerAttr->value.blob.data == nullptr ||
                aliasAttr->value.blob.size == 0U ||
                aliasAttr->value.blob.size > ASSET_ALIAS_MAX ||
                identityAttr->value.blob.size == 0U ||
                identityAttr->value.blob.size > ASSET_ALIAS_MAX ||
                ownerAttr->value.blob.size <= ownerPrefix.size()) {
                return MoonlightIdentityBackendCode::Corrupt;
            }
            const std::string assetAlias(
                reinterpret_cast<const char*>(aliasAttr->value.blob.data),
                aliasAttr->value.blob.size);
            const std::string identityAlias(
                reinterpret_cast<const char*>(identityAttr->value.blob.data),
                identityAttr->value.blob.size);
            const std::string owner(
                reinterpret_cast<const char*>(ownerAttr->value.blob.data),
                ownerAttr->value.blob.size);
            const std::size_t timestampOffset = ownerPrefix.size();
            std::uint64_t createdAtMs = 0U;
            const bool currentFormat =
                owner.size() == ownerPrefix.size() + 16U + 1U + 16U &&
                owner.compare(0U, ownerPrefix.size(), ownerPrefix) == 0 &&
                owner[timestampOffset + 16U] == ':' &&
                parseFixedHex(owner, timestampOffset, 16U, createdAtMs);
            if (!currentFormat ||
                !resultLabelsValid(result, assetAlias, identityAlias,
                                   ASSET_KIND_PROBE, &owner)) {
                return MoonlightIdentityBackendCode::Corrupt;
            }
            if (nowMs >= createdAtMs &&
                nowMs - createdAtMs >= PROBE_STALE_AFTER_MS) {
                stale.emplace_back(assetAlias, identityAlias);
            }
        }
        if (stale.empty()) {
            return MoonlightIdentityBackendCode::Ok;
        }
        // Deleting at least one record guarantees progress. Requery from the
        // beginning so an arbitrarily large crashed-probe backlog is drained
        // in bounded Asset Store batches instead of becoming unrecoverable.
        for (const auto& item : stale) {
            const MoonlightIdentityBackendCode removed =
                removeExactAsset(item.first, item.second);
            if (removed != MoonlightIdentityBackendCode::Ok &&
                removed != MoonlightIdentityBackendCode::NotFound) {
                return removed;
            }
        }
    }
}

bool randomGeneration(std::uint64_t& generation) noexcept {
    generation = 0;
    return RAND_bytes(reinterpret_cast<unsigned char*>(&generation),
                      sizeof(generation)) == 1 &&
           generation != 0U;
}

bool serializeManifest(const MoonlightIdentityStoredRecord& record,
                       std::uint64_t generation,
                       SecureBytes& encoded,
                       Manifest& manifest) {
    manifest.metadata = record.metadata;
    manifest.generation = generation;
    manifest.certificateDerSize =
        static_cast<std::uint32_t>(record.certificateDer.size());
    manifest.certificatePemSize =
        static_cast<std::uint32_t>(record.certificatePem.size());
    manifest.privateKeySize =
        static_cast<std::uint32_t>(record.privateKeyPkcs8.size());
    manifest.certificateDerChunks = chunkCount(record.certificateDer.size());
    manifest.certificatePemChunks = chunkCount(record.certificatePem.size());
    manifest.privateKeyChunks = chunkCount(record.privateKeyPkcs8.size());
    if (manifest.certificateDerChunks == 0U ||
        manifest.certificatePemChunks == 0U ||
        manifest.privateKeyChunks == 0U ||
        !sha256(record.certificateDer.data(), record.certificateDer.size(),
                manifest.certificateDerDigest) ||
        !sha256(reinterpret_cast<const std::uint8_t*>(
                    record.certificatePem.data()),
                record.certificatePem.size(),
                manifest.certificatePemDigest) ||
        !sha256(record.privateKeyPkcs8.data(), record.privateKeyPkcs8.size(),
                manifest.privateKeyDigest)) {
        return false;
    }

    std::vector<std::uint8_t>& output = encoded.bytes;
    output.reserve(512U);
    appendBytes(output, MANIFEST_MAGIC.data(), MANIFEST_MAGIC.size());
    appendU16(output, FORMAT_VERSION);
    appendU16(output, 0U);
    appendU64(output, manifest.generation);
    appendU32(output, manifest.metadata.identityVersion);
    appendU64(output, manifest.metadata.createdAtMs);
    appendU64(output, manifest.metadata.rotatedAtMs);
    appendU8(output,
             static_cast<std::uint8_t>(manifest.metadata.storageMode));
    appendU8(output, 0U);
    appendU16(output, 0U);
    appendU32(output, manifest.certificateDerSize);
    appendU32(output, manifest.certificatePemSize);
    appendU32(output, manifest.privateKeySize);
    appendU16(output, manifest.certificateDerChunks);
    appendU16(output, manifest.certificatePemChunks);
    appendU16(output, manifest.privateKeyChunks);
    appendU16(output, static_cast<std::uint16_t>(
                          manifest.metadata.ownerScopeFingerprint.size()));
    appendU16(output, static_cast<std::uint16_t>(
                          manifest.metadata.certificateSha256.size()));
    appendU16(output, static_cast<std::uint16_t>(
                          manifest.metadata.localSecureStoreRef.size()));
    appendBytes(output, manifest.certificateDerDigest.data(),
                manifest.certificateDerDigest.size());
    appendBytes(output, manifest.certificatePemDigest.data(),
                manifest.certificatePemDigest.size());
    appendBytes(output, manifest.privateKeyDigest.data(),
                manifest.privateKeyDigest.size());
    appendBytes(output, manifest.metadata.ownerScopeFingerprint.data(),
                manifest.metadata.ownerScopeFingerprint.size());
    appendBytes(output, manifest.metadata.certificateSha256.data(),
                manifest.metadata.certificateSha256.size());
    appendBytes(output, manifest.metadata.localSecureStoreRef.data(),
                manifest.metadata.localSecureStoreRef.size());
    std::array<std::uint8_t, SHA256_SIZE> digest {};
    if (!sha256(output.data(), output.size(), digest)) {
        return false;
    }
    appendBytes(output, digest.data(), digest.size());
    secureClear(digest.data(), digest.size());
    return output.size() <= MOONLIGHT_ASSET_SECRET_LIMIT;
}

bool parseManifest(const std::uint8_t* data,
                   std::size_t size,
                   Manifest& manifest) {
    if (data == nullptr || size <= SHA256_SIZE ||
        size > MOONLIGHT_ASSET_SECRET_LIMIT) {
        return false;
    }
    std::array<std::uint8_t, SHA256_SIZE> actualDigest {};
    if (!sha256(data, size - SHA256_SIZE, actualDigest) ||
        CRYPTO_memcmp(actualDigest.data(), data + size - SHA256_SIZE,
                      SHA256_SIZE) != 0) {
        secureClear(actualDigest.data(), actualDigest.size());
        return false;
    }
    secureClear(actualDigest.data(), actualDigest.size());

    ByteReader reader(data, size - SHA256_SIZE);
    std::array<std::uint8_t, MANIFEST_MAGIC.size()> magic {};
    std::uint16_t version = 0;
    std::uint16_t reserved16 = 0;
    std::uint8_t storageMode = 0;
    std::uint8_t reserved8 = 0;
    std::uint16_t ownerSize = 0;
    std::uint16_t certificateHashSize = 0;
    std::uint16_t aliasSize = 0;
    if (!reader.read(magic.data(), magic.size()) || magic != MANIFEST_MAGIC ||
        !reader.readU16(version) || version != FORMAT_VERSION ||
        !reader.readU16(reserved16) || reserved16 != 0U ||
        !reader.readU64(manifest.generation) || manifest.generation == 0U ||
        !reader.readU32(manifest.metadata.identityVersion) ||
        !reader.readU64(manifest.metadata.createdAtMs) ||
        !reader.readU64(manifest.metadata.rotatedAtMs) ||
        !reader.readU8(storageMode) ||
        !reader.readU8(reserved8) || reserved8 != 0U ||
        !reader.readU16(reserved16) || reserved16 != 0U ||
        !reader.readU32(manifest.certificateDerSize) ||
        !reader.readU32(manifest.certificatePemSize) ||
        !reader.readU32(manifest.privateKeySize) ||
        !reader.readU16(manifest.certificateDerChunks) ||
        !reader.readU16(manifest.certificatePemChunks) ||
        !reader.readU16(manifest.privateKeyChunks) ||
        !reader.readU16(ownerSize) || !reader.readU16(certificateHashSize) ||
        !reader.readU16(aliasSize) ||
        !reader.read(manifest.certificateDerDigest.data(),
                     manifest.certificateDerDigest.size()) ||
        !reader.read(manifest.certificatePemDigest.data(),
                     manifest.certificatePemDigest.size()) ||
        !reader.read(manifest.privateKeyDigest.data(),
                     manifest.privateKeyDigest.size()) ||
        ownerSize != 64U || certificateHashSize != 64U ||
        aliasSize != MOONLIGHT_HUKS_ALIAS_LIMIT ||
        !reader.readString(ownerSize,
                           manifest.metadata.ownerScopeFingerprint) ||
        !reader.readString(certificateHashSize,
                           manifest.metadata.certificateSha256) ||
        !reader.readString(aliasSize,
                           manifest.metadata.localSecureStoreRef) ||
        !reader.finished()) {
        return false;
    }
    manifest.metadata.storageMode =
        static_cast<MoonlightIdentityStorageMode>(storageMode);
    return manifest.certificateDerSize > 0U &&
           manifest.certificateDerSize <= CERTIFICATE_DER_MAX &&
           manifest.certificatePemSize > 0U &&
           manifest.certificatePemSize <= CERTIFICATE_PEM_MAX &&
           manifest.privateKeySize > 0U &&
           manifest.privateKeySize <= PRIVATE_KEY_PKCS8_MAX &&
           manifest.certificateDerChunks ==
               chunkCount(manifest.certificateDerSize) &&
           manifest.certificatePemChunks ==
               chunkCount(manifest.certificatePemSize) &&
           manifest.privateKeyChunks == chunkCount(manifest.privateKeySize) &&
           validMetadata(manifest.metadata);
}

bool encodeChunk(ChunkKind kind,
                 std::uint64_t generation,
                 std::uint16_t index,
                 std::uint16_t count,
                 const std::uint8_t* payload,
                 std::size_t payloadSize,
                 SecureBytes& encoded) {
    if (generation == 0U || index >= count || payload == nullptr ||
        payloadSize == 0U || payloadSize > CHUNK_PAYLOAD_MAX) {
        return false;
    }
    std::vector<std::uint8_t>& output = encoded.bytes;
    output.reserve(24U + payloadSize + SHA256_SIZE);
    appendBytes(output, CHUNK_MAGIC.data(), CHUNK_MAGIC.size());
    appendU16(output, FORMAT_VERSION);
    appendU8(output, static_cast<std::uint8_t>(kind));
    appendU8(output, 0U);
    appendU64(output, generation);
    appendU16(output, index);
    appendU16(output, count);
    appendU16(output, static_cast<std::uint16_t>(payloadSize));
    appendU16(output, 0U);
    appendBytes(output, payload, payloadSize);
    std::array<std::uint8_t, SHA256_SIZE> digest {};
    if (!sha256(output.data(), output.size(), digest)) {
        return false;
    }
    appendBytes(output, digest.data(), digest.size());
    secureClear(digest.data(), digest.size());
    return output.size() <= MOONLIGHT_ASSET_SECRET_LIMIT;
}

bool appendDecodedChunk(const std::uint8_t* encoded,
                        std::size_t encodedSize,
                        ChunkKind expectedKind,
                        std::uint64_t expectedGeneration,
                        std::uint16_t expectedIndex,
                        std::uint16_t expectedCount,
                        std::size_t expectedPayloadSize,
                        std::vector<std::uint8_t>& output) {
    if (encoded == nullptr || encodedSize <= SHA256_SIZE ||
        encodedSize > MOONLIGHT_ASSET_SECRET_LIMIT) {
        return false;
    }
    std::array<std::uint8_t, SHA256_SIZE> digest {};
    if (!sha256(encoded, encodedSize - SHA256_SIZE, digest) ||
        CRYPTO_memcmp(digest.data(), encoded + encodedSize - SHA256_SIZE,
                      SHA256_SIZE) != 0) {
        secureClear(digest.data(), digest.size());
        return false;
    }
    secureClear(digest.data(), digest.size());

    ByteReader reader(encoded, encodedSize - SHA256_SIZE);
    std::array<std::uint8_t, CHUNK_MAGIC.size()> magic {};
    std::uint16_t version = 0;
    std::uint8_t kind = 0;
    std::uint8_t reserved8 = 0;
    std::uint64_t generation = 0;
    std::uint16_t index = 0;
    std::uint16_t count = 0;
    std::uint16_t payloadSize = 0;
    std::uint16_t reserved16 = 0;
    if (!reader.read(magic.data(), magic.size()) || magic != CHUNK_MAGIC ||
        !reader.readU16(version) || version != FORMAT_VERSION ||
        !reader.readU8(kind) ||
        !reader.readU8(reserved8) || reserved8 != 0U ||
        !reader.readU64(generation) ||
        !reader.readU16(index) || !reader.readU16(count) ||
        !reader.readU16(payloadSize) ||
        !reader.readU16(reserved16) || reserved16 != 0U ||
        kind != static_cast<std::uint8_t>(expectedKind) ||
        generation != expectedGeneration || index != expectedIndex ||
        count != expectedCount || payloadSize != expectedPayloadSize ||
        reader.remaining() != payloadSize ||
        output.size() > output.max_size() - payloadSize) {
        return false;
    }
    output.insert(output.end(), reader.current(),
                  reader.current() + payloadSize);
    return true;
}

MoonlightIdentityBackendCode readManifest(const std::string& identityAlias,
                                          Manifest& manifest) {
    SecureBytes encoded;
    const MoonlightIdentityBackendCode code = queryExactAsset(
        manifestAlias(identityAlias), identityAlias, ASSET_KIND_MANIFEST,
        nullptr, encoded.bytes);
    if (code != MoonlightIdentityBackendCode::Ok) {
        return code;
    }
    if (!parseManifest(encoded.bytes.data(), encoded.bytes.size(), manifest) ||
        manifest.metadata.localSecureStoreRef != identityAlias) {
        return MoonlightIdentityBackendCode::Corrupt;
    }
    return MoonlightIdentityBackendCode::Ok;
}

MoonlightIdentityBackendCode writeChunks(
    const std::string& identityAlias,
    const std::string& owner,
    ChunkKind kind,
    std::uint64_t generation,
    const std::uint8_t* data,
    std::size_t size,
    std::uint16_t count,
    std::vector<std::string>& writtenAliases) {
    for (std::uint16_t index = 0; index < count; ++index) {
        const std::size_t offset =
            static_cast<std::size_t>(index) * CHUNK_PAYLOAD_MAX;
        const std::size_t payloadSize =
            std::min(CHUNK_PAYLOAD_MAX, size - offset);
        SecureBytes encoded;
        if (!encodeChunk(kind, generation, index, count, data + offset,
                         payloadSize, encoded)) {
            return MoonlightIdentityBackendCode::Corrupt;
        }
        std::string alias = chunkAlias(identityAlias, generation, kind, index);
        const MoonlightIdentityBackendCode code = addAsset(
            alias, encoded.bytes.data(), encoded.bytes.size(), identityAlias,
            ASSET_KIND_CHUNK, owner, ASSET_CONFLICT_THROW_ERROR);
        if (code != MoonlightIdentityBackendCode::Ok) {
            if (code == MoonlightIdentityBackendCode::OutcomeUnknown) {
                writtenAliases.push_back(std::move(alias));
            }
            return code;
        }
        writtenAliases.push_back(std::move(alias));
    }
    return MoonlightIdentityBackendCode::Ok;
}

bool cleanupAliases(const std::vector<std::string>& aliases,
                    const std::string& identityAlias) noexcept {
    bool clean = true;
    for (const std::string& alias : aliases) {
        const MoonlightIdentityBackendCode code =
            removeExactAsset(alias, identityAlias);
        clean = clean && (code == MoonlightIdentityBackendCode::Ok ||
                          code == MoonlightIdentityBackendCode::NotFound);
    }
    return clean;
}

void cleanupGeneration(const std::string& identityAlias,
                       const Manifest& manifest) noexcept {
    try {
        for (const auto& entry : {
                 std::pair<ChunkKind, std::uint16_t> {
                     ChunkKind::CertificateDer,
                     manifest.certificateDerChunks},
                 {ChunkKind::CertificatePem,
                  manifest.certificatePemChunks},
                 {ChunkKind::PrivateKeyPkcs8, manifest.privateKeyChunks},
             }) {
            for (std::uint16_t index = 0; index < entry.second; ++index) {
                static_cast<void>(removeExactAsset(
                    chunkAlias(identityAlias, manifest.generation,
                               entry.first, index),
                    identityAlias));
            }
        }
    } catch (...) {
        // The new manifest is already committed. Old-generation cleanup is
        // best effort and erase() removes every generation by identity label.
    }
}

MoonlightIdentityBackendCode readChunks(
    const std::string& identityAlias,
    const std::string& owner,
    ChunkKind kind,
    std::uint64_t generation,
    std::size_t expectedSize,
    std::uint16_t expectedCount,
    const std::array<std::uint8_t, SHA256_SIZE>& expectedDigest,
    std::vector<std::uint8_t>& output) {
    output.clear();
    output.reserve(expectedSize);
    for (std::uint16_t index = 0; index < expectedCount; ++index) {
        SecureBytes encoded;
        const MoonlightIdentityBackendCode code = queryExactAsset(
            chunkAlias(identityAlias, generation, kind, index), identityAlias,
            ASSET_KIND_CHUNK, &owner, encoded.bytes);
        if (code != MoonlightIdentityBackendCode::Ok) {
            return code == MoonlightIdentityBackendCode::NotFound
                       ? MoonlightIdentityBackendCode::Corrupt
                       : code;
        }
        const std::size_t offset =
            static_cast<std::size_t>(index) * CHUNK_PAYLOAD_MAX;
        const std::size_t payloadSize =
            std::min(CHUNK_PAYLOAD_MAX, expectedSize - offset);
        if (!appendDecodedChunk(
                encoded.bytes.data(), encoded.bytes.size(), kind, generation,
                index, expectedCount, payloadSize, output)) {
            return MoonlightIdentityBackendCode::Corrupt;
        }
    }
    std::array<std::uint8_t, SHA256_SIZE> digest {};
    const bool valid = output.size() == expectedSize &&
                       sha256(output.data(), output.size(), digest) &&
                       sameDigest(digest, expectedDigest);
    secureClear(digest.data(), digest.size());
    return valid ? MoonlightIdentityBackendCode::Ok
                 : MoonlightIdentityBackendCode::Corrupt;
}

bool runtimeContractProbe() noexcept {
    std::array<std::uint8_t, 32> first {};
    std::array<std::uint8_t, 32> second {};
    std::string base;
    std::string assetAlias;
    bool cleanupRequired = false;
    bool added = false;
    bool ready = false;
    try {
        const std::uint64_t nowMs = wallClockMilliseconds();
        // Current owners carry creation time and randomness. Cleanup removes
        // only expired owners, never another live environment/process probe.
        if (removeStaleRuntimeProbeAssets(nowMs) !=
            MoonlightIdentityBackendCode::Ok) {
            throw 0;
        }
        std::uint64_t random = 0;
        if (!randomGeneration(random)) {
            throw 0;
        }
        const std::string timestamp = fixedHex(nowMs, 16U);
        const std::string randomText = fixedHex(random, 16U);
        base = std::string(ASSET_ALIAS_PREFIX) + "p:" + timestamp + ":" +
               randomText;
        assetAlias = base + ":record";
        const std::string owner = std::string(PROBE_OWNER_PREFIX) + timestamp +
                                  ":" + randomText;
        if (RAND_bytes(first.data(), static_cast<int>(first.size())) != 1 ||
            RAND_bytes(second.data(), static_cast<int>(second.size())) != 1) {
            throw 0;
        }
        MoonlightIdentityBackendCode code = addAsset(
            assetAlias, first.data(), first.size(), base, ASSET_KIND_PROBE,
            owner, ASSET_CONFLICT_THROW_ERROR);
        cleanupRequired = code == MoonlightIdentityBackendCode::Ok ||
                          code == MoonlightIdentityBackendCode::OutcomeUnknown;
        added = code == MoonlightIdentityBackendCode::Ok;
        SecureBytes loaded;
        if (added) {
            code = queryExactAsset(assetAlias, base, ASSET_KIND_PROBE, &owner,
                                   loaded.bytes);
        }
        if (code == MoonlightIdentityBackendCode::Ok &&
            loaded.bytes.size() == first.size() &&
            CRYPTO_memcmp(loaded.bytes.data(), first.data(), first.size()) ==
                0) {
            code = addAsset(assetAlias, second.data(), second.size(), base,
                            ASSET_KIND_PROBE, owner,
                            ASSET_CONFLICT_OVERWRITE);
        } else {
            code = MoonlightIdentityBackendCode::Corrupt;
        }
        loaded.clear();
        if (code == MoonlightIdentityBackendCode::Ok) {
            code = queryExactAsset(assetAlias, base, ASSET_KIND_PROBE, &owner,
                                   loaded.bytes);
        }
        ready = code == MoonlightIdentityBackendCode::Ok &&
                loaded.bytes.size() == second.size() &&
                CRYPTO_memcmp(loaded.bytes.data(), second.data(),
                              second.size()) == 0;
    } catch (...) {
        ready = false;
    }
    if (cleanupRequired && !assetAlias.empty()) {
        const MoonlightIdentityBackendCode removed =
            removeExactAsset(assetAlias, base);
        ready = ready && added &&
                removed == MoonlightIdentityBackendCode::Ok;
    }
    secureClear(first.data(), first.size());
    secureClear(second.data(), second.size());
    return ready;
}

class AssetStoreIdentityBackend final : public MoonlightIdentityBackend {
public:
    AssetStoreIdentityBackend() noexcept
        : runtimeReady_(runtimeContractProbe()) {}

    MoonlightIdentityCapability capability() const noexcept override {
        MoonlightIdentityCapability result;
        result.status = runtimeReady_
                            ? MoonlightIdentityCapabilityStatus::RuntimeReady
                            : MoonlightIdentityCapabilityStatus::
                                  RuntimeProofRequired;
        // The existing interface names the recoverable software-key mode
        // HuksWrappedPkcs8. API-23 Asset Store is the encrypted persistence
        // boundary here; no HUKS direct signer is advertised.
        result.storageMode = MoonlightIdentityStorageMode::HuksWrappedPkcs8;
        result.huksApiLinked = linked(&OH_Huks_GenerateKeyItem) &&
                               linked(&OH_Huks_InitSession) &&
                               linked(&OH_Huks_FinishSession);
        result.assetApiLinked = linked(&OH_Asset_Add) &&
                                linked(&OH_Asset_Query) &&
                                linked(&OH_Asset_Remove) &&
                                linked(&OH_Asset_FreeResultSet);
        result.directRsaTlsSignerReady = false;
        result.wrappedPkcs8Ready = runtimeReady_;
        result.encryptedBlobAtomic = runtimeReady_;
        result.secureBufferPageLockSupported = false;
        result.huksAliasLimit = OH_HUKS_MAX_KEY_ALIAS_LEN;
        result.assetSecretLimit = MOONLIGHT_ASSET_SECRET_LIMIT;
        return result;
    }

    MoonlightIdentityBackendLoadResult load(
        const std::string& alias) noexcept override {
        MoonlightIdentityBackendLoadResult result;
        if (!runtimeReady_) {
            return result;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!MoonlightSecureIdentity::validAlias(alias)) {
                result.code = MoonlightIdentityBackendCode::Corrupt;
                return result;
            }
            Manifest manifest;
            result.code = readManifest(alias, manifest);
            if (result.code != MoonlightIdentityBackendCode::Ok) {
                return result;
            }

            auto record = std::make_unique<MoonlightIdentityStoredRecord>();
            record->metadata = manifest.metadata;
            result.code = readChunks(
                alias, manifest.metadata.ownerScopeFingerprint,
                ChunkKind::CertificateDer, manifest.generation,
                manifest.certificateDerSize, manifest.certificateDerChunks,
                manifest.certificateDerDigest, record->certificateDer);
            if (result.code != MoonlightIdentityBackendCode::Ok) {
                return result;
            }
            SecureBytes certificatePem;
            result.code = readChunks(
                alias, manifest.metadata.ownerScopeFingerprint,
                ChunkKind::CertificatePem, manifest.generation,
                manifest.certificatePemSize, manifest.certificatePemChunks,
                manifest.certificatePemDigest, certificatePem.bytes);
            if (result.code != MoonlightIdentityBackendCode::Ok) {
                return result;
            }
            record->certificatePem.assign(
                reinterpret_cast<const char*>(certificatePem.bytes.data()),
                certificatePem.bytes.size());
            SecureBytes privateKey;
            result.code = readChunks(
                alias, manifest.metadata.ownerScopeFingerprint,
                ChunkKind::PrivateKeyPkcs8, manifest.generation,
                manifest.privateKeySize, manifest.privateKeyChunks,
                manifest.privateKeyDigest, privateKey.bytes);
            if (result.code != MoonlightIdentityBackendCode::Ok) {
                return result;
            }
            record->privateKeyPkcs8 =
                MoonlightSecureBuffer(privateKey.release());
            result.record = std::move(record);
            result.code = MoonlightIdentityBackendCode::Ok;
            return result;
        } catch (...) {
            result.record.reset();
            result.code = MoonlightIdentityBackendCode::IoFailure;
            return result;
        }
    }

    MoonlightIdentityBackendCode store(
        const MoonlightIdentityStoredRecord& record,
        bool replaceExisting) noexcept override {
        if (!runtimeReady_) {
            return MoonlightIdentityBackendCode::Unavailable;
        }
        std::vector<std::string> writtenAliases;
        const std::string* transactionAlias = nullptr;
        bool preserveWrittenGeneration = false;
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!validRecord(record)) {
                return MoonlightIdentityBackendCode::Corrupt;
            }
            const std::string& alias = record.metadata.localSecureStoreRef;
            transactionAlias = &alias;
            Manifest previous;
            const MoonlightIdentityBackendCode previousCode =
                readManifest(alias, previous);
            if ((previousCode == MoonlightIdentityBackendCode::Ok) !=
                replaceExisting) {
                return MoonlightIdentityBackendCode::Conflict;
            }
            if (previousCode != MoonlightIdentityBackendCode::Ok &&
                previousCode != MoonlightIdentityBackendCode::NotFound) {
                return previousCode;
            }
            if (replaceExisting &&
                previous.metadata.ownerScopeFingerprint !=
                    record.metadata.ownerScopeFingerprint) {
                return MoonlightIdentityBackendCode::Conflict;
            }

            std::uint64_t generation = 0;
            if (!randomGeneration(generation) ||
                (replaceExisting && generation == previous.generation)) {
                return MoonlightIdentityBackendCode::IoFailure;
            }
            SecureBytes encodedManifest;
            Manifest next;
            if (!serializeManifest(record, generation, encodedManifest, next)) {
                return MoonlightIdentityBackendCode::Corrupt;
            }

            writtenAliases.reserve(
                static_cast<std::size_t>(next.certificateDerChunks) +
                next.certificatePemChunks + next.privateKeyChunks);
            MoonlightIdentityBackendCode code = writeChunks(
                alias, record.metadata.ownerScopeFingerprint,
                ChunkKind::CertificateDer, generation,
                record.certificateDer.data(), record.certificateDer.size(),
                next.certificateDerChunks, writtenAliases);
            if (code == MoonlightIdentityBackendCode::Ok) {
                code = writeChunks(
                    alias, record.metadata.ownerScopeFingerprint,
                    ChunkKind::CertificatePem, generation,
                    reinterpret_cast<const std::uint8_t*>(
                        record.certificatePem.data()),
                    record.certificatePem.size(), next.certificatePemChunks,
                    writtenAliases);
            }
            if (code == MoonlightIdentityBackendCode::Ok) {
                code = writeChunks(
                    alias, record.metadata.ownerScopeFingerprint,
                    ChunkKind::PrivateKeyPkcs8, generation,
                    record.privateKeyPkcs8.data(),
                    record.privateKeyPkcs8.size(), next.privateKeyChunks,
                    writtenAliases);
            }
            if (code != MoonlightIdentityBackendCode::Ok) {
                const bool clean = cleanupAliases(writtenAliases, alias);
                preserveWrittenGeneration = true;
                return clean ? code
                             : MoonlightIdentityBackendCode::OutcomeUnknown;
            }

            // This single Asset add is the logical commit point. Readers can
            // see either the old manifest or this complete generation, never
            // a manifest that points at chunks still being written.
            code = addAsset(
                manifestAlias(alias), encodedManifest.bytes.data(),
                encodedManifest.bytes.size(), alias, ASSET_KIND_MANIFEST,
                record.metadata.ownerScopeFingerprint,
                replaceExisting ? ASSET_CONFLICT_OVERWRITE
                                : ASSET_CONFLICT_THROW_ERROR);
            if (code != MoonlightIdentityBackendCode::Ok) {
                if (code == MoonlightIdentityBackendCode::OutcomeUnknown) {
                    preserveWrittenGeneration = true;
                } else {
                    const bool clean = cleanupAliases(writtenAliases, alias);
                    preserveWrittenGeneration = true;
                    if (!clean) {
                        return MoonlightIdentityBackendCode::OutcomeUnknown;
                    }
                }
                return code;
            }
            preserveWrittenGeneration = true;
            if (replaceExisting) {
                cleanupGeneration(alias, previous);
            }
            return MoonlightIdentityBackendCode::Ok;
        } catch (...) {
            const bool clean = preserveWrittenGeneration ||
                               transactionAlias == nullptr ||
                               cleanupAliases(writtenAliases,
                                              *transactionAlias);
            return clean ? MoonlightIdentityBackendCode::IoFailure
                         : MoonlightIdentityBackendCode::OutcomeUnknown;
        }
    }

    MoonlightIdentityBackendCode erase(
        const std::string& alias) noexcept override {
        if (!runtimeReady_) {
            return MoonlightIdentityBackendCode::Unavailable;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!MoonlightSecureIdentity::validAlias(alias)) {
                return MoonlightIdentityBackendCode::Corrupt;
            }
            return removeIdentityAssets(alias);
        } catch (...) {
            return MoonlightIdentityBackendCode::IoFailure;
        }
    }

    MoonlightIdentityBackendListResult list(
        const std::string& ownerScopeFingerprint) noexcept override {
        MoonlightIdentityBackendListResult output;
        if (!runtimeReady_) {
            return output;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!validFingerprint(ownerScopeFingerprint)) {
                output.code = MoonlightIdentityBackendCode::Corrupt;
                return output;
            }
            constexpr std::uint32_t SNAPSHOT_ATTEMPTS = 2U;
            for (std::uint32_t attempt = 0U; attempt < SNAPSHOT_ATTEMPTS;
                 ++attempt) {
                output.records.clear();
                const std::array<Asset_Attr, 6> query {
                    boolAttr(ASSET_TAG_REQUIRE_ATTR_ENCRYPTED, true),
                    literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_1,
                                ASSET_DOMAIN),
                    literalAttr(ASSET_TAG_DATA_LABEL_CRITICAL_3,
                                ASSET_KIND_MANIFEST),
                    textAttr(ASSET_TAG_DATA_LABEL_CRITICAL_4,
                             ownerScopeFingerprint),
                    // Inventory is a two-step operation: enumerate
                    // attributes, then read each manifest by exact alias.
                    numberAttr(ASSET_TAG_RETURN_TYPE,
                               ASSET_RETURN_ATTRIBUTES),
                    numberAttr(
                        ASSET_TAG_RETURN_LIMIT,
                        static_cast<std::uint32_t>(INVENTORY_MAX + 1U)),
                };
                AssetResults results;
                output.code = mapAssetCode(
                    OH_Asset_Query(query.data(),
                                   static_cast<std::uint32_t>(query.size()),
                                   results.get()),
                    false);
                if (output.code == MoonlightIdentityBackendCode::NotFound) {
                    output.code = MoonlightIdentityBackendCode::Ok;
                    return output;
                }
                if (output.code != MoonlightIdentityBackendCode::Ok) {
                    return output;
                }
                if (results.value().count > INVENTORY_MAX ||
                    (results.value().count != 0U &&
                     results.value().results == nullptr)) {
                    output.code = MoonlightIdentityBackendCode::Corrupt;
                    return output;
                }

                bool snapshotInvalidated = false;
                std::set<std::string> aliases;
                output.records.reserve(results.value().count);
                for (std::uint32_t index = 0U;
                     index < results.value().count; ++index) {
                    const Asset_Result& result =
                        results.value().results[index];
                    const Asset_Attr* aliasAttr =
                        OH_Asset_ParseAttr(&result, ASSET_TAG_ALIAS);
                    const Asset_Attr* identityAttr = OH_Asset_ParseAttr(
                        &result, ASSET_TAG_DATA_LABEL_CRITICAL_2);
                    if (aliasAttr == nullptr || identityAttr == nullptr ||
                        aliasAttr->value.blob.data == nullptr ||
                        identityAttr->value.blob.data == nullptr ||
                        aliasAttr->value.blob.size > ASSET_ALIAS_MAX ||
                        identityAttr->value.blob.size !=
                            MOONLIGHT_HUKS_ALIAS_LIMIT) {
                        output.code = MoonlightIdentityBackendCode::Corrupt;
                        output.records.clear();
                        return output;
                    }
                    const std::string identityAlias(
                        reinterpret_cast<const char*>(
                            identityAttr->value.blob.data),
                        identityAttr->value.blob.size);
                    const std::string storedAlias(
                        reinterpret_cast<const char*>(
                            aliasAttr->value.blob.data),
                        aliasAttr->value.blob.size);
                    if (!resultLabelsValid(result, storedAlias,
                                           identityAlias,
                                           ASSET_KIND_MANIFEST,
                                           &ownerScopeFingerprint) ||
                        storedAlias != manifestAlias(identityAlias)) {
                        output.code = MoonlightIdentityBackendCode::Corrupt;
                        output.records.clear();
                        return output;
                    }

                    SecureBytes secret;
                    const MoonlightIdentityBackendCode exact =
                        queryExactAsset(storedAlias, identityAlias,
                                        ASSET_KIND_MANIFEST,
                                        &ownerScopeFingerprint,
                                        secret.bytes);
                    if (exact == MoonlightIdentityBackendCode::NotFound) {
                        snapshotInvalidated = true;
                        break;
                    }
                    if (exact != MoonlightIdentityBackendCode::Ok) {
                        output.code = exact;
                        output.records.clear();
                        return output;
                    }
                    Manifest manifest;
                    if (!parseManifest(secret.bytes.data(),
                                       secret.bytes.size(), manifest) ||
                        manifest.metadata.localSecureStoreRef !=
                            identityAlias ||
                        manifest.metadata.ownerScopeFingerprint !=
                            ownerScopeFingerprint ||
                        !aliases.insert(identityAlias).second) {
                        output.code = MoonlightIdentityBackendCode::Corrupt;
                        output.records.clear();
                        return output;
                    }
                    output.records.push_back(std::move(manifest.metadata));
                }
                if (snapshotInvalidated) {
                    output.records.clear();
                    if (attempt + 1U < SNAPSHOT_ATTEMPTS) {
                        continue;
                    }
                    output.code = MoonlightIdentityBackendCode::Busy;
                    return output;
                }
                std::sort(output.records.begin(), output.records.end(),
                          [](const MoonlightIdentityMetadata& left,
                             const MoonlightIdentityMetadata& right) {
                              return left.localSecureStoreRef <
                                     right.localSecureStoreRef;
                          });
                output.code = MoonlightIdentityBackendCode::Ok;
                return output;
            }
            output.code = MoonlightIdentityBackendCode::Busy;
            return output;
        } catch (...) {
            output.records.clear();
            output.code = MoonlightIdentityBackendCode::IoFailure;
            return output;
        }
    }

private:
    const bool runtimeReady_;
    std::mutex mutex_;
};

} // namespace

std::unique_ptr<MoonlightIdentityBackend>
createMoonlightPlatformIdentityBackend() {
    return std::make_unique<AssetStoreIdentityBackend>();
}

bool moonlightSecureIdentityPlatformCompileProbe() noexcept {
    return linked(&OH_Huks_GenerateKeyItem) &&
           linked(&OH_Huks_ExportPublicKeyItem) &&
           linked(&OH_Huks_DeleteKeyItem) && linked(&OH_Huks_InitSession) &&
           linked(&OH_Huks_UpdateSession) && linked(&OH_Huks_FinishSession) &&
           linked(&OH_Huks_AbortSession) && linked(&OH_Asset_Add) &&
           linked(&OH_Asset_Query) && linked(&OH_Asset_Remove) &&
           linked(&OH_Asset_ParseAttr) && linked(&OH_Asset_FreeResultSet);
}

} // namespace remotedesk::moonlight
