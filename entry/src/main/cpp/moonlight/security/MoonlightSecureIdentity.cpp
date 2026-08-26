#include "MoonlightSecureIdentity.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <ctime>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <utility>

#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <sys/mman.h>

namespace remotedesk::moonlight {
namespace {

constexpr char IDENTITY_ALIAS_PREFIX[] = "rdml-v1-";
constexpr char IDENTITY_ALIAS_DOMAIN[] =
    "RemoteDesk/Moonlight/IdentityAlias/v1";
constexpr char IDENTITY_COMMON_NAME[] = "NVIDIA GameStream Client";
constexpr std::size_t IDENTITY_ALIAS_DIGEST_BYTES = 28;
constexpr std::size_t IDENTITY_FINGERPRINT_LENGTH = 64;
constexpr std::size_t IDENTITY_INSTALLATION_MIN = 8;
constexpr std::size_t IDENTITY_INSTALLATION_MAX = 128;
constexpr std::size_t IDENTITY_CERT_DER_MAX = 8 * 1024;
constexpr std::size_t IDENTITY_CERT_PEM_MAX = 12 * 1024;
constexpr std::size_t IDENTITY_PKCS8_MAX = 16 * 1024;
constexpr std::size_t IDENTITY_SIGN_INPUT_MAX = 64 * 1024;
constexpr std::size_t IDENTITY_INVENTORY_MAX = 256;
constexpr std::uint64_t TWENTY_YEARS_SECONDS = 7305ULL * 24ULL * 60ULL * 60ULL;

std::atomic<std::uint64_t> g_secureCleanseCount {0};

bool defaultEntropy(std::uint8_t* output, std::size_t size) noexcept {
    return output != nullptr && size > 0U &&
           size <= static_cast<std::size_t>(std::numeric_limits<int>::max()) &&
           RAND_bytes(output, static_cast<int>(size)) == 1;
}

template <typename T, auto FreeFunction>
struct OpenSslDeleter final {
    void operator()(T* value) const noexcept {
        if (value != nullptr) {
            static_cast<void>(FreeFunction(value));
        }
    }
};

using BioPtr = std::unique_ptr<BIO, OpenSslDeleter<BIO, BIO_free>>;
using BnPtr = std::unique_ptr<BIGNUM, OpenSslDeleter<BIGNUM, BN_free>>;
using EvpKeyPtr = std::unique_ptr<EVP_PKEY, OpenSslDeleter<EVP_PKEY, EVP_PKEY_free>>;
using EvpKeyContextPtr =
    std::unique_ptr<EVP_PKEY_CTX, OpenSslDeleter<EVP_PKEY_CTX, EVP_PKEY_CTX_free>>;
using MessageDigestContextPtr =
    std::unique_ptr<EVP_MD_CTX, OpenSslDeleter<EVP_MD_CTX, EVP_MD_CTX_free>>;
using Pkcs8Ptr = std::unique_ptr<PKCS8_PRIV_KEY_INFO,
                                 OpenSslDeleter<PKCS8_PRIV_KEY_INFO,
                                                PKCS8_PRIV_KEY_INFO_free>>;
using X509Ptr = std::unique_ptr<X509, OpenSslDeleter<X509, X509_free>>;

bool isLowerHex(char value) noexcept {
    return (value >= '0' && value <= '9') ||
           (value >= 'a' && value <= 'f');
}

bool validFingerprint(const std::string& value) noexcept {
    return value.size() == IDENTITY_FINGERPRINT_LENGTH &&
           std::all_of(value.begin(), value.end(), isLowerHex);
}

bool validInstallationId(const std::string& value) noexcept {
    if (value.size() < IDENTITY_INSTALLATION_MIN ||
        value.size() > IDENTITY_INSTALLATION_MAX) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return character >= 0x21U && character <= 0x7eU;
    });
}

std::uint64_t defaultClock() noexcept {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    const auto millis =
        std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
    return millis > 0 ? static_cast<std::uint64_t>(millis) : 0;
}

std::uint64_t elapsedMillis(
    const std::chrono::steady_clock::time_point& started) noexcept {
    const auto elapsed = std::chrono::steady_clock::now() - started;
    const auto millis =
        std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();
    return millis > 0 ? static_cast<std::uint64_t>(millis) : 0;
}

std::string lowercaseHex(const std::uint8_t* bytes, std::size_t size) {
    static constexpr char HEX[] = "0123456789abcdef";
    std::string result;
    result.resize(size * 2);
    for (std::size_t index = 0; index < size; ++index) {
        result[index * 2] = HEX[(bytes[index] >> 4U) & 0x0fU];
        result[index * 2 + 1] = HEX[bytes[index] & 0x0fU];
    }
    return result;
}

bool decodeHex(const std::string& text, std::vector<std::uint8_t>& bytes) {
    if ((text.size() % 2U) != 0U ||
        !std::all_of(text.begin(), text.end(), isLowerHex)) {
        return false;
    }
    bytes.resize(text.size() / 2U);
    auto nibble = [](char character) -> std::uint8_t {
        if (character >= '0' && character <= '9') {
            return static_cast<std::uint8_t>(character - '0');
        }
        return static_cast<std::uint8_t>(character - 'a' + 10);
    };
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        bytes[index] = static_cast<std::uint8_t>(
            (nibble(text[index * 2U]) << 4U) |
            nibble(text[index * 2U + 1U]));
    }
    return true;
}

std::string maskedAlias(const std::string& alias) {
    if (!MoonlightSecureIdentity::validAlias(alias)) {
        return "invalid";
    }
    return std::string(IDENTITY_ALIAS_PREFIX) + "..." +
           alias.substr(alias.size() - 8U);
}

bool validMetadata(const MoonlightIdentityMetadata& metadata) noexcept {
    return metadata.identityVersion >= 1U &&
           metadata.identityVersion <= 1000U &&
           validFingerprint(metadata.certificateSha256) &&
           validFingerprint(metadata.ownerScopeFingerprint) &&
           (metadata.storageMode ==
                MoonlightIdentityStorageMode::HuksDirectSigner ||
            metadata.storageMode ==
                MoonlightIdentityStorageMode::HuksWrappedPkcs8) &&
           MoonlightSecureIdentity::validAlias(metadata.localSecureStoreRef) &&
           metadata.createdAtMs > 0U &&
           ((metadata.identityVersion == 1U &&
             metadata.rotatedAtMs == 0U) ||
            (metadata.identityVersion > 1U &&
             metadata.rotatedAtMs >= metadata.createdAtMs));
}

MoonlightIdentityCode mapBackendCode(MoonlightIdentityBackendCode code) noexcept {
    switch (code) {
        case MoonlightIdentityBackendCode::Ok:
            return MoonlightIdentityCode::Ok;
        case MoonlightIdentityBackendCode::NotFound:
            return MoonlightIdentityCode::NotFound;
        case MoonlightIdentityBackendCode::Busy:
            return MoonlightIdentityCode::Busy;
        case MoonlightIdentityBackendCode::Unavailable:
            return MoonlightIdentityCode::Unavailable;
        case MoonlightIdentityBackendCode::Conflict:
            return MoonlightIdentityCode::Conflict;
        case MoonlightIdentityBackendCode::Corrupt:
            return MoonlightIdentityCode::Corrupt;
        case MoonlightIdentityBackendCode::IoFailure:
            return MoonlightIdentityCode::StorageFailure;
        case MoonlightIdentityBackendCode::OutcomeUnknown:
            return MoonlightIdentityCode::StorageOutcomeUnknown;
    }
    return MoonlightIdentityCode::StorageFailure;
}

MoonlightIdentityDiagnostic diagnostic(
    MoonlightIdentityOperation operation,
    MoonlightIdentityCode code,
    MoonlightIdentityBackendCode backendCode,
    const std::string& alias,
    const std::chrono::steady_clock::time_point& started) {
    MoonlightIdentityDiagnostic result;
    result.operation = operation;
    result.code = code;
    result.backendCode = backendCode;
    result.maskedAlias = maskedAlias(alias);
    result.durationMs = elapsedMillis(started);
    return result;
}

bool digestSha256(const std::uint8_t* data,
                  std::size_t size,
                  std::array<std::uint8_t, 32>& digest) noexcept {
    unsigned int digestSize = 0;
    return EVP_Digest(data, size, digest.data(), &digestSize, EVP_sha256(),
                      nullptr) == 1 && digestSize == digest.size();
}

bool certificateFingerprint(const std::vector<std::uint8_t>& certificateDer,
                            std::string& fingerprint) noexcept {
    std::array<std::uint8_t, 32> digest {};
    if (certificateDer.empty() ||
        !digestSha256(certificateDer.data(), certificateDer.size(), digest)) {
        return false;
    }
    fingerprint = lowercaseHex(digest.data(), digest.size());
    return true;
}

bool serializeCertificate(X509* certificate,
                          std::vector<std::uint8_t>& certificateDer,
                          std::string& certificatePem) {
    const int derSize = i2d_X509(certificate, nullptr);
    if (derSize <= 0 ||
        static_cast<std::size_t>(derSize) > IDENTITY_CERT_DER_MAX) {
        return false;
    }
    certificateDer.resize(static_cast<std::size_t>(derSize));
    unsigned char* cursor = certificateDer.data();
    if (i2d_X509(certificate, &cursor) != derSize) {
        return false;
    }

    BioPtr output(BIO_new(BIO_s_mem()));
    if (!output || PEM_write_bio_X509(output.get(), certificate) != 1) {
        return false;
    }
    char* memory = nullptr;
    const long pemSize = BIO_get_mem_data(output.get(), &memory);
    if (pemSize <= 0 || memory == nullptr ||
        static_cast<std::size_t>(pemSize) > IDENTITY_CERT_PEM_MAX) {
        return false;
    }
    certificatePem.assign(memory, static_cast<std::size_t>(pemSize));
    return certificatePem.find('\r') == std::string::npos;
}

bool serializePrivateKey(EVP_PKEY* key, MoonlightSecureBuffer& privateKeyPkcs8) {
    Pkcs8Ptr pkcs8(EVP_PKEY2PKCS8(key));
    if (!pkcs8) {
        return false;
    }
    const int derSize = i2d_PKCS8_PRIV_KEY_INFO(pkcs8.get(), nullptr);
    if (derSize <= 0 ||
        static_cast<std::size_t>(derSize) > IDENTITY_PKCS8_MAX) {
        return false;
    }
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(derSize));
    unsigned char* cursor = bytes.data();
    if (i2d_PKCS8_PRIV_KEY_INFO(pkcs8.get(), &cursor) != derSize) {
        OPENSSL_cleanse(bytes.data(), bytes.size());
        return false;
    }
    privateKeyPkcs8 = MoonlightSecureBuffer(std::move(bytes));
    return true;
}

bool generateRecord(const MoonlightIdentityMetadata& metadata,
                    std::uint64_t nowMs,
                    const std::function<bool(std::uint8_t*, std::size_t)>& entropy,
                    MoonlightIdentityStoredRecord& record) {
    ERR_clear_error();
    EvpKeyContextPtr keyContext(EVP_PKEY_CTX_new_from_name(nullptr, "RSA", nullptr));
    if (!keyContext || EVP_PKEY_keygen_init(keyContext.get()) <= 0 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(keyContext.get(), 2048) <= 0) {
        return false;
    }
    EVP_PKEY* generatedKey = nullptr;
    if (EVP_PKEY_generate(keyContext.get(), &generatedKey) <= 0 ||
        generatedKey == nullptr) {
        return false;
    }
    EvpKeyPtr key(generatedKey);

    X509Ptr certificate(X509_new());
    if (!certificate || X509_set_version(certificate.get(), 2) != 1) {
        return false;
    }

    std::array<std::uint8_t, 8> serialBytes {};
    bool entropyReady = false;
    try {
        entropyReady = entropy && entropy(serialBytes.data(), serialBytes.size());
    } catch (...) {
        entropyReady = false;
    }
    if (!entropyReady) {
        OPENSSL_cleanse(serialBytes.data(), serialBytes.size());
        return false;
    }
    serialBytes[0] &= 0x7fU;
    if (std::all_of(serialBytes.begin(), serialBytes.end(),
                    [](std::uint8_t value) { return value == 0U; })) {
        serialBytes.back() = 1U;
    }
    BnPtr serialBn(BN_bin2bn(serialBytes.data(), serialBytes.size(), nullptr));
    ASN1_INTEGER* serial = X509_get_serialNumber(certificate.get());
    if (!serialBn || serial == nullptr ||
        BN_to_ASN1_INTEGER(serialBn.get(), serial) == nullptr) {
        OPENSSL_cleanse(serialBytes.data(), serialBytes.size());
        return false;
    }
    OPENSSL_cleanse(serialBytes.data(), serialBytes.size());

    const std::uint64_t nowSeconds = nowMs / 1000U;
    if (nowSeconds == 0U ||
        nowSeconds > static_cast<std::uint64_t>(
                         std::numeric_limits<std::time_t>::max()) ||
        TWENTY_YEARS_SECONDS >
            static_cast<std::uint64_t>(std::numeric_limits<std::time_t>::max()) -
                nowSeconds) {
        return false;
    }
    const std::time_t notBefore = static_cast<std::time_t>(nowSeconds);
    const std::time_t notAfter =
        static_cast<std::time_t>(nowSeconds + TWENTY_YEARS_SECONDS);
    ASN1_TIME* notBeforeTime = ASN1_TIME_set(nullptr, notBefore);
    ASN1_TIME* notAfterTime = ASN1_TIME_set(nullptr, notAfter);
    if (notBeforeTime == nullptr || notAfterTime == nullptr) {
        ASN1_TIME_free(notBeforeTime);
        ASN1_TIME_free(notAfterTime);
        return false;
    }
    const bool timesSet =
        X509_set1_notBefore(certificate.get(), notBeforeTime) == 1 &&
        X509_set1_notAfter(certificate.get(), notAfterTime) == 1;
    ASN1_TIME_free(notBeforeTime);
    ASN1_TIME_free(notAfterTime);
    if (!timesSet) {
        return false;
    }

    X509_NAME* subject = X509_get_subject_name(certificate.get());
    if (subject == nullptr ||
        X509_NAME_add_entry_by_txt(
            subject, "CN", MBSTRING_ASC,
            reinterpret_cast<const unsigned char*>(IDENTITY_COMMON_NAME), -1,
            -1, 0) != 1 ||
        X509_set_issuer_name(certificate.get(), subject) != 1 ||
        X509_set_pubkey(certificate.get(), key.get()) != 1 ||
        X509_sign(certificate.get(), key.get(), EVP_sha256()) <= 0) {
        return false;
    }

    record.metadata = metadata;
    if (!serializeCertificate(certificate.get(), record.certificateDer,
                              record.certificatePem) ||
        !serializePrivateKey(key.get(), record.privateKeyPkcs8) ||
        !certificateFingerprint(record.certificateDer,
                                record.metadata.certificateSha256)) {
        return false;
    }
    return true;
}

struct ParsedIdentity final {
    EvpKeyPtr key;
    X509Ptr certificate;
};

bool validateRecord(const MoonlightIdentityStoredRecord& record,
                    std::uint64_t nowMs,
                    ParsedIdentity* parsed = nullptr) {
    if (!validMetadata(record.metadata) || record.certificateDer.empty() ||
        record.certificateDer.size() > IDENTITY_CERT_DER_MAX ||
        record.certificatePem.empty() ||
        record.certificatePem.size() > IDENTITY_CERT_PEM_MAX ||
        record.certificatePem.find('\r') != std::string::npos ||
        record.privateKeyPkcs8.empty() ||
        record.privateKeyPkcs8.size() > IDENTITY_PKCS8_MAX || nowMs == 0U ||
        record.metadata.createdAtMs > nowMs ||
        record.metadata.rotatedAtMs > nowMs) {
        return false;
    }

    const unsigned char* certCursor = record.certificateDer.data();
    X509Ptr certificate(d2i_X509(nullptr, &certCursor,
                                 static_cast<long>(record.certificateDer.size())));
    if (!certificate ||
        certCursor != record.certificateDer.data() + record.certificateDer.size()) {
        return false;
    }

    const unsigned char* keyCursor = record.privateKeyPkcs8.data();
    Pkcs8Ptr pkcs8(d2i_PKCS8_PRIV_KEY_INFO(
        nullptr, &keyCursor, static_cast<long>(record.privateKeyPkcs8.size())));
    if (!pkcs8 ||
        keyCursor != record.privateKeyPkcs8.data() + record.privateKeyPkcs8.size()) {
        return false;
    }
    EvpKeyPtr key(EVP_PKCS82PKEY(pkcs8.get()));
    if (!key || EVP_PKEY_get_base_id(key.get()) != EVP_PKEY_RSA ||
        EVP_PKEY_get_bits(key.get()) != 2048) {
        return false;
    }

    BIGNUM* exponentRaw = nullptr;
    if (EVP_PKEY_get_bn_param(key.get(), OSSL_PKEY_PARAM_RSA_E, &exponentRaw) !=
            1 ||
        exponentRaw == nullptr) {
        BN_free(exponentRaw);
        return false;
    }
    BnPtr exponent(exponentRaw);
    if (!BN_is_word(exponent.get(), RSA_F4)) {
        return false;
    }

    EvpKeyPtr publicKey(X509_get_pubkey(certificate.get()));
    if (!publicKey || EVP_PKEY_eq(publicKey.get(), key.get()) != 1 ||
        X509_verify(certificate.get(), publicKey.get()) != 1 ||
        X509_get_version(certificate.get()) != 2 ||
        X509_get_signature_nid(certificate.get()) !=
            NID_sha256WithRSAEncryption) {
        return false;
    }

    const ASN1_INTEGER* serial = X509_get0_serialNumber(certificate.get());
    std::uint64_t serialValue = 0;
    if (serial == nullptr || ASN1_INTEGER_get_uint64(&serialValue, serial) != 1 ||
        serialValue == 0U) {
        return false;
    }

    std::array<char, 128> commonName {};
    X509_NAME* subject = X509_get_subject_name(certificate.get());
    if (subject == nullptr || X509_NAME_entry_count(subject) != 1) {
        return false;
    }
    const int commonNameLength = X509_NAME_get_text_by_NID(
        subject, NID_commonName,
        commonName.data(), static_cast<int>(commonName.size()));
    if (commonNameLength !=
            static_cast<int>(std::strlen(IDENTITY_COMMON_NAME)) ||
        std::memcmp(commonName.data(), IDENTITY_COMMON_NAME,
                    std::strlen(IDENTITY_COMMON_NAME)) != 0 ||
        OBJ_obj2nid(X509_NAME_ENTRY_get_object(
            X509_NAME_get_entry(subject, 0))) != NID_commonName ||
        X509_NAME_cmp(subject,
                      X509_get_issuer_name(certificate.get())) != 0) {
        return false;
    }

    std::time_t now = static_cast<std::time_t>(nowMs / 1000U);
    const int notBeforeComparison =
        X509_cmp_time(X509_get0_notBefore(certificate.get()), &now);
    const int notAfterComparison =
        X509_cmp_time(X509_get0_notAfter(certificate.get()), &now);
    int validityDays = 0;
    int validitySeconds = 0;
    if (notBeforeComparison == 0 || notAfterComparison == 0 ||
        notBeforeComparison > 0 || notAfterComparison < 0 ||
        ASN1_TIME_diff(&validityDays, &validitySeconds,
                       X509_get0_notBefore(certificate.get()),
                       X509_get0_notAfter(certificate.get())) != 1 ||
        validityDays != 7305 || validitySeconds != 0) {
        return false;
    }

    std::string fingerprint;
    if (!certificateFingerprint(record.certificateDer, fingerprint) ||
        fingerprint != record.metadata.certificateSha256) {
        return false;
    }

    BioPtr pemInput(BIO_new_mem_buf(record.certificatePem.data(),
                                    static_cast<int>(record.certificatePem.size())));
    X509Ptr pemCertificate(
        pemInput ? PEM_read_bio_X509(pemInput.get(), nullptr, nullptr, nullptr)
                 : nullptr);
    std::vector<std::uint8_t> canonicalDer;
    std::string canonicalPem;
    if (!pemCertificate || X509_cmp(certificate.get(), pemCertificate.get()) != 0 ||
        !serializeCertificate(certificate.get(), canonicalDer, canonicalPem) ||
        canonicalDer != record.certificateDer ||
        canonicalPem != record.certificatePem) {
        return false;
    }

    EvpKeyContextPtr validationContext(
        EVP_PKEY_CTX_new_from_pkey(nullptr, key.get(), nullptr));
    if (!validationContext ||
        EVP_PKEY_pairwise_check(validationContext.get()) != 1) {
        return false;
    }

    if (parsed != nullptr) {
        parsed->key = std::move(key);
        parsed->certificate = std::move(certificate);
    }
    return true;
}

bool readyCapability(const MoonlightIdentityCapability& capability) noexcept {
    if (capability.status != MoonlightIdentityCapabilityStatus::RuntimeReady ||
        capability.huksAliasLimit < MOONLIGHT_HUKS_ALIAS_LIMIT) {
        return false;
    }
    if (capability.storageMode ==
        MoonlightIdentityStorageMode::HuksWrappedPkcs8) {
        return capability.wrappedPkcs8Ready && capability.encryptedBlobAtomic;
    }
    return capability.directRsaTlsSignerReady;
}

} // namespace

MoonlightSecureBuffer::MoonlightSecureBuffer(
    std::vector<std::uint8_t> bytes) noexcept
    : bytes_(std::move(bytes)) {
    if (!bytes_.empty()) {
        pageLocked_ = mlock(bytes_.data(), bytes_.size()) == 0;
    }
}

MoonlightSecureBuffer::~MoonlightSecureBuffer() {
    clear();
}

MoonlightSecureBuffer::MoonlightSecureBuffer(
    MoonlightSecureBuffer&& other) noexcept
    : bytes_(std::move(other.bytes_)), pageLocked_(other.pageLocked_) {
    other.pageLocked_ = false;
}

MoonlightSecureBuffer& MoonlightSecureBuffer::operator=(
    MoonlightSecureBuffer&& other) noexcept {
    if (this != &other) {
        clear();
        bytes_ = std::move(other.bytes_);
        pageLocked_ = other.pageLocked_;
        other.pageLocked_ = false;
    }
    return *this;
}

const std::uint8_t* MoonlightSecureBuffer::data() const noexcept {
    return bytes_.data();
}

std::uint8_t* MoonlightSecureBuffer::data() noexcept {
    return bytes_.data();
}

std::size_t MoonlightSecureBuffer::size() const noexcept {
    return bytes_.size();
}

bool MoonlightSecureBuffer::empty() const noexcept {
    return bytes_.empty();
}

bool MoonlightSecureBuffer::pageLocked() const noexcept {
    return pageLocked_;
}

void MoonlightSecureBuffer::clear() noexcept {
    if (!bytes_.empty()) {
        OPENSSL_cleanse(bytes_.data(), bytes_.size());
        g_secureCleanseCount.fetch_add(1U, std::memory_order_relaxed);
        if (pageLocked_) {
            static_cast<void>(munlock(bytes_.data(), bytes_.size()));
        }
        bytes_.clear();
    }
    pageLocked_ = false;
}

struct MoonlightIdentityLease::Impl final {
    MoonlightIdentityMetadata metadata;
    std::vector<std::uint8_t> certificateDer;
    std::string certificatePem;
    EvpKeyPtr privateKey;
    X509Ptr certificate;
    bool privateDerWasPageLocked = false;
    std::function<void()> release;

    ~Impl() {
        privateKey.reset();
        certificate.reset();
        if (release) {
            release();
        }
    }
};

MoonlightIdentityLease::MoonlightIdentityLease() noexcept = default;

MoonlightIdentityLease::MoonlightIdentityLease(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightIdentityLease::~MoonlightIdentityLease() = default;

MoonlightIdentityLease::MoonlightIdentityLease(
    MoonlightIdentityLease&& other) noexcept = default;

MoonlightIdentityLease& MoonlightIdentityLease::operator=(
    MoonlightIdentityLease&& other) noexcept = default;

bool MoonlightIdentityLease::valid() const noexcept {
    return impl_ != nullptr && impl_->privateKey != nullptr &&
           impl_->certificate != nullptr;
}

const MoonlightIdentityMetadata& MoonlightIdentityLease::metadata() const noexcept {
    static const MoonlightIdentityMetadata EMPTY {};
    return impl_ != nullptr ? impl_->metadata : EMPTY;
}

const std::vector<std::uint8_t>&
MoonlightIdentityLease::certificateDer() const noexcept {
    static const std::vector<std::uint8_t> EMPTY;
    return impl_ != nullptr ? impl_->certificateDer : EMPTY;
}

const std::string& MoonlightIdentityLease::certificatePem() const noexcept {
    static const std::string EMPTY;
    return impl_ != nullptr ? impl_->certificatePem : EMPTY;
}

bool MoonlightIdentityLease::privateMaterialPageLockApplied() const noexcept {
    return impl_ != nullptr && impl_->privateDerWasPageLocked;
}

MoonlightIdentityCode MoonlightIdentityLease::signSha256(
    const std::vector<std::uint8_t>& message,
    std::vector<std::uint8_t>& signature) noexcept {
    signature.clear();
    if (!valid() || message.empty() || message.size() > IDENTITY_SIGN_INPUT_MAX) {
        return MoonlightIdentityCode::InvalidArgument;
    }
    ERR_clear_error();
    MessageDigestContextPtr context(EVP_MD_CTX_new());
    if (!context ||
        EVP_DigestSignInit(context.get(), nullptr, EVP_sha256(), nullptr,
                           impl_->privateKey.get()) != 1 ||
        EVP_DigestSignUpdate(context.get(), message.data(), message.size()) != 1) {
        ERR_clear_error();
        return MoonlightIdentityCode::CryptoFailure;
    }
    std::size_t signatureSize = 0;
    if (EVP_DigestSignFinal(context.get(), nullptr, &signatureSize) != 1 ||
        signatureSize == 0U || signatureSize > 512U) {
        ERR_clear_error();
        return MoonlightIdentityCode::CryptoFailure;
    }
    signature.resize(signatureSize);
    if (EVP_DigestSignFinal(context.get(), signature.data(), &signatureSize) != 1) {
        OPENSSL_cleanse(signature.data(), signature.size());
        signature.clear();
        ERR_clear_error();
        return MoonlightIdentityCode::CryptoFailure;
    }
    signature.resize(signatureSize);
    ERR_clear_error();
    return MoonlightIdentityCode::Ok;
}

MoonlightIdentityCode MoonlightIdentityLease::configureTlsContext(
    struct ssl_ctx_st* context) noexcept {
    if (!valid() || context == nullptr) {
        return MoonlightIdentityCode::InvalidArgument;
    }
    ERR_clear_error();
    if (SSL_CTX_use_certificate(context, impl_->certificate.get()) != 1 ||
        SSL_CTX_use_PrivateKey(context, impl_->privateKey.get()) != 1 ||
        SSL_CTX_check_private_key(context) != 1) {
        ERR_clear_error();
        return MoonlightIdentityCode::CryptoFailure;
    }
    ERR_clear_error();
    return MoonlightIdentityCode::Ok;
}

void MoonlightIdentityLease::reset() noexcept {
    impl_.reset();
}

struct MoonlightSecureIdentity::SharedState final {
    struct Entry final {
        std::size_t leases = 0;
        bool admissionOpen = false;
        bool mutation = false;
        bool cancelled = false;
        bool deletePending = false;
        MoonlightIdentityOperationKey activeKey {};
        std::optional<MoonlightIdentityMetadata> metadata;
    };

    std::mutex mutex;
    std::condition_variable cv;
    std::map<std::string, Entry> entries;
    bool shuttingDown = false;
};

struct MoonlightSecureIdentity::Impl final {
    std::unique_ptr<MoonlightIdentityBackend> backend;
    Clock clock;
    std::function<bool(std::uint8_t*, std::size_t)> entropy = defaultEntropy;
    std::shared_ptr<SharedState> state = std::make_shared<SharedState>();
};

MoonlightSecureIdentity::MoonlightSecureIdentity(
    std::unique_ptr<MoonlightIdentityBackend> backend,
    Clock clock)
    : MoonlightSecureIdentity(std::move(backend), std::move(clock),
                              defaultEntropy) {}

MoonlightSecureIdentity::MoonlightSecureIdentity(
    std::unique_ptr<MoonlightIdentityBackend> backend,
    Clock clock,
    std::function<bool(std::uint8_t*, std::size_t)> entropy)
    : impl_(std::make_unique<Impl>()) {
    impl_->backend = std::move(backend);
    impl_->clock = clock ? std::move(clock) : Clock(defaultClock);
    impl_->entropy = entropy ? std::move(entropy)
                             : std::function<bool(std::uint8_t*, std::size_t)>(
                                   defaultEntropy);
}

MoonlightSecureIdentity::~MoonlightSecureIdentity() {
    if (!impl_) {
        return;
    }
    const auto state = impl_->state;
    std::unique_lock<std::mutex> lock(state->mutex);
    state->shuttingDown = true;
    for (auto& [alias, entry] : state->entries) {
        static_cast<void>(alias);
        entry.admissionOpen = false;
        if (entry.mutation) {
            entry.cancelled = true;
        }
    }
    state->cv.notify_all();
    state->cv.wait(lock, [&]() {
        return std::all_of(
            state->entries.begin(), state->entries.end(),
            [](const auto& item) {
                return !item.second.mutation && item.second.leases == 0U;
            });
    });
}

bool MoonlightSecureIdentity::deriveAlias(const MoonlightIdentityScope& scope,
                                          std::string& alias) noexcept {
    alias.clear();
    if (!validFingerprint(scope.ownerScopeFingerprint) ||
        !validInstallationId(scope.installationId)) {
        return false;
    }
    std::vector<std::uint8_t> ownerBytes;
    if (!decodeHex(scope.ownerScopeFingerprint, ownerBytes)) {
        return false;
    }
    EVP_MD_CTX* rawContext = EVP_MD_CTX_new();
    if (rawContext == nullptr) {
        return false;
    }
    MessageDigestContextPtr context(rawContext);
    std::array<std::uint8_t, 32> digest {};
    unsigned int digestSize = 0;
    const std::uint32_t installationSize =
        static_cast<std::uint32_t>(scope.installationId.size());
    const std::array<std::uint8_t, 4> lengthBytes {
        static_cast<std::uint8_t>((installationSize >> 24U) & 0xffU),
        static_cast<std::uint8_t>((installationSize >> 16U) & 0xffU),
        static_cast<std::uint8_t>((installationSize >> 8U) & 0xffU),
        static_cast<std::uint8_t>(installationSize & 0xffU),
    };
    const bool ok =
        EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) == 1 &&
        EVP_DigestUpdate(context.get(), IDENTITY_ALIAS_DOMAIN,
                         std::strlen(IDENTITY_ALIAS_DOMAIN)) == 1 &&
        EVP_DigestUpdate(context.get(), ownerBytes.data(), ownerBytes.size()) ==
            1 &&
        EVP_DigestUpdate(context.get(), lengthBytes.data(), lengthBytes.size()) ==
            1 &&
        EVP_DigestUpdate(context.get(), scope.installationId.data(),
                         scope.installationId.size()) == 1 &&
        EVP_DigestFinal_ex(context.get(), digest.data(), &digestSize) == 1 &&
        digestSize == digest.size();
    OPENSSL_cleanse(ownerBytes.data(), ownerBytes.size());
    if (!ok) {
        return false;
    }
    alias = std::string(IDENTITY_ALIAS_PREFIX) +
            lowercaseHex(digest.data(), IDENTITY_ALIAS_DIGEST_BYTES);
    OPENSSL_cleanse(digest.data(), digest.size());
    return validAlias(alias);
}

bool MoonlightSecureIdentity::validAlias(const std::string& alias) noexcept {
    constexpr std::size_t PREFIX_SIZE = sizeof(IDENTITY_ALIAS_PREFIX) - 1U;
    return alias.size() == MOONLIGHT_HUKS_ALIAS_LIMIT &&
           alias.compare(0, PREFIX_SIZE, IDENTITY_ALIAS_PREFIX) == 0 &&
           std::all_of(alias.begin() + PREFIX_SIZE,
                       alias.end(), isLowerHex);
}

MoonlightIdentityCapability MoonlightSecureIdentity::capability() const noexcept {
    if (!impl_ || !impl_->backend) {
        return {};
    }
    return impl_->backend->capability();
}

MoonlightIdentityResult MoonlightSecureIdentity::ensure(
    const MoonlightIdentityScope& scope,
    const MoonlightIdentityOperationKey& key) noexcept {
    return ensureOrRotate(scope, key, false, std::chrono::milliseconds(0));
}

MoonlightIdentityResult MoonlightSecureIdentity::rotate(
    const MoonlightIdentityScope& scope,
    const MoonlightIdentityOperationKey& key,
    std::chrono::milliseconds drainTimeout) noexcept {
    return ensureOrRotate(scope, key, true, drainTimeout);
}

MoonlightIdentityResult MoonlightSecureIdentity::ensureOrRotate(
    const MoonlightIdentityScope& scope,
    const MoonlightIdentityOperationKey& key,
    bool rotateIdentity,
    std::chrono::milliseconds drainTimeout) noexcept {
    const auto started = std::chrono::steady_clock::now();
    const MoonlightIdentityOperation operation =
        rotateIdentity ? MoonlightIdentityOperation::Rotate
                       : MoonlightIdentityOperation::Ensure;
    MoonlightIdentityResult result;
    std::string alias;
    if (!impl_ || !impl_->backend || !key.valid() ||
        !deriveAlias(scope, alias) ||
        (rotateIdentity && (drainTimeout.count() <= 0 ||
                            drainTimeout > std::chrono::seconds(30)))) {
        result.code = MoonlightIdentityCode::InvalidArgument;
        result.diagnostic = diagnostic(
            operation, result.code, MoonlightIdentityBackendCode::Unavailable,
            alias, started);
        return result;
    }
    const MoonlightIdentityCapability backendCapability =
        impl_->backend->capability();
    if (!readyCapability(backendCapability) ||
        backendCapability.storageMode ==
            MoonlightIdentityStorageMode::HuksDirectSigner) {
        result.code = MoonlightIdentityCode::Unavailable;
        result.diagnostic = diagnostic(
            operation, result.code, MoonlightIdentityBackendCode::Unavailable,
            alias, started);
        return result;
    }

    const auto state = impl_->state;
    std::optional<MoonlightIdentityMetadata> inMemoryMetadata;
    {
        std::unique_lock<std::mutex> lock(state->mutex);
        if (state->shuttingDown) {
            result.code = MoonlightIdentityCode::ShuttingDown;
            result.diagnostic = diagnostic(
                operation, result.code,
                MoonlightIdentityBackendCode::Unavailable, alias, started);
            return result;
        }
        auto& entry = state->entries[alias];
        if (entry.mutation || entry.deletePending) {
            result.code = MoonlightIdentityCode::Busy;
            result.diagnostic = diagnostic(
                operation, result.code, MoonlightIdentityBackendCode::Busy,
                alias, started);
            return result;
        }
        inMemoryMetadata = entry.metadata;
        entry.mutation = true;
        entry.cancelled = false;
        entry.activeKey = key;
        entry.admissionOpen = false;

        if (rotateIdentity && entry.leases != 0U) {
            const auto deadline = std::chrono::steady_clock::now() + drainTimeout;
            if (!state->cv.wait_until(lock, deadline, [&]() {
                    return entry.leases == 0U || entry.cancelled ||
                           state->shuttingDown;
                })) {
                entry.mutation = false;
                entry.activeKey = {};
                entry.admissionOpen = inMemoryMetadata.has_value();
                state->cv.notify_all();
                result.code = MoonlightIdentityCode::DrainTimeout;
                result.diagnostic = diagnostic(
                    operation, result.code, MoonlightIdentityBackendCode::Busy,
                    alias, started);
                return result;
            }
        }
        if (entry.cancelled || state->shuttingDown) {
            entry.mutation = false;
            entry.activeKey = {};
            entry.admissionOpen = inMemoryMetadata.has_value();
            state->cv.notify_all();
            result.code = state->shuttingDown
                              ? MoonlightIdentityCode::ShuttingDown
                              : MoonlightIdentityCode::Cancelled;
            result.diagnostic = diagnostic(
                operation, result.code,
                MoonlightIdentityBackendCode::Unavailable, alias, started);
            return result;
        }
    }

    MoonlightIdentityBackendCode backendCode = MoonlightIdentityBackendCode::Ok;
    MoonlightIdentityBackendLoadResult loaded = impl_->backend->load(alias);
    backendCode = loaded.code;
    std::uint64_t nowMs = 0U;
    try {
        nowMs = impl_->clock ? impl_->clock() : 0U;
    } catch (...) {
        nowMs = 0U;
    }
    bool success = false;
    bool storageCommitted = false;
    bool created = false;
    bool rotated = false;
    MoonlightIdentityMetadata finalMetadata;
    std::optional<MoonlightIdentityMetadata> rollbackMetadata;

    if (loaded.code == MoonlightIdentityBackendCode::Ok && loaded.record) {
        if (loaded.record->metadata.ownerScopeFingerprint !=
                scope.ownerScopeFingerprint ||
            loaded.record->metadata.localSecureStoreRef != alias ||
            loaded.record->metadata.storageMode !=
                backendCapability.storageMode ||
            !validateRecord(*loaded.record, nowMs)) {
            result.code = MoonlightIdentityCode::Corrupt;
            backendCode = MoonlightIdentityBackendCode::Corrupt;
        } else {
            rollbackMetadata = loaded.record->metadata;
            if (!rotateIdentity) {
                success = true;
                finalMetadata = loaded.record->metadata;
            }
        }
    } else if (loaded.code != MoonlightIdentityBackendCode::NotFound) {
        result.code = mapBackendCode(loaded.code);
    } else if (rotateIdentity) {
        result.code = MoonlightIdentityCode::NotFound;
    }

    bool cancelBeforeCommit = false;
    bool shutdownBeforeCommit = false;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        const auto iterator = state->entries.find(alias);
        if (iterator == state->entries.end() || !iterator->second.mutation ||
            iterator->second.activeKey != key) {
            result.code = MoonlightIdentityCode::Stale;
        } else {
            cancelBeforeCommit = iterator->second.cancelled;
            shutdownBeforeCommit = state->shuttingDown;
        }
    }
    if ((cancelBeforeCommit || shutdownBeforeCommit) &&
        result.code != MoonlightIdentityCode::Stale) {
        success = false;
        result.code = shutdownBeforeCommit
                          ? MoonlightIdentityCode::ShuttingDown
                          : MoonlightIdentityCode::Cancelled;
    }

    if (!success && !cancelBeforeCommit && !shutdownBeforeCommit &&
        result.code == MoonlightIdentityCode::InvalidArgument &&
        ((!rotateIdentity && loaded.code == MoonlightIdentityBackendCode::NotFound) ||
         (rotateIdentity && loaded.code == MoonlightIdentityBackendCode::Ok &&
          loaded.record))) {
        MoonlightIdentityMetadata metadata;
        metadata.identityVersion = rotateIdentity
                                       ? loaded.record->metadata.identityVersion + 1U
                                       : 1U;
        if (metadata.identityVersion > 1000U || nowMs == 0U) {
            result.code = MoonlightIdentityCode::CryptoFailure;
        } else {
            metadata.ownerScopeFingerprint = scope.ownerScopeFingerprint;
            metadata.storageMode = backendCapability.storageMode;
            metadata.localSecureStoreRef = alias;
            metadata.createdAtMs = rotateIdentity
                                       ? loaded.record->metadata.createdAtMs
                                       : nowMs;
            metadata.rotatedAtMs = rotateIdentity ? nowMs : 0U;
            MoonlightIdentityStoredRecord generated;
            if (!generateRecord(metadata, nowMs, impl_->entropy, generated) ||
                !validateRecord(generated, nowMs)) {
                result.code = MoonlightIdentityCode::CryptoFailure;
            } else {
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    const auto iterator = state->entries.find(alias);
                    if (iterator == state->entries.end() ||
                        !iterator->second.mutation ||
                        iterator->second.activeKey != key) {
                        result.code = MoonlightIdentityCode::Stale;
                    } else if (state->shuttingDown) {
                        result.code = MoonlightIdentityCode::ShuttingDown;
                    } else if (iterator->second.cancelled) {
                        result.code = MoonlightIdentityCode::Cancelled;
                    }
                }
                if (result.code == MoonlightIdentityCode::InvalidArgument) {
                    // store() is the atomic commit point. Cancellation that
                    // races after this call starts cannot safely roll back a
                    // replacement, so a successful store wins the race.
                    backendCode =
                        impl_->backend->store(generated, rotateIdentity);
                    if (backendCode == MoonlightIdentityBackendCode::Ok) {
                        success = true;
                        storageCommitted = true;
                        created = !rotateIdentity;
                        rotated = rotateIdentity;
                        finalMetadata = generated.metadata;
                    } else {
                        result.code = mapBackendCode(backendCode);
                    }
                } else {
                    success = false;
                }
            }
        }
    }

    {
        std::lock_guard<std::mutex> lock(state->mutex);
        auto iterator = state->entries.find(alias);
        if (iterator != state->entries.end() && iterator->second.mutation &&
            iterator->second.activeKey == key) {
            auto& entry = iterator->second;
            if (!storageCommitted &&
                (entry.cancelled || state->shuttingDown)) {
                success = false;
                result.code = state->shuttingDown
                                  ? MoonlightIdentityCode::ShuttingDown
                                  : MoonlightIdentityCode::Cancelled;
            }
            entry.mutation = false;
            entry.activeKey = {};
            entry.cancelled = false;
            if (success) {
                entry.metadata = finalMetadata;
                entry.admissionOpen = true;
                entry.deletePending = false;
            } else if (result.code ==
                           MoonlightIdentityCode::StorageOutcomeUnknown) {
                entry.metadata.reset();
                entry.admissionOpen = false;
                entry.deletePending = true;
            } else if (rollbackMetadata.has_value()) {
                entry.metadata = rollbackMetadata;
                entry.admissionOpen = true;
                entry.deletePending = false;
            } else {
                state->entries.erase(iterator);
            }
        }
        state->cv.notify_all();
    }

    if (success) {
        result.code = MoonlightIdentityCode::Ok;
        result.metadata = finalMetadata;
        result.hasMetadata = true;
        result.created = created;
        result.rotated = rotated;
    }
    result.diagnostic =
        diagnostic(operation, result.code, backendCode, alias, started);
    return result;
}

MoonlightIdentityAcquireResult MoonlightSecureIdentity::acquire(
    const MoonlightIdentityScope& scope,
    const MoonlightIdentityOperationKey& key) noexcept {
    const auto started = std::chrono::steady_clock::now();
    MoonlightIdentityAcquireResult result;
    std::string alias;
    if (!impl_ || !impl_->backend || !key.valid() ||
        !deriveAlias(scope, alias)) {
        result.code = MoonlightIdentityCode::InvalidArgument;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Acquire, result.code,
            MoonlightIdentityBackendCode::Unavailable, alias, started);
        return result;
    }
    const MoonlightIdentityCapability backendCapability =
        impl_->backend->capability();
    if (!readyCapability(backendCapability) ||
        backendCapability.storageMode !=
            MoonlightIdentityStorageMode::HuksWrappedPkcs8) {
        result.code = MoonlightIdentityCode::Unavailable;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Acquire, result.code,
            MoonlightIdentityBackendCode::Unavailable, alias, started);
        return result;
    }

    const auto state = impl_->state;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->shuttingDown) {
            result.code = MoonlightIdentityCode::ShuttingDown;
        } else {
            auto& entry = state->entries[alias];
            if (entry.mutation || entry.deletePending) {
                result.code = MoonlightIdentityCode::Busy;
            } else {
                ++entry.leases;
                entry.admissionOpen = true;
                result.code = MoonlightIdentityCode::Ok;
            }
        }
    }
    if (result.code != MoonlightIdentityCode::Ok) {
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Acquire, result.code,
            result.code == MoonlightIdentityCode::Busy
                ? MoonlightIdentityBackendCode::Busy
                : MoonlightIdentityBackendCode::Unavailable,
            alias, started);
        return result;
    }

    auto releaseReservation = [state, alias]() noexcept {
        std::lock_guard<std::mutex> lock(state->mutex);
        const auto iterator = state->entries.find(alias);
        if (iterator != state->entries.end() && iterator->second.leases > 0U) {
            --iterator->second.leases;
            if (iterator->second.leases == 0U &&
                !iterator->second.mutation &&
                !iterator->second.deletePending &&
                !iterator->second.metadata.has_value()) {
                state->entries.erase(iterator);
            }
        }
        state->cv.notify_all();
    };

    MoonlightIdentityBackendLoadResult loaded = impl_->backend->load(alias);
    if (loaded.code != MoonlightIdentityBackendCode::Ok || !loaded.record) {
        releaseReservation();
        const MoonlightIdentityBackendCode effectiveCode =
            loaded.code == MoonlightIdentityBackendCode::Ok
                ? MoonlightIdentityBackendCode::Corrupt
                : loaded.code;
        result.code = mapBackendCode(effectiveCode);
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Acquire, result.code, effectiveCode,
            alias, started);
        return result;
    }

    ParsedIdentity parsed;
    std::uint64_t nowMs = 0U;
    try {
        nowMs = impl_->clock ? impl_->clock() : 0U;
    } catch (...) {
        nowMs = 0U;
    }
    if (loaded.record->metadata.ownerScopeFingerprint !=
            scope.ownerScopeFingerprint ||
        loaded.record->metadata.localSecureStoreRef != alias ||
        loaded.record->metadata.storageMode != backendCapability.storageMode ||
        !validateRecord(*loaded.record, nowMs, &parsed)) {
        releaseReservation();
        result.code = MoonlightIdentityCode::Corrupt;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Acquire, result.code,
            MoonlightIdentityBackendCode::Corrupt, alias, started);
        return result;
    }

    bool reservationStale = false;
    bool shuttingDown = false;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        const auto iterator = state->entries.find(alias);
        if (iterator == state->entries.end() || iterator->second.mutation ||
            iterator->second.deletePending || state->shuttingDown) {
            reservationStale = true;
            shuttingDown = state->shuttingDown;
        } else {
            iterator->second.metadata = loaded.record->metadata;
            iterator->second.admissionOpen = true;
        }
    }
    if (reservationStale) {
        releaseReservation();
        result.code = shuttingDown ? MoonlightIdentityCode::ShuttingDown
                                   : MoonlightIdentityCode::Stale;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Acquire, result.code,
            MoonlightIdentityBackendCode::Busy, alias, started);
        return result;
    }

    auto leaseImpl = std::make_unique<MoonlightIdentityLease::Impl>();
    leaseImpl->metadata = loaded.record->metadata;
    leaseImpl->certificateDer = std::move(loaded.record->certificateDer);
    leaseImpl->certificatePem = std::move(loaded.record->certificatePem);
    leaseImpl->privateKey = std::move(parsed.key);
    leaseImpl->certificate = std::move(parsed.certificate);
    leaseImpl->privateDerWasPageLocked =
        loaded.record->privateKeyPkcs8.pageLocked();
    leaseImpl->release = std::move(releaseReservation);
    loaded.record->privateKeyPkcs8.clear();

    result.code = MoonlightIdentityCode::Ok;
    result.metadata = leaseImpl->metadata;
    result.lease = MoonlightIdentityLease(std::move(leaseImpl));
    result.diagnostic = diagnostic(
        MoonlightIdentityOperation::Acquire, result.code,
        MoonlightIdentityBackendCode::Ok, alias, started);
    return result;
}

MoonlightIdentityResult MoonlightSecureIdentity::erase(
    const MoonlightIdentityScope& scope,
    const MoonlightIdentityOperationKey& key,
    std::chrono::milliseconds drainTimeout) noexcept {
    std::string alias;
    if (!deriveAlias(scope, alias)) {
        MoonlightIdentityResult result;
        result.code = MoonlightIdentityCode::InvalidArgument;
        return result;
    }
    return eraseResolved(scope.ownerScopeFingerprint, alias, key, drainTimeout);
}

MoonlightIdentityResult MoonlightSecureIdentity::eraseAlias(
    const std::string& ownerScopeFingerprint,
    const std::string& alias,
    const MoonlightIdentityOperationKey& key,
    std::chrono::milliseconds drainTimeout) noexcept {
    return eraseResolved(ownerScopeFingerprint, alias, key, drainTimeout);
}

MoonlightIdentityResult MoonlightSecureIdentity::eraseResolved(
    const std::string& ownerScopeFingerprint,
    const std::string& alias,
    const MoonlightIdentityOperationKey& key,
    std::chrono::milliseconds drainTimeout) noexcept {
    const auto started = std::chrono::steady_clock::now();
    MoonlightIdentityResult result;
    if (!impl_ || !impl_->backend || !key.valid() ||
        !validFingerprint(ownerScopeFingerprint) || !validAlias(alias) ||
        drainTimeout.count() <= 0 || drainTimeout > std::chrono::seconds(30)) {
        result.code = MoonlightIdentityCode::InvalidArgument;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Delete, result.code,
            MoonlightIdentityBackendCode::Unavailable, alias, started);
        return result;
    }
    const MoonlightIdentityCapability backendCapability =
        impl_->backend->capability();
    if (!readyCapability(backendCapability) ||
        backendCapability.storageMode !=
            MoonlightIdentityStorageMode::HuksWrappedPkcs8) {
        result.code = MoonlightIdentityCode::Unavailable;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Delete, result.code,
            MoonlightIdentityBackendCode::Unavailable, alias, started);
        return result;
    }

    const auto state = impl_->state;
    {
        std::unique_lock<std::mutex> lock(state->mutex);
        if (state->shuttingDown) {
            result.code = MoonlightIdentityCode::ShuttingDown;
            result.diagnostic = diagnostic(
                MoonlightIdentityOperation::Delete, result.code,
                MoonlightIdentityBackendCode::Unavailable, alias, started);
            return result;
        }
        auto& entry = state->entries[alias];
        if (entry.mutation) {
            result.code = MoonlightIdentityCode::Busy;
            result.diagnostic = diagnostic(
                MoonlightIdentityOperation::Delete, result.code,
                MoonlightIdentityBackendCode::Busy, alias, started);
            return result;
        }
        if (entry.metadata.has_value() &&
            entry.metadata->ownerScopeFingerprint != ownerScopeFingerprint) {
            result.code = MoonlightIdentityCode::Conflict;
            result.diagnostic = diagnostic(
                MoonlightIdentityOperation::Delete, result.code,
                MoonlightIdentityBackendCode::Conflict, alias, started);
            return result;
        }
        entry.mutation = true;
        entry.cancelled = false;
        entry.activeKey = key;
        entry.admissionOpen = false;
        entry.deletePending = true;

        const auto deadline = std::chrono::steady_clock::now() + drainTimeout;
        if (!state->cv.wait_until(lock, deadline, [&]() {
                return entry.leases == 0U || entry.cancelled ||
                       state->shuttingDown;
            })) {
            entry.mutation = false;
            entry.activeKey = {};
            entry.deletePending = true;
            state->cv.notify_all();
            result.code = MoonlightIdentityCode::DrainTimeout;
            result.diagnostic = diagnostic(
                MoonlightIdentityOperation::Delete, result.code,
                MoonlightIdentityBackendCode::Busy, alias, started);
            return result;
        }
        if (entry.cancelled || state->shuttingDown) {
            entry.mutation = false;
            entry.activeKey = {};
            entry.deletePending = false;
            entry.admissionOpen = entry.metadata.has_value();
            state->cv.notify_all();
            result.code = state->shuttingDown
                              ? MoonlightIdentityCode::ShuttingDown
                              : MoonlightIdentityCode::Cancelled;
            result.diagnostic = diagnostic(
                MoonlightIdentityOperation::Delete, result.code,
                MoonlightIdentityBackendCode::Unavailable, alias, started);
            return result;
        }
    }

    MoonlightIdentityBackendLoadResult loaded = impl_->backend->load(alias);
    MoonlightIdentityBackendCode backendCode = loaded.code;
    std::optional<MoonlightIdentityMetadata> rollbackMetadata;
    if (loaded.code == MoonlightIdentityBackendCode::Ok && loaded.record &&
        (loaded.record->metadata.ownerScopeFingerprint != ownerScopeFingerprint ||
         loaded.record->metadata.localSecureStoreRef != alias)) {
        backendCode = MoonlightIdentityBackendCode::Conflict;
    } else if (loaded.code == MoonlightIdentityBackendCode::Ok &&
               !loaded.record) {
        backendCode = MoonlightIdentityBackendCode::Corrupt;
    } else if (loaded.code == MoonlightIdentityBackendCode::Ok) {
        rollbackMetadata = loaded.record->metadata;
        bool cancelledBeforeErase = false;
        bool shutdownBeforeErase = false;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            const auto iterator = state->entries.find(alias);
            if (iterator == state->entries.end() ||
                !iterator->second.mutation ||
                iterator->second.activeKey != key) {
                backendCode = MoonlightIdentityBackendCode::Conflict;
            } else {
                cancelledBeforeErase = iterator->second.cancelled;
                shutdownBeforeErase = state->shuttingDown;
            }
        }
        if (cancelledBeforeErase || shutdownBeforeErase) {
            backendCode = MoonlightIdentityBackendCode::Busy;
            result.code = shutdownBeforeErase
                              ? MoonlightIdentityCode::ShuttingDown
                              : MoonlightIdentityCode::Cancelled;
        } else if (backendCode == MoonlightIdentityBackendCode::Ok) {
            // erase() is the delete commit point. A successful erase wins a
            // cancellation race that begins after this call starts.
            backendCode = impl_->backend->erase(alias);
        }
    }

    const bool deleted = backendCode == MoonlightIdentityBackendCode::Ok ||
                         backendCode == MoonlightIdentityBackendCode::NotFound;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        auto iterator = state->entries.find(alias);
        if (iterator != state->entries.end() && iterator->second.mutation &&
            iterator->second.activeKey == key) {
            if (deleted) {
                state->entries.erase(iterator);
            } else {
                iterator->second.mutation = false;
                iterator->second.activeKey = {};
                iterator->second.cancelled = false;
                if ((result.code == MoonlightIdentityCode::Cancelled ||
                     result.code == MoonlightIdentityCode::ShuttingDown) &&
                    rollbackMetadata.has_value()) {
                    iterator->second.metadata = rollbackMetadata;
                    iterator->second.admissionOpen = true;
                    iterator->second.deletePending = false;
                } else {
                    iterator->second.admissionOpen = false;
                    iterator->second.deletePending = true;
                }
            }
        }
        state->cv.notify_all();
    }

    if (deleted) {
        result.code = MoonlightIdentityCode::Ok;
    } else if (result.code != MoonlightIdentityCode::Cancelled &&
               result.code != MoonlightIdentityCode::ShuttingDown) {
        result.code = mapBackendCode(backendCode);
    }
    result.deleted = deleted;
    result.diagnostic = diagnostic(
        MoonlightIdentityOperation::Delete, result.code, backendCode, alias,
        started);
    return result;
}

MoonlightIdentityInventoryResult MoonlightSecureIdentity::inventory(
    const std::string& ownerScopeFingerprint) noexcept {
    const auto started = std::chrono::steady_clock::now();
    MoonlightIdentityInventoryResult result;
    if (!impl_ || !impl_->backend ||
        !validFingerprint(ownerScopeFingerprint)) {
        result.code = MoonlightIdentityCode::InvalidArgument;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Inventory, result.code,
            MoonlightIdentityBackendCode::Unavailable, {}, started);
        return result;
    }
    const MoonlightIdentityCapability backendCapability =
        impl_->backend->capability();
    if (!readyCapability(backendCapability) ||
        backendCapability.storageMode !=
            MoonlightIdentityStorageMode::HuksWrappedPkcs8) {
        result.code = MoonlightIdentityCode::Unavailable;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Inventory, result.code,
            MoonlightIdentityBackendCode::Unavailable, {}, started);
        return result;
    }
    MoonlightIdentityBackendListResult listed =
        impl_->backend->list(ownerScopeFingerprint);
    if (listed.code != MoonlightIdentityBackendCode::Ok) {
        result.code = mapBackendCode(listed.code);
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Inventory, result.code, listed.code,
            {}, started);
        return result;
    }
    if (listed.records.size() > IDENTITY_INVENTORY_MAX) {
        result.code = MoonlightIdentityCode::Corrupt;
        result.diagnostic = diagnostic(
            MoonlightIdentityOperation::Inventory, result.code,
            MoonlightIdentityBackendCode::Corrupt, {}, started);
        return result;
    }
    std::sort(listed.records.begin(), listed.records.end(),
              [](const auto& left, const auto& right) {
                  return left.localSecureStoreRef < right.localSecureStoreRef;
              });
    std::set<std::string> aliases;
    for (const auto& metadata : listed.records) {
        if (!validMetadata(metadata) ||
            metadata.ownerScopeFingerprint != ownerScopeFingerprint ||
            metadata.storageMode != backendCapability.storageMode ||
            !aliases.insert(metadata.localSecureStoreRef).second) {
            result.code = MoonlightIdentityCode::Corrupt;
            result.records.clear();
            result.diagnostic = diagnostic(
                MoonlightIdentityOperation::Inventory, result.code,
                MoonlightIdentityBackendCode::Corrupt, {}, started);
            return result;
        }
    }
    result.code = MoonlightIdentityCode::Ok;
    result.records = std::move(listed.records);
    result.diagnostic = diagnostic(
        MoonlightIdentityOperation::Inventory, result.code,
        MoonlightIdentityBackendCode::Ok, {}, started);
    return result;
}

bool MoonlightSecureIdentity::cancel(
    const MoonlightIdentityOperationKey& key) noexcept {
    if (!impl_ || !key.valid()) {
        return false;
    }
    const auto state = impl_->state;
    std::lock_guard<std::mutex> lock(state->mutex);
    for (auto& [alias, entry] : state->entries) {
        static_cast<void>(alias);
        if (entry.mutation && entry.activeKey == key) {
            entry.cancelled = true;
            state->cv.notify_all();
            return true;
        }
    }
    return false;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::unique_ptr<MoonlightSecureIdentity>
MoonlightSecureIdentity::createForTesting(
    std::unique_ptr<MoonlightIdentityBackend> backend,
    Clock clock,
    EntropyForTesting entropy) {
    return std::unique_ptr<MoonlightSecureIdentity>(
        new MoonlightSecureIdentity(std::move(backend), std::move(clock),
                                    std::move(entropy)));
}

std::uint64_t MoonlightSecureIdentity::secureCleanseCountForTesting() noexcept {
    return g_secureCleanseCount.load(std::memory_order_relaxed);
}

void MoonlightSecureIdentity::resetSecureCleanseCountForTesting() noexcept {
    g_secureCleanseCount.store(0U, std::memory_order_relaxed);
}
#endif

} // namespace remotedesk::moonlight
