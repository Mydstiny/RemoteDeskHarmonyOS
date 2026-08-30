#include "moonlight/pairing/MoonlightPairingManager.h"

#include "common/network_generation_fence.h"

#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <ctime>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kSecretBytes = 16U;
constexpr std::size_t kMaxCertificateBytes = 64U * 1024U;
constexpr std::size_t kMaxSignatureBytes = 1024U;
constexpr std::size_t kMaxIdentityPemBytes = 32U * 1024U;
constexpr std::size_t kMaxHostIdentityBytes = 256U;
constexpr std::size_t kMaxHostLabelBytes = 512U;
constexpr std::chrono::milliseconds kCleanupTimeout{2000};

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::atomic<std::uint64_t> gPairingCleanseCount{0};
#endif

void secureWipe(void* pointer, std::size_t size) noexcept {
    if (pointer != nullptr && size != 0U) {
        OPENSSL_cleanse(pointer, size);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        gPairingCleanseCount.fetch_add(1U, std::memory_order_relaxed);
#endif
    }
}

void secureWipeString(std::string& value) noexcept {
    if (!value.empty()) {
        secureWipe(value.data(), value.size());
    }
    value.clear();
}

class StringWiper final {
public:
    explicit StringWiper(std::string& value) noexcept : value_(value) {}
    ~StringWiper() { secureWipeString(value_); }

    StringWiper(const StringWiper&) = delete;
    StringWiper& operator=(const StringWiper&) = delete;

private:
    std::string& value_;
};

class ByteVectorWiper final {
public:
    explicit ByteVectorWiper(std::vector<std::uint8_t>& value) noexcept : value_(value) {}
    ~ByteVectorWiper() { secureWipe(value_.data(), value_.size()); }

    ByteVectorWiper(const ByteVectorWiper&) = delete;
    ByteVectorWiper& operator=(const ByteVectorWiper&) = delete;

private:
    std::vector<std::uint8_t>& value_;
};

class ScopeExit final {
public:
    explicit ScopeExit(std::function<void()> callback) : callback_(std::move(callback)) {}
    ~ScopeExit() {
        if (armed_ && callback_) {
            callback_();
        }
    }
    void disarm() noexcept { armed_ = false; }

    ScopeExit(const ScopeExit&) = delete;
    ScopeExit& operator=(const ScopeExit&) = delete;

private:
    std::function<void()> callback_;
    bool armed_ = true;
};

struct PairingKeyHash final {
    std::size_t operator()(const MoonlightPairingOperationKey& key) const noexcept {
        std::size_t value = static_cast<std::size_t>(key.requestId);
        value ^= static_cast<std::size_t>(key.generation) + 0x9e3779b9U + (value << 6U) +
                 (value >> 2U);
        value ^= static_cast<std::size_t>(key.ownerToken) + 0x9e3779b9U + (value << 6U) +
                 (value >> 2U);
        return value;
    }
};

struct ActivePairing final {
    ActivePairing(MoonlightPairingOperationKey valueKey, std::string valueLane,
                  remotedesk::net::NetworkGenerationSnapshot valueNetwork)
        : key(valueKey), lane(std::move(valueLane)), network(valueNetwork) {}

    MoonlightPairingOperationKey key {};
    std::string lane;
    remotedesk::net::NetworkGenerationSnapshot network {};
    std::atomic<bool> cancelled{false};
};

bool boundedText(const std::string& value, std::size_t maximum, bool allowEmpty = false) {
    if ((!allowEmpty && value.empty()) || value.size() > maximum) {
        return false;
    }
    return std::none_of(value.begin(), value.end(), [](char character) {
        const auto byte = static_cast<unsigned char>(character);
        return byte < 0x20U || byte == 0x7fU;
    });
}

std::string laneFor(const MoonlightPairingRequest& request) {
    return request.identityScope.ownerScopeFingerprint + ":" + request.hostId;
}

MoonlightHostRequestKey hostKey(const MoonlightPairingOperationKey& key) noexcept {
    return {key.requestId, key.generation, key.ownerToken};
}

MoonlightIdentityOperationKey identityKey(const MoonlightPairingOperationKey& key) noexcept {
    return {key.requestId, key.generation, key.ownerToken};
}

bool isPinValid(const MoonlightSecureBuffer& pin) noexcept {
    if (pin.size() != 4U || pin.data() == nullptr) {
        return false;
    }
    for (std::size_t index = 0; index < pin.size(); ++index) {
        if (pin.data()[index] < static_cast<std::uint8_t>('0') ||
            pin.data()[index] > static_cast<std::uint8_t>('9')) {
            return false;
        }
    }
    return true;
}

bool validateRequestShape(const MoonlightPairingRequest& request) {
    if (!request.key.valid() || !isPinValid(request.pin) || request.serverMajorVersion == 0U ||
        request.timeout < MoonlightHostLimits::kMinTimeout ||
        request.timeout > MoonlightHostLimits::kMaxTimeout ||
        !boundedText(request.hostId, kMaxHostIdentityBytes) ||
        !boundedText(request.serverUuid, kMaxHostIdentityBytes) ||
        !boundedText(request.hostLabel, kMaxHostLabelBytes, true)) {
        return false;
    }
    std::string alias;
    return MoonlightSecureIdentity::deriveAlias(request.identityScope, alias);
}

std::string maskedHost(const std::string& hostId) {
    std::array<unsigned char, EVP_MAX_MD_SIZE> digest {};
    unsigned int length = 0;
    if (EVP_Digest(hostId.data(), hostId.size(), digest.data(), &length, EVP_sha256(), nullptr) !=
            1 ||
        length < 4U) {
        return "host:<masked>";
    }
    constexpr char hex[] = "0123456789abcdef";
    std::string output("host:");
    for (std::size_t index = 0; index < 4U; ++index) {
        output.push_back(hex[digest[index] >> 4U]);
        output.push_back(hex[digest[index] & 0x0fU]);
    }
    secureWipe(digest.data(), digest.size());
    return output;
}

std::string hexEncode(const std::uint8_t* bytes, std::size_t size) {
    constexpr char hex[] = "0123456789ABCDEF";
    if (bytes == nullptr || size > (std::numeric_limits<std::size_t>::max() / 2U)) {
        return {};
    }
    std::string output;
    output.resize(size * 2U);
    for (std::size_t index = 0; index < size; ++index) {
        output[index * 2U] = hex[bytes[index] >> 4U];
        output[index * 2U + 1U] = hex[bytes[index] & 0x0fU];
    }
    return output;
}

int hexNibble(char character) noexcept {
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    if (character >= 'A' && character <= 'F') {
        return character - 'A' + 10;
    }
    return -1;
}

bool hexDecode(const std::string& text, std::size_t maximumBytes,
               MoonlightSecureBuffer& output) {
    if (text.empty() || (text.size() & 1U) != 0U || text.size() / 2U > maximumBytes) {
        return false;
    }
    std::vector<std::uint8_t> bytes(text.size() / 2U, 0U);
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        const int high = hexNibble(text[index * 2U]);
        const int low = hexNibble(text[index * 2U + 1U]);
        if (high < 0 || low < 0) {
            secureWipe(bytes.data(), bytes.size());
            return false;
        }
        bytes[index] = static_cast<std::uint8_t>((high << 4) | low);
    }
    output = MoonlightSecureBuffer(std::move(bytes));
    return true;
}

bool digestParts(const EVP_MD* algorithm,
                 const std::vector<std::pair<const std::uint8_t*, std::size_t>>& parts,
                 MoonlightSecureBuffer& output) {
    if (algorithm == nullptr) {
        return false;
    }
    EVP_MD_CTX* rawContext = EVP_MD_CTX_new();
    if (rawContext == nullptr) {
        return false;
    }
    const std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> context(rawContext,
                                                                        EVP_MD_CTX_free);
    if (EVP_DigestInit_ex(context.get(), algorithm, nullptr) != 1) {
        return false;
    }
    for (const auto& part : parts) {
        if ((part.second != 0U && part.first == nullptr) ||
            EVP_DigestUpdate(context.get(), part.first, part.second) != 1) {
            return false;
        }
    }
    const int expected = EVP_MD_get_size(algorithm);
    if (expected <= 0) {
        return false;
    }
    std::vector<std::uint8_t> digest(static_cast<std::size_t>(expected), 0U);
    unsigned int actual = 0;
    if (EVP_DigestFinal_ex(context.get(), digest.data(), &actual) != 1 ||
        actual != digest.size()) {
        secureWipe(digest.data(), digest.size());
        return false;
    }
    output = MoonlightSecureBuffer(std::move(digest));
    return true;
}

bool aesBlockTransform(bool encrypt, const MoonlightSecureBuffer& input,
                       const MoonlightSecureBuffer& key, std::size_t logicalSize,
                       MoonlightSecureBuffer& output) {
    if (key.size() != kSecretBytes || input.data() == nullptr || logicalSize > input.size()) {
        return false;
    }
    const std::size_t rounded = (logicalSize + (kSecretBytes - 1U)) & ~(kSecretBytes - 1U);
    if (rounded == 0U || (encrypt && input.size() < logicalSize) ||
        (!encrypt && input.size() != rounded)) {
        return false;
    }
    std::vector<std::uint8_t> padded(rounded, 0U);
    std::copy_n(input.data(), encrypt ? logicalSize : rounded, padded.data());
    std::vector<std::uint8_t> transformed(rounded, 0U);
    EVP_CIPHER_CTX* rawContext = EVP_CIPHER_CTX_new();
    if (rawContext == nullptr) {
        secureWipe(padded.data(), padded.size());
        return false;
    }
    const std::unique_ptr<EVP_CIPHER_CTX, decltype(&EVP_CIPHER_CTX_free)> context(
        rawContext, EVP_CIPHER_CTX_free);
    int written = 0;
    int finalBytes = 0;
    const bool ok =
        (encrypt ? EVP_EncryptInit_ex(context.get(), EVP_aes_128_ecb(), nullptr, key.data(), nullptr)
                 : EVP_DecryptInit_ex(context.get(), EVP_aes_128_ecb(), nullptr, key.data(), nullptr)) ==
            1 &&
        EVP_CIPHER_CTX_set_padding(context.get(), 0) == 1 &&
        (encrypt ? EVP_EncryptUpdate(context.get(), transformed.data(), &written, padded.data(),
                                     static_cast<int>(padded.size()))
                 : EVP_DecryptUpdate(context.get(), transformed.data(), &written, padded.data(),
                                     static_cast<int>(padded.size()))) == 1 &&
        (encrypt ? EVP_EncryptFinal_ex(context.get(), transformed.data() + written, &finalBytes)
                 : EVP_DecryptFinal_ex(context.get(), transformed.data() + written, &finalBytes)) ==
            1 &&
        static_cast<std::size_t>(written + finalBytes) == rounded;
    secureWipe(padded.data(), padded.size());
    if (!ok) {
        secureWipe(transformed.data(), transformed.size());
        return false;
    }
    if (!encrypt) {
        for (std::size_t index = logicalSize; index < transformed.size(); ++index) {
            if (transformed[index] != 0U) {
                secureWipe(transformed.data(), transformed.size());
                return false;
            }
        }
    }
    output = MoonlightSecureBuffer(std::move(transformed));
    return true;
}

bool secureSlice(const MoonlightSecureBuffer& input, std::size_t offset, std::size_t size,
                 MoonlightSecureBuffer& output) {
    if (offset > input.size() || size > input.size() - offset) {
        return false;
    }
    std::vector<std::uint8_t> bytes(size, 0U);
    if (size != 0U) {
        std::copy_n(input.data() + offset, size, bytes.data());
    }
    output = MoonlightSecureBuffer(std::move(bytes));
    return true;
}

bool appendSecure(const MoonlightSecureBuffer& first, const MoonlightSecureBuffer& second,
                  MoonlightSecureBuffer& output) {
    if (first.size() > std::numeric_limits<std::size_t>::max() - second.size()) {
        return false;
    }
    std::vector<std::uint8_t> bytes(first.size() + second.size(), 0U);
    if (!first.empty()) {
        std::copy_n(first.data(), first.size(), bytes.data());
    }
    if (!second.empty()) {
        std::copy_n(second.data(), second.size(), bytes.data() + first.size());
    }
    output = MoonlightSecureBuffer(std::move(bytes));
    return true;
}

std::string nameText(X509_NAME* name) {
    if (name == nullptr) {
        return {};
    }
    BIO* rawBio = BIO_new(BIO_s_mem());
    if (rawBio == nullptr) {
        return {};
    }
    const std::unique_ptr<BIO, decltype(&BIO_free)> bio(rawBio, BIO_free);
    if (X509_NAME_print_ex(bio.get(), name, 0, XN_FLAG_RFC2253) < 0) {
        return {};
    }
    char* data = nullptr;
    const long size = BIO_get_mem_data(bio.get(), &data);
    if (size <= 0 || size > static_cast<long>(kMaxHostLabelBytes) || data == nullptr) {
        return {};
    }
    return std::string(data, static_cast<std::size_t>(size));
}

std::string asn1TimeText(const ASN1_TIME* time) {
    if (time == nullptr) {
        return {};
    }
    BIO* rawBio = BIO_new(BIO_s_mem());
    if (rawBio == nullptr) {
        return {};
    }
    const std::unique_ptr<BIO, decltype(&BIO_free)> bio(rawBio, BIO_free);
    if (ASN1_TIME_print(bio.get(), time) != 1) {
        return {};
    }
    char* data = nullptr;
    const long size = BIO_get_mem_data(bio.get(), &data);
    if (size <= 0 || size > 64L || data == nullptr) {
        return {};
    }
    return std::string(data, static_cast<std::size_t>(size));
}

struct ParsedCertificate final {
    ~ParsedCertificate() {
        secureWipe(signature.data(), signature.size());
        secureWipe(canonicalDer.data(), canonicalDer.size());
    }

    std::unique_ptr<X509, decltype(&X509_free)> certificate{nullptr, X509_free};
    // Sunshine's plaincert field contains a hex-encoded PEM certificate while
    // some compatible hosts return DER. Normalize either strict wire shape to
    // one exact DER leaf before TLS pinning and fingerprinting.
    std::vector<std::uint8_t> canonicalDer;
    std::vector<std::uint8_t> signature;
    MoonlightTrustCandidate candidate;
};

bool isCertificateTrailingWhitespace(unsigned char value) noexcept {
    return value == static_cast<unsigned char>(' ') ||
        value == static_cast<unsigned char>('\t') ||
        value == static_cast<unsigned char>('\r') ||
        value == static_cast<unsigned char>('\n');
}

bool decodeCertificate(const std::vector<std::uint8_t>& encoded,
                       std::unique_ptr<X509, decltype(&X509_free)>& output,
                       bool& sourceWasDer) {
    sourceWasDer = false;
    if (encoded.empty() || encoded.size() > kMaxCertificateBytes ||
        encoded.size() > static_cast<std::size_t>(std::numeric_limits<long>::max()) ||
        encoded.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return false;
    }

    const unsigned char* derCursor = encoded.data();
    X509* rawCertificate = d2i_X509(
        nullptr, &derCursor, static_cast<long>(encoded.size()));
    if (rawCertificate != nullptr && derCursor == encoded.data() + encoded.size()) {
        output.reset(rawCertificate);
        sourceWasDer = true;
        return true;
    }
    X509_free(rawCertificate);

    BIO* rawBio = BIO_new_mem_buf(encoded.data(), static_cast<int>(encoded.size()));
    if (rawBio == nullptr) {
        return false;
    }
    const std::unique_ptr<BIO, decltype(&BIO_free)> bio(rawBio, BIO_free);
    rawCertificate = PEM_read_bio_X509(bio.get(), nullptr, nullptr, nullptr);
    if (rawCertificate == nullptr) {
        return false;
    }
    std::unique_ptr<X509, decltype(&X509_free)> certificate(rawCertificate, X509_free);

    // PEM_read_bio_X509() may leave line endings after the END marker. Permit
    // only ASCII whitespace so appended certificates or arbitrary bytes can
    // never be silently accepted as part of the pin.
    std::array<unsigned char, 256U> trailing{};
    for (;;) {
        const int count = BIO_read(bio.get(), trailing.data(),
                                   static_cast<int>(trailing.size()));
        if (count <= 0) {
            break;
        }
        if (!std::all_of(trailing.begin(), trailing.begin() + count,
                         isCertificateTrailingWhitespace)) {
            return false;
        }
    }
    output = std::move(certificate);
    return true;
}

bool parseCertificate(const std::vector<std::uint8_t>& encoded, const std::string& hostId,
                      const std::string& hostLabel, std::uint64_t wallClockMs,
                      ParsedCertificate& output) {
    std::unique_ptr<X509, decltype(&X509_free)> certificate(nullptr, X509_free);
    bool sourceWasDer = false;
    if (!decodeCertificate(encoded, certificate, sourceWasDer)) {
        return false;
    }
    const int canonicalSize = i2d_X509(certificate.get(), nullptr);
    if (canonicalSize <= 0 ||
        static_cast<std::size_t>(canonicalSize) > kMaxCertificateBytes) {
        return false;
    }
    std::vector<std::uint8_t> canonical(
        static_cast<std::size_t>(canonicalSize), 0U);
    unsigned char* canonicalCursor = canonical.data();
    if (i2d_X509(certificate.get(), &canonicalCursor) != canonicalSize ||
        (sourceWasDer && canonical != encoded)) {
        return false;
    }

    EVP_PKEY* rawPublicKey = X509_get_pubkey(certificate.get());
    if (rawPublicKey == nullptr) {
        return false;
    }
    const std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> publicKey(rawPublicKey,
                                                                       EVP_PKEY_free);
    const int keyType = EVP_PKEY_base_id(publicKey.get());
    const int keyBits = EVP_PKEY_get_bits(publicKey.get());
    if ((keyType == EVP_PKEY_RSA && keyBits < 2048) ||
        (keyType == EVP_PKEY_EC && keyBits < 256) ||
        (keyType != EVP_PKEY_RSA && keyType != EVP_PKEY_EC) || keyBits <= 0) {
        return false;
    }
    // The pairing transcript proves possession of the leaf private key and
    // the transport subsequently pins that exact leaf. Do not require the
    // leaf to be self-signed or currently within its Web-PKI validity window;
    // official Moonlight clients also permit Sunshine custom/expired pinned
    // certificates here rather than treating them as public-CA identities.
    static_cast<void>(wallClockMs);

    std::array<unsigned char, EVP_MAX_MD_SIZE> fingerprint {};
    unsigned int fingerprintSize = 0;
    if (X509_digest(certificate.get(), EVP_sha256(), fingerprint.data(), &fingerprintSize) != 1 ||
        fingerprintSize != 32U) {
        return false;
    }
    std::string fingerprintText = hexEncode(fingerprint.data(), fingerprintSize);
    std::transform(fingerprintText.begin(), fingerprintText.end(), fingerprintText.begin(),
                   [](char character) {
                       return static_cast<char>(character >= 'A' && character <= 'F'
                                                    ? character - 'A' + 'a'
                                                    : character);
                   });
    secureWipe(fingerprint.data(), fingerprint.size());

    const ASN1_BIT_STRING* certificateSignature = nullptr;
    const X509_ALGOR* signatureAlgorithm = nullptr;
    X509_get0_signature(&certificateSignature, &signatureAlgorithm, certificate.get());
    static_cast<void>(signatureAlgorithm);
    if (certificateSignature == nullptr || certificateSignature->length <= 0 ||
        static_cast<std::size_t>(certificateSignature->length) > kMaxSignatureBytes) {
        return false;
    }
    const std::string subject = nameText(X509_get_subject_name(certificate.get()));
    const std::string issuer = nameText(X509_get_issuer_name(certificate.get()));
    const std::string start = asn1TimeText(X509_get0_notBefore(certificate.get()));
    const std::string end = asn1TimeText(X509_get0_notAfter(certificate.get()));
    if (subject.empty() || issuer.empty() || start.empty() || end.empty()) {
        return false;
    }

    output.signature.assign(certificateSignature->data,
                            certificateSignature->data + certificateSignature->length);
    output.canonicalDer = std::move(canonical);
    output.candidate.maskedHost = maskedHost(hostId);
    output.candidate.hostLabel = hostLabel;
    output.candidate.certificateSha256 = std::move(fingerprintText);
    output.candidate.subject = subject;
    output.candidate.issuer = issuer;
    output.candidate.notBefore = start;
    output.candidate.notAfter = end;
    output.candidate.publicKeyAlgorithm = keyType == EVP_PKEY_RSA ? "RSA" : "EC";
    output.candidate.publicKeyBits = static_cast<std::uint32_t>(keyBits);
    output.certificate = std::move(certificate);
    return true;
}

bool certificateSignature(const std::vector<std::uint8_t>& der,
                          MoonlightSecureBuffer& output) {
    if (der.empty() || der.size() > kMaxCertificateBytes ||
        der.size() > static_cast<std::size_t>(std::numeric_limits<long>::max())) {
        return false;
    }
    const unsigned char* cursor = der.data();
    const std::unique_ptr<X509, decltype(&X509_free)> certificate(
        d2i_X509(nullptr, &cursor, static_cast<long>(der.size())), X509_free);
    if (certificate == nullptr || cursor != der.data() + der.size()) {
        return false;
    }
    const ASN1_BIT_STRING* signature = nullptr;
    const X509_ALGOR* algorithm = nullptr;
    X509_get0_signature(&signature, &algorithm, certificate.get());
    static_cast<void>(algorithm);
    if (signature == nullptr || signature->length <= 0 ||
        static_cast<std::size_t>(signature->length) > kMaxSignatureBytes) {
        return false;
    }
    std::vector<std::uint8_t> bytes(signature->data, signature->data + signature->length);
    output = MoonlightSecureBuffer(std::move(bytes));
    return true;
}

bool verifyServerSignature(X509* certificate, const MoonlightSecureBuffer& message,
                           const MoonlightSecureBuffer& signature) {
    if (certificate == nullptr || message.empty() || signature.empty()) {
        return false;
    }
    EVP_PKEY* rawKey = X509_get_pubkey(certificate);
    EVP_MD_CTX* rawContext = EVP_MD_CTX_new();
    if (rawKey == nullptr || rawContext == nullptr) {
        EVP_PKEY_free(rawKey);
        EVP_MD_CTX_free(rawContext);
        return false;
    }
    const std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key(rawKey, EVP_PKEY_free);
    const std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> context(rawContext,
                                                                        EVP_MD_CTX_free);
    return EVP_DigestVerifyInit(context.get(), nullptr, EVP_sha256(), nullptr, key.get()) == 1 &&
           EVP_DigestVerifyUpdate(context.get(), message.data(), message.size()) == 1 &&
           EVP_DigestVerifyFinal(context.get(), signature.data(), signature.size()) == 1;
}

void wipePairingPayload(MoonlightHostResult& result) noexcept {
    if (!result.pairing.has_value()) {
        return;
    }
    auto wipe = [](std::optional<std::string>& value) {
        if (value.has_value()) {
            secureWipeString(*value);
            value.reset();
        }
    };
    wipe(result.pairing->plainCertificateHex);
    wipe(result.pairing->challengeResponseHex);
    wipe(result.pairing->pairingSecretHex);
    result.pairing.reset();
}

void wipeCallQuery(MoonlightHostCall& call) noexcept {
    for (auto& parameter : call.query) {
        secureWipeString(parameter.value);
    }
    call.query.clear();
}

class QueryWiper final {
public:
    explicit QueryWiper(MoonlightHostCall& call) noexcept : call_(call) {}
    ~QueryWiper() { wipeCallQuery(call_); }

private:
    MoonlightHostCall& call_;
};

bool possiblySent(const MoonlightHostResult& result) noexcept {
    return std::any_of(result.diagnostics.begin(), result.diagnostics.end(), [](const auto& item) {
        return item.sendState != MoonlightTransportSendState::NotSent;
    });
}

MoonlightPairingCode mapHostCode(const MoonlightHostResult& result) noexcept {
    if (result.mutationOutcomeUnknown || result.error == MoonlightHostError::ActionUnknown) {
        return MoonlightPairingCode::MutationOutcomeUnknown;
    }
    switch (result.error) {
    case MoonlightHostError::Cancelled:
        return MoonlightPairingCode::Cancelled;
    case MoonlightHostError::StaleRequest:
        return MoonlightPairingCode::Stale;
    case MoonlightHostError::DeadlineExceeded:
        return MoonlightPairingCode::DeadlineExceeded;
    case MoonlightHostError::ShuttingDown:
        return MoonlightPairingCode::ShuttingDown;
    case MoonlightHostError::InvalidField:
    case MoonlightHostError::MissingRequiredField:
    case MoonlightHostError::MalformedXml:
    case MoonlightHostError::XmlBudgetExceeded:
        return MoonlightPairingCode::ProtocolFailure;
    default:
        return MoonlightPairingCode::TransportFailure;
    }
}

MoonlightPairingCode mapIdentityCode(MoonlightIdentityCode code) noexcept {
    switch (code) {
    case MoonlightIdentityCode::Ok:
        return MoonlightPairingCode::Ok;
    case MoonlightIdentityCode::Cancelled:
        return MoonlightPairingCode::Cancelled;
    case MoonlightIdentityCode::Stale:
        return MoonlightPairingCode::Stale;
    case MoonlightIdentityCode::ShuttingDown:
        return MoonlightPairingCode::ShuttingDown;
    case MoonlightIdentityCode::Unavailable:
        return MoonlightPairingCode::Unavailable;
    case MoonlightIdentityCode::StorageOutcomeUnknown:
        return MoonlightPairingCode::RepairRequired;
    default:
        return MoonlightPairingCode::IdentityFailure;
    }
}

} // namespace

struct MoonlightPairingManager::Impl final {
    Impl(std::shared_ptr<MoonlightHostApi> valueHostApi,
         std::shared_ptr<MoonlightSecureIdentity> valueSecureIdentity,
         std::shared_ptr<MoonlightPairingTrustPort> valueTrustPort,
         std::shared_ptr<MoonlightPairingTlsBindingPort> valueTlsBindingPort,
         std::shared_ptr<MoonlightPairingCommitPort> valueCommitPort, Entropy valueEntropy,
         MonotonicClock valueMonotonicClock, WallClock valueWallClock)
        : hostApi(std::move(valueHostApi)), secureIdentity(std::move(valueSecureIdentity)),
          trustPort(std::move(valueTrustPort)), tlsBindingPort(std::move(valueTlsBindingPort)),
          commitPort(std::move(valueCommitPort)), entropy(std::move(valueEntropy)),
          monotonicClock(std::move(valueMonotonicClock)), wallClock(std::move(valueWallClock)) {}

    std::mutex mutex;
    std::condition_variable cv;
    std::unordered_map<std::string, std::shared_ptr<ActivePairing>> activeLanes;
    std::unordered_map<MoonlightPairingOperationKey, std::shared_ptr<ActivePairing>, PairingKeyHash>
        activeKeys;
    std::unordered_set<std::string> repairBlockedLanes;
    bool shuttingDown = false;
    std::shared_ptr<MoonlightHostApi> hostApi;
    std::shared_ptr<MoonlightSecureIdentity> secureIdentity;
    std::shared_ptr<MoonlightPairingTrustPort> trustPort;
    std::shared_ptr<MoonlightPairingTlsBindingPort> tlsBindingPort;
    std::shared_ptr<MoonlightPairingCommitPort> commitPort;
    Entropy entropy;
    MonotonicClock monotonicClock;
    WallClock wallClock;
};

namespace {

class ActiveLease final {
public:
    ActiveLease(std::shared_ptr<MoonlightPairingManager::Impl> impl,
                std::shared_ptr<ActivePairing> active)
        : impl_(std::move(impl)), active_(std::move(active)) {}
    ~ActiveLease() {
        if (impl_ == nullptr || active_ == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        const auto lane = impl_->activeLanes.find(active_->lane);
        if (lane != impl_->activeLanes.end() && lane->second == active_) {
            impl_->activeLanes.erase(lane);
        }
        const auto key = impl_->activeKeys.find(active_->key);
        if (key != impl_->activeKeys.end() && key->second == active_) {
            impl_->activeKeys.erase(key);
        }
        impl_->cv.notify_all();
    }

private:
    std::shared_ptr<MoonlightPairingManager::Impl> impl_;
    std::shared_ptr<ActivePairing> active_;
};

class BindingLease final {
public:
    BindingLease(std::shared_ptr<MoonlightPairingTlsBindingPort> port,
                 MoonlightPairingOperationKey key)
        : port_(std::move(port)), key_(key) {}
    ~BindingLease() {
        if (bound_ && port_ != nullptr) {
            port_->unbind(key_);
        }
    }
    void markBound() noexcept { bound_ = true; }

private:
    std::shared_ptr<MoonlightPairingTlsBindingPort> port_;
    MoonlightPairingOperationKey key_ {};
    bool bound_ = false;
};

std::chrono::milliseconds remainingTimeout(
    const std::shared_ptr<MoonlightPairingManager::Impl>& impl,
    std::chrono::steady_clock::time_point deadline, bool longPairWait) {
    const auto now = impl->monotonicClock();
    if (now >= deadline) {
        return std::chrono::milliseconds{0};
    }
    auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
    const auto maximum = longPairWait ? MoonlightHostLimits::kMaxTimeout
                                      : MoonlightHostLimits::kMaxStandardTimeout;
    if (remaining > maximum) {
        remaining = maximum;
    }
    return remaining;
}

void observeHostResult(const MoonlightHostResult& hostResult, MoonlightPairingResult& result) {
    result.lastHostError = hostResult.error;
    result.lastHttpStatus = hostResult.httpStatus;
    result.lastXmlStatus = hostResult.xmlStatus.value_or(0);
    result.transportAttempts += hostResult.diagnostics.size();
}

bool hasOnlyPairingPayload(const MoonlightPairingPayload& payload,
                           bool allowPlainCertificate,
                           bool allowChallengeResponse,
                           bool allowPairingSecret) noexcept {
    return (allowPlainCertificate || !payload.plainCertificateHex.has_value()) &&
           (allowChallengeResponse || !payload.challengeResponseHex.has_value()) &&
           (allowPairingSecret || !payload.pairingSecretHex.has_value());
}

MoonlightRemoteCleanup runRemoteCleanup(
    const std::shared_ptr<MoonlightPairingManager::Impl>& impl,
    const MoonlightPairingRequest& request, MoonlightPairingResult& result,
    std::uint64_t expectedNetworkGeneration) noexcept {
    try {
        MoonlightHostCall call;
        call.key = hostKey(request.key);
        call.operation = MoonlightHostOperation::Unpair;
        call.endpoint = request.endpoint;
        call.endpoint.pinnedTrustAvailable = false;
        call.timeout = kCleanupTimeout;
        call.expectedNetworkGeneration = expectedNetworkGeneration;
        const auto hostResult = impl->hostApi->execute(call);
        result.transportAttempts += hostResult.diagnostics.size();
        if (hostResult.ok() && hostResult.action.has_value() && hostResult.action->accepted) {
            return MoonlightRemoteCleanup::Confirmed;
        }
        const bool responseUnknown = std::any_of(
            hostResult.diagnostics.begin(), hostResult.diagnostics.end(), [](const auto& item) {
                return item.sendState == MoonlightTransportSendState::SentResponseUnknown;
            });
        if (hostResult.mutationOutcomeUnknown ||
            hostResult.error == MoonlightHostError::ActionUnknown || responseUnknown) {
            return MoonlightRemoteCleanup::OutcomeUnknown;
        }
        return MoonlightRemoteCleanup::Failed;
    } catch (...) {
        return MoonlightRemoteCleanup::Failed;
    }
}

} // namespace

MoonlightPairingManager::MoonlightPairingManager(
    std::shared_ptr<MoonlightHostApi> hostApi,
    std::shared_ptr<MoonlightSecureIdentity> secureIdentity,
    std::shared_ptr<MoonlightPairingTrustPort> trustPort,
    std::shared_ptr<MoonlightPairingTlsBindingPort> tlsBindingPort,
    std::shared_ptr<MoonlightPairingCommitPort> commitPort, Entropy entropy,
    MonotonicClock monotonicClock, WallClock wallClock) {
    if (!monotonicClock) {
        monotonicClock = []() { return std::chrono::steady_clock::now(); };
    }
    if (!wallClock) {
        wallClock = []() {
            return static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::system_clock::now().time_since_epoch())
                    .count());
        };
    }
    impl_ = std::make_shared<Impl>(std::move(hostApi), std::move(secureIdentity),
                                   std::move(trustPort), std::move(tlsBindingPort),
                                   std::move(commitPort), std::move(entropy),
                                   std::move(monotonicClock), std::move(wallClock));
}

MoonlightPairingManager::~MoonlightPairingManager() {
    const auto impl = std::atomic_exchange_explicit(
        &impl_, std::shared_ptr<Impl>{}, std::memory_order_acq_rel);
    if (impl == nullptr) {
        return;
    }
    std::vector<MoonlightPairingOperationKey> keys;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        impl->shuttingDown = true;
        keys.reserve(impl->activeKeys.size());
        for (const auto& item : impl->activeKeys) {
            item.second->cancelled.store(true, std::memory_order_release);
            keys.push_back(item.first);
        }
    }
    for (const auto& key : keys) {
        if (impl->hostApi != nullptr) {
            impl->hostApi->cancel(hostKey(key));
        }
        if (impl->secureIdentity != nullptr) {
            impl->secureIdentity->cancel(identityKey(key));
        }
        if (impl->trustPort != nullptr) {
            impl->trustPort->cancel(key);
        }
        if (impl->tlsBindingPort != nullptr) {
            impl->tlsBindingPort->cancel(key);
        }
        if (impl->commitPort != nullptr) {
            impl->commitPort->cancel(key);
        }
    }
    std::unique_lock<std::mutex> lock(impl->mutex);
    impl->cv.wait(lock, [&]() { return impl->activeKeys.empty(); });
}

MoonlightPairingResult MoonlightPairingManager::execute(MoonlightPairingRequest request) noexcept {
    MoonlightPairingResult result;
    auto transition = [&](MoonlightPairingStage stage) {
        result.stageTrace.push_back(stage);
        result.terminalStage = stage;
    };
    transition(MoonlightPairingStage::Idle);

    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            result.code = MoonlightPairingCode::ShuttingDown;
            transition(MoonlightPairingStage::Failed);
            return result;
        }
        if (!validateRequestShape(request)) {
            result.code = MoonlightPairingCode::InvalidArgument;
            transition(MoonlightPairingStage::Failed);
            return result;
        }
        if (request.serverMajorVersion < 7U && !request.allowLegacySha1) {
            result.code = MoonlightPairingCode::LegacySha1Disabled;
            transition(MoonlightPairingStage::Failed);
            return result;
        }

        const auto network =
            remotedesk::net::ProcessNetworkGenerationFence().snapshot();
        if (!network.available || network.generation == 0U ||
            (request.expectedNetworkGeneration != 0U &&
             request.expectedNetworkGeneration != network.generation)) {
            result.code = MoonlightPairingCode::Stale;
            transition(MoonlightPairingStage::Failed);
            return result;
        }
        const std::string lane = laneFor(request);
        auto active = std::make_shared<ActivePairing>(request.key, lane, network);
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            if (impl->shuttingDown) {
                result.code = MoonlightPairingCode::ShuttingDown;
                transition(MoonlightPairingStage::Failed);
                return result;
            }
            if (impl->repairBlockedLanes.find(lane) != impl->repairBlockedLanes.end() ||
                (impl->commitPort != nullptr &&
                 impl->commitPort->repairRequired(request.identityScope.ownerScopeFingerprint,
                                                  request.hostId))) {
                result.code = MoonlightPairingCode::RepairRequired;
                result.repairRequired = true;
                transition(MoonlightPairingStage::Failed);
                return result;
            }
            if (impl->activeLanes.find(lane) != impl->activeLanes.end() ||
                impl->activeKeys.find(request.key) != impl->activeKeys.end()) {
                result.code = MoonlightPairingCode::Busy;
                transition(MoonlightPairingStage::Failed);
                return result;
            }
            impl->activeLanes.emplace(lane, active);
            try {
                impl->activeKeys.emplace(request.key, active);
            } catch (...) {
                impl->activeLanes.erase(lane);
                throw;
            }
        }
        ActiveLease activeLease(impl, active);
        const auto deadline = impl->monotonicClock() + request.timeout;
        bool remoteMutationPossible = false;
        bool cleanupHandled = false;
        ScopeExit exceptionCleanup([&]() {
            if (remoteMutationPossible && !cleanupHandled) {
                result.remoteCleanup = runRemoteCleanup(
                    impl, request, result, active->network.generation);
            }
        });
        BindingLease bindingLease(impl->tlsBindingPort, request.key);

        auto stoppedCode = [&]() -> std::optional<MoonlightPairingCode> {
            if (active->cancelled.load(std::memory_order_acquire)) {
                return MoonlightPairingCode::Cancelled;
            }
            if (!active->network.available ||
                remotedesk::net::ProcessNetworkGenerationFence().shouldCancel(
                    active->network)) {
                return MoonlightPairingCode::Stale;
            }
            if (impl->monotonicClock() >= deadline) {
                return MoonlightPairingCode::DeadlineExceeded;
            }
            return std::nullopt;
        };
        auto finish = [&](MoonlightPairingCode code, bool cleanup) {
            if (code == MoonlightPairingCode::Cancelled ||
                code == MoonlightPairingCode::DeadlineExceeded) {
                transition(MoonlightPairingStage::Cancelling);
            }
            if (cleanup && remoteMutationPossible) {
                result.remoteCleanup = runRemoteCleanup(
                    impl, request, result, active->network.generation);
            }
            cleanupHandled = true;
            exceptionCleanup.disarm();
            result.code = code;
            transition(code == MoonlightPairingCode::Cancelled
                           ? MoonlightPairingStage::Cancelled
                           : MoonlightPairingStage::Failed);
            return result;
        };
        auto runCall = [&](MoonlightHostCall& call, bool longPairWait) {
            QueryWiper queryWiper(call);
            call.key = hostKey(request.key);
            call.endpoint = request.endpoint;
            call.expectedNetworkGeneration = active->network.generation;
            if (const auto stopped = stoppedCode(); stopped.has_value()) {
                MoonlightHostResult stoppedResult;
                stoppedResult.key = call.key;
                stoppedResult.error = *stopped == MoonlightPairingCode::Cancelled
                                          ? MoonlightHostError::Cancelled
                                      : *stopped == MoonlightPairingCode::Stale
                                          ? MoonlightHostError::StaleRequest
                                          : MoonlightHostError::DeadlineExceeded;
                observeHostResult(stoppedResult, result);
                return stoppedResult;
            }
            const auto remaining = remainingTimeout(impl, deadline, longPairWait);
            if (remaining < MoonlightHostLimits::kMinTimeout) {
                MoonlightHostResult stoppedResult;
                stoppedResult.key = call.key;
                stoppedResult.error = MoonlightHostError::DeadlineExceeded;
                observeHostResult(stoppedResult, result);
                return stoppedResult;
            }
            call.timeout = remaining;
            auto hostResult = impl->hostApi->execute(call);
            observeHostResult(hostResult, result);
            remoteMutationPossible = remoteMutationPossible || possiblySent(hostResult);
            return hostResult;
        };

        transition(MoonlightPairingStage::Preflight);
        if (impl->hostApi == nullptr || impl->secureIdentity == nullptr ||
            impl->trustPort == nullptr || impl->tlsBindingPort == nullptr ||
            impl->commitPort == nullptr || !impl->entropy || !impl->monotonicClock ||
            !impl->wallClock || !impl->trustPort->available() ||
            !impl->tlsBindingPort->available() || !impl->commitPort->available()) {
            return finish(MoonlightPairingCode::Unavailable, false);
        }
        const auto capability = impl->secureIdentity->capability();
        if (capability.status != MoonlightIdentityCapabilityStatus::RuntimeReady ||
            !capability.encryptedBlobAtomic ||
            (!capability.directRsaTlsSignerReady && !capability.wrappedPkcs8Ready)) {
            return finish(MoonlightPairingCode::Unavailable, false);
        }
        MoonlightHostCall preflight;
        QueryWiper preflightWiper(preflight);
        preflight.key = hostKey(request.key);
        preflight.operation = MoonlightHostOperation::Pair;
        preflight.endpoint = request.endpoint;
        preflight.timeout = request.timeout;
        preflight.query = {{"phrase", "getservercert"},
                           {"salt", "00000000000000000000000000000000"},
                           {"clientcert", "00"}};
        if (impl->hostApi->validate(preflight) != MoonlightHostError::None) {
            return finish(MoonlightPairingCode::InvalidArgument, false);
        }
        if (const auto stopped = stoppedCode(); stopped.has_value()) {
            return finish(*stopped, false);
        }

        const EVP_MD* pairingHash = request.serverMajorVersion >= 7U ? EVP_sha256() : EVP_sha1();
        const int hashLengthValue = EVP_MD_get_size(pairingHash);
        if (hashLengthValue <= 0) {
            return finish(MoonlightPairingCode::CryptoFailure, false);
        }
        const auto hashLength = static_cast<std::size_t>(hashLengthValue);
        MoonlightSecureBuffer salt(std::vector<std::uint8_t>(kSecretBytes, 0U));
        MoonlightSecureBuffer clientChallenge(std::vector<std::uint8_t>(kSecretBytes, 0U));
        MoonlightSecureBuffer clientSecret(std::vector<std::uint8_t>(kSecretBytes, 0U));
        if (!impl->entropy(salt.data(), salt.size()) ||
            !impl->entropy(clientChallenge.data(), clientChallenge.size()) ||
            !impl->entropy(clientSecret.data(), clientSecret.size())) {
            return finish(MoonlightPairingCode::CryptoFailure, false);
        }
        MoonlightSecureBuffer fullKeyDigest;
        if (!digestParts(pairingHash,
                         {{salt.data(), salt.size()}, {request.pin.data(), request.pin.size()}},
                         fullKeyDigest)) {
            return finish(MoonlightPairingCode::CryptoFailure, false);
        }
        MoonlightSecureBuffer aesKey;
        if (!secureSlice(fullKeyDigest, 0U, kSecretBytes, aesKey)) {
            return finish(MoonlightPairingCode::CryptoFailure, false);
        }

        const auto ensured = impl->secureIdentity->ensure(request.identityScope,
                                                          identityKey(request.key));
        if (ensured.code != MoonlightIdentityCode::Ok) {
            return finish(mapIdentityCode(ensured.code), false);
        }
        auto acquired = impl->secureIdentity->acquire(request.identityScope,
                                                      identityKey(request.key));
        if (acquired.code != MoonlightIdentityCode::Ok || !acquired.lease.valid()) {
            return finish(mapIdentityCode(acquired.code), false);
        }
        if (acquired.lease.certificatePem().empty() ||
            acquired.lease.certificatePem().size() > kMaxIdentityPemBytes) {
            return finish(MoonlightPairingCode::IdentityFailure, false);
        }
        MoonlightSecureBuffer clientCertificateSignature;
        if (!certificateSignature(acquired.lease.certificateDer(), clientCertificateSignature)) {
            return finish(MoonlightPairingCode::IdentityFailure, false);
        }

        transition(MoonlightPairingStage::WaitingForServerCertificate);
        MoonlightHostCall getCertificate;
        getCertificate.operation = MoonlightHostOperation::Pair;
        getCertificate.query.push_back({"phrase", "getservercert"});
        getCertificate.query.push_back({"salt", hexEncode(salt.data(), salt.size())});
        getCertificate.query.push_back(
            {"clientcert",
             hexEncode(reinterpret_cast<const std::uint8_t*>(
                           acquired.lease.certificatePem().data()),
                       acquired.lease.certificatePem().size())});
        auto certificateResult = runCall(getCertificate, true);
        if (!certificateResult.ok()) {
            const auto code = mapHostCode(certificateResult);
            wipePairingPayload(certificateResult);
            return finish(code, true);
        }
        if (!certificateResult.pairing.has_value() ||
            !certificateResult.pairing->paired.value_or(false) ||
            !certificateResult.pairing->plainCertificateHex.has_value() ||
            !hasOnlyPairingPayload(*certificateResult.pairing, true, false, false)) {
            const auto code = certificateResult.pairing.has_value() &&
                                      certificateResult.pairing->paired.value_or(false)
                                  ? MoonlightPairingCode::AlreadyInProgress
                                  : MoonlightPairingCode::ProtocolFailure;
            wipePairingPayload(certificateResult);
            return finish(code, true);
        }
        MoonlightSecureBuffer serverCertificateBytes;
        const bool certificateHexValid =
            hexDecode(*certificateResult.pairing->plainCertificateHex, kMaxCertificateBytes,
                      serverCertificateBytes);
        wipePairingPayload(certificateResult);
        if (!certificateHexValid) {
            return finish(MoonlightPairingCode::CertificateInvalid, true);
        }
        std::vector<std::uint8_t> serverCertificateEncoded(
            serverCertificateBytes.data(),
            serverCertificateBytes.data() + serverCertificateBytes.size());
        ParsedCertificate serverCertificate;
        if (!parseCertificate(serverCertificateEncoded, request.hostId, request.hostLabel,
                              impl->wallClock(),
                              serverCertificate)) {
            return finish(MoonlightPairingCode::CertificateInvalid, true);
        }
        result.certificateSha256 = serverCertificate.candidate.certificateSha256;

        transition(MoonlightPairingStage::AwaitingTrust);
        MoonlightTrustReview review;
        try {
            review = impl->trustPort->review(
                request.key, serverCertificate.candidate, deadline,
                [&stoppedCode]() { return stoppedCode().has_value(); });
        } catch (...) {
            return finish(MoonlightPairingCode::Unavailable, true);
        }
        if (const auto stopped = stoppedCode(); stopped.has_value()) {
            return finish(*stopped, true);
        }
        result.trustChange = review.change;
        if (review.decision != MoonlightTrustDecision::Accept) {
            const auto code = review.decision == MoonlightTrustDecision::Reject
                                  ? MoonlightPairingCode::TrustRejected
                              : review.decision == MoonlightTrustDecision::Timeout
                                  ? MoonlightPairingCode::TrustTimeout
                              : review.decision == MoonlightTrustDecision::Cancelled
                                  ? MoonlightPairingCode::Cancelled
                              : review.decision == MoonlightTrustDecision::Stale
                                  ? MoonlightPairingCode::Stale
                                  : MoonlightPairingCode::Unavailable;
            return finish(code, true);
        }
        if (const auto stopped = stoppedCode(); stopped.has_value()) {
            return finish(*stopped, true);
        }
        MoonlightPairingPortCode bindCode = MoonlightPairingPortCode::Unavailable;
        try {
            bindCode = impl->tlsBindingPort->bind(
                request.key, request.endpoint, serverCertificate.canonicalDer,
                serverCertificate.candidate.certificateSha256, deadline,
                [&stoppedCode]() { return stoppedCode().has_value(); },
                acquired.lease);
        } catch (...) {
            bindCode = MoonlightPairingPortCode::Unavailable;
        }
        bindingLease.markBound();
        if (const auto stopped = stoppedCode(); stopped.has_value()) {
            return finish(*stopped, true);
        }
        if (bindCode != MoonlightPairingPortCode::Ok) {
            const auto code = bindCode == MoonlightPairingPortCode::Cancelled
                                  ? MoonlightPairingCode::Cancelled
                              : bindCode == MoonlightPairingPortCode::Stale
                                  ? MoonlightPairingCode::Stale
                                  : MoonlightPairingCode::Unavailable;
            return finish(code, true);
        }
        transition(MoonlightPairingStage::ClientChallenge);
        MoonlightSecureBuffer encryptedClientChallenge;
        if (!aesBlockTransform(true, clientChallenge, aesKey, clientChallenge.size(),
                               encryptedClientChallenge)) {
            return finish(MoonlightPairingCode::CryptoFailure, true);
        }
        MoonlightHostCall challengeCall;
        challengeCall.operation = MoonlightHostOperation::Pair;
        challengeCall.query.push_back(
            {"clientchallenge",
             hexEncode(encryptedClientChallenge.data(), encryptedClientChallenge.size())});
        auto challengeResult = runCall(challengeCall, false);
        if (!challengeResult.ok()) {
            const auto code = mapHostCode(challengeResult);
            wipePairingPayload(challengeResult);
            return finish(code, true);
        }
        if (!challengeResult.pairing.has_value() ||
            !challengeResult.pairing->paired.value_or(false) ||
            !challengeResult.pairing->challengeResponseHex.has_value() ||
            !hasOnlyPairingPayload(*challengeResult.pairing, false, true, false)) {
            wipePairingPayload(challengeResult);
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }
        MoonlightSecureBuffer encryptedServerResponse;
        const std::size_t serverResponseLogicalSize = hashLength + kSecretBytes;
        const std::size_t serverResponseRoundedSize =
            (serverResponseLogicalSize + (kSecretBytes - 1U)) & ~(kSecretBytes - 1U);
        const bool responseHexValid =
            hexDecode(*challengeResult.pairing->challengeResponseHex,
                      serverResponseRoundedSize, encryptedServerResponse) &&
            encryptedServerResponse.size() == serverResponseRoundedSize;
        wipePairingPayload(challengeResult);
        if (!responseHexValid) {
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }

        transition(MoonlightPairingStage::ServerChallenge);
        MoonlightSecureBuffer decryptedServerResponse;
        if (!aesBlockTransform(false, encryptedServerResponse, aesKey,
                               serverResponseLogicalSize, decryptedServerResponse)) {
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }
        MoonlightSecureBuffer expectedServerResponse;
        MoonlightSecureBuffer serverChallenge;
        if (!secureSlice(decryptedServerResponse, 0U, hashLength, expectedServerResponse) ||
            !secureSlice(decryptedServerResponse, hashLength, kSecretBytes, serverChallenge)) {
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }
        MoonlightSecureBuffer challengeHash;
        if (!digestParts(pairingHash,
                         {{serverChallenge.data(), serverChallenge.size()},
                          {clientCertificateSignature.data(), clientCertificateSignature.size()},
                          {clientSecret.data(), clientSecret.size()}},
                         challengeHash)) {
            return finish(MoonlightPairingCode::CryptoFailure, true);
        }
        MoonlightSecureBuffer encryptedChallengeHash;
        if (!aesBlockTransform(true, challengeHash, aesKey, challengeHash.size(),
                               encryptedChallengeHash)) {
            return finish(MoonlightPairingCode::CryptoFailure, true);
        }

        MoonlightHostCall responseCall;
        responseCall.operation = MoonlightHostOperation::Pair;
        responseCall.query.push_back(
            {"serverchallengeresp",
             hexEncode(encryptedChallengeHash.data(), encryptedChallengeHash.size())});
        auto secretResult = runCall(responseCall, false);
        if (!secretResult.ok()) {
            const auto code = mapHostCode(secretResult);
            wipePairingPayload(secretResult);
            return finish(code, true);
        }
        if (!secretResult.pairing.has_value() ||
            !secretResult.pairing->paired.value_or(false) ||
            !secretResult.pairing->pairingSecretHex.has_value() ||
            !hasOnlyPairingPayload(*secretResult.pairing, false, false, true)) {
            wipePairingPayload(secretResult);
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }
        MoonlightSecureBuffer signedServerSecret;
        const bool serverSecretHexValid =
            hexDecode(*secretResult.pairing->pairingSecretHex,
                      kSecretBytes + kMaxSignatureBytes, signedServerSecret) &&
            signedServerSecret.size() > kSecretBytes;
        wipePairingPayload(secretResult);
        if (!serverSecretHexValid) {
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }

        transition(MoonlightPairingStage::SecretVerification);
        MoonlightSecureBuffer serverSecret;
        MoonlightSecureBuffer serverSecretSignature;
        if (!secureSlice(signedServerSecret, 0U, kSecretBytes, serverSecret) ||
            !secureSlice(signedServerSecret, kSecretBytes,
                         signedServerSecret.size() - kSecretBytes, serverSecretSignature)) {
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }
        if (!verifyServerSignature(serverCertificate.certificate.get(), serverSecret,
                                   serverSecretSignature)) {
            return finish(MoonlightPairingCode::ServerAuthenticationFailed, true);
        }
        MoonlightSecureBuffer actualServerResponse;
        if (!digestParts(pairingHash,
                         {{clientChallenge.data(), clientChallenge.size()},
                          {serverCertificate.signature.data(), serverCertificate.signature.size()},
                          {serverSecret.data(), serverSecret.size()}},
                         actualServerResponse)) {
            return finish(MoonlightPairingCode::CryptoFailure, true);
        }
        if (actualServerResponse.size() != expectedServerResponse.size() ||
            CRYPTO_memcmp(actualServerResponse.data(), expectedServerResponse.data(),
                          actualServerResponse.size()) != 0) {
            return finish(MoonlightPairingCode::PinWrong, true);
        }

        transition(MoonlightPairingStage::ClientSecret);
        std::vector<std::uint8_t> clientSecretMessage(
            clientSecret.data(), clientSecret.data() + clientSecret.size());
        ByteVectorWiper clientSecretMessageWiper(clientSecretMessage);
        std::vector<std::uint8_t> clientSignatureBytes;
        const auto signCode = acquired.lease.signSha256(
            clientSecretMessage, clientSignatureBytes);
        MoonlightSecureBuffer clientSignature(std::move(clientSignatureBytes));
        if (signCode != MoonlightIdentityCode::Ok || clientSignature.empty()) {
            return finish(MoonlightPairingCode::IdentityFailure, true);
        }
        MoonlightSecureBuffer clientPairingSecret;
        if (!appendSecure(clientSecret, clientSignature, clientPairingSecret)) {
            return finish(MoonlightPairingCode::CryptoFailure, true);
        }
        MoonlightHostCall clientSecretCall;
        clientSecretCall.operation = MoonlightHostOperation::Pair;
        clientSecretCall.query.push_back(
            {"clientpairingsecret",
             hexEncode(clientPairingSecret.data(), clientPairingSecret.size())});
        auto clientSecretResult = runCall(clientSecretCall, false);
        if (!clientSecretResult.ok()) {
            const auto code = mapHostCode(clientSecretResult);
            wipePairingPayload(clientSecretResult);
            return finish(code, true);
        }
        if (!clientSecretResult.pairing.has_value() ||
            !clientSecretResult.pairing->paired.value_or(false) ||
            !hasOnlyPairingPayload(*clientSecretResult.pairing, false, false, false)) {
            wipePairingPayload(clientSecretResult);
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }
        wipePairingPayload(clientSecretResult);

        transition(MoonlightPairingStage::FinalChallenge);
        if (const auto stopped = stoppedCode(); stopped.has_value()) {
            return finish(*stopped, true);
        }
        MoonlightHostCall finalChallenge;
        finalChallenge.operation = MoonlightHostOperation::PairChallenge;
        finalChallenge.endpoint = request.endpoint;
        finalChallenge.endpoint.pinnedTrustAvailable = true;
        QueryWiper finalWiper(finalChallenge);
        finalChallenge.key = hostKey(request.key);
        finalChallenge.expectedNetworkGeneration = active->network.generation;
        const auto finalRemaining = remainingTimeout(impl, deadline, false);
        if (finalRemaining < MoonlightHostLimits::kMinTimeout) {
            return finish(MoonlightPairingCode::DeadlineExceeded, true);
        }
        finalChallenge.timeout = finalRemaining;
        auto finalResult = impl->hostApi->execute(finalChallenge);
        observeHostResult(finalResult, result);
        remoteMutationPossible = remoteMutationPossible || possiblySent(finalResult);
        if (!finalResult.ok()) {
            const auto code = mapHostCode(finalResult);
            wipePairingPayload(finalResult);
            return finish(code, true);
        }
        if (!finalResult.pairing.has_value() ||
            !finalResult.pairing->paired.value_or(false) ||
            !hasOnlyPairingPayload(*finalResult.pairing, false, false, false)) {
            wipePairingPayload(finalResult);
            return finish(MoonlightPairingCode::ProtocolFailure, true);
        }
        wipePairingPayload(finalResult);

        transition(MoonlightPairingStage::Committing);
        if (const auto stopped = stoppedCode(); stopped.has_value()) {
            return finish(*stopped, true);
        }
        MoonlightPairingCommitRecord record;
        record.key = request.key;
        record.ownerScopeFingerprint = request.identityScope.ownerScopeFingerprint;
        record.hostId = request.hostId;
        record.serverUuid = request.serverUuid;
        record.certificateSha256 = serverCertificate.candidate.certificateSha256;
        record.localSecureStoreRef = acquired.lease.metadata().localSecureStoreRef;
        record.identityVersion = acquired.lease.metadata().identityVersion;
        record.pairingGeneration = request.key.generation;
        record.observedAtMs = impl->wallClock();
        record.trustChange = review.change;

        MoonlightPairingPortCode commitCode = MoonlightPairingPortCode::OutcomeUnknown;
        try {
            commitCode = impl->commitPort->commit(record);
        } catch (...) {
            commitCode = MoonlightPairingPortCode::OutcomeUnknown;
        }
        if (commitCode == MoonlightPairingPortCode::Ok) {
            cleanupHandled = true;
            exceptionCleanup.disarm();
            result.code = MoonlightPairingCode::Ok;
            transition(MoonlightPairingStage::Paired);
            return result;
        }
        if (commitCode == MoonlightPairingPortCode::OutcomeUnknown) {
            impl->commitPort->recordRepairRequired(record);
            try {
                std::lock_guard<std::mutex> lock(impl->mutex);
                impl->repairBlockedLanes.insert(lane);
            } catch (...) {
                // The durable commit-port fence remains authoritative if the
                // process-local acceleration set cannot grow.
            }
            result.code = MoonlightPairingCode::RepairRequired;
            result.repairRequired = true;
            cleanupHandled = true;
            exceptionCleanup.disarm();
            transition(MoonlightPairingStage::Failed);
            return result;
        }
        result.localRollbackAttempted = true;
        const auto rollbackCode = impl->commitPort->rollback(record);
        result.localRollbackSucceeded = rollbackCode == MoonlightPairingPortCode::Ok;
        if (!result.localRollbackSucceeded) {
            impl->commitPort->recordRepairRequired(record);
            try {
                std::lock_guard<std::mutex> lock(impl->mutex);
                impl->repairBlockedLanes.insert(lane);
            } catch (...) {
                // The durable commit-port fence remains authoritative.
            }
            result.repairRequired = true;
        }
        const auto commitFailureCode = commitCode == MoonlightPairingPortCode::Cancelled
                                           ? MoonlightPairingCode::Cancelled
                                       : commitCode == MoonlightPairingPortCode::Stale
                                           ? MoonlightPairingCode::Stale
                                       : result.repairRequired
                                           ? MoonlightPairingCode::RepairRequired
                                           : MoonlightPairingCode::CommitFailed;
        return finish(commitFailureCode, true);
    } catch (...) {
        result.code = result.terminalStage == MoonlightPairingStage::Committing
                          ? MoonlightPairingCode::CommitFailed
                          : MoonlightPairingCode::CryptoFailure;
        transition(MoonlightPairingStage::Failed);
        return result;
    }
}

bool MoonlightPairingManager::cancel(const MoonlightPairingOperationKey& key) noexcept {
    if (!key.valid()) {
        return false;
    }
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            return false;
        }
        std::shared_ptr<ActivePairing> active;
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            const auto iterator = impl->activeKeys.find(key);
            if (iterator == impl->activeKeys.end()) {
                return false;
            }
            active = iterator->second;
            bool expected = false;
            if (!active->cancelled.compare_exchange_strong(expected, true,
                                                           std::memory_order_acq_rel)) {
                return false;
            }
        }
        if (impl->hostApi != nullptr) {
            impl->hostApi->cancel(hostKey(key));
        }
        if (impl->secureIdentity != nullptr) {
            impl->secureIdentity->cancel(identityKey(key));
        }
        if (impl->trustPort != nullptr) {
            impl->trustPort->cancel(key);
        }
        if (impl->tlsBindingPort != nullptr) {
            impl->tlsBindingPort->cancel(key);
        }
        if (impl->commitPort != nullptr) {
            impl->commitPort->cancel(key);
        }
        return true;
    } catch (...) {
        return false;
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::uint64_t MoonlightPairingManager::secureCleanseCountForTesting() noexcept {
    return gPairingCleanseCount.load(std::memory_order_relaxed);
}

void MoonlightPairingManager::resetSecureCleanseCountForTesting() noexcept {
    gPairingCleanseCount.store(0U, std::memory_order_relaxed);
}
#endif

} // namespace remotedesk::moonlight
