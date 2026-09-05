#include "moonlight/pairing/MoonlightPairingManager.h"
#include "common/network_generation_fence.h"
#include "test_runner.h"

#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

const std::string OWNER(64U, 'c');
constexpr std::uint64_t NOW_MS = 1780000000000ULL;

struct TestStoredIdentity final {
    MoonlightIdentityMetadata metadata;
    std::vector<std::uint8_t> certificateDer;
    std::string certificatePem;
    std::vector<std::uint8_t> privateKey;
};

class PairingIdentityBackend final : public MoonlightIdentityBackend {
public:
    MoonlightIdentityCapability capability() const noexcept override {
        MoonlightIdentityCapability value;
        value.status = available_ ? MoonlightIdentityCapabilityStatus::RuntimeReady
                                  : MoonlightIdentityCapabilityStatus::Unavailable;
        value.storageMode = MoonlightIdentityStorageMode::HuksWrappedPkcs8;
        value.huksApiLinked = available_;
        value.assetApiLinked = available_;
        value.wrappedPkcs8Ready = available_;
        value.encryptedBlobAtomic = available_;
        value.secureBufferPageLockSupported = true;
        return value;
    }

    MoonlightIdentityBackendLoadResult load(const std::string& alias) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto iterator = records_.find(alias);
        if (iterator == records_.end()) {
            return {MoonlightIdentityBackendCode::NotFound, nullptr};
        }
        auto record = std::make_unique<MoonlightIdentityStoredRecord>();
        record->metadata = iterator->second.metadata;
        record->certificateDer = iterator->second.certificateDer;
        record->certificatePem = iterator->second.certificatePem;
        record->privateKeyPkcs8 = MoonlightSecureBuffer(iterator->second.privateKey);
        return {MoonlightIdentityBackendCode::Ok, std::move(record)};
    }

    MoonlightIdentityBackendCode store(const MoonlightIdentityStoredRecord& record,
                                       bool replaceExisting) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto& alias = record.metadata.localSecureStoreRef;
        const bool exists = records_.find(alias) != records_.end();
        if (exists != replaceExisting) {
            return MoonlightIdentityBackendCode::Conflict;
        }
        TestStoredIdentity stored;
        stored.metadata = record.metadata;
        stored.certificateDer = record.certificateDer;
        stored.certificatePem = record.certificatePem;
        stored.privateKey.assign(record.privateKeyPkcs8.data(),
                                 record.privateKeyPkcs8.data() + record.privateKeyPkcs8.size());
        records_[alias] = std::move(stored);
        return MoonlightIdentityBackendCode::Ok;
    }

    MoonlightIdentityBackendCode erase(const std::string& alias) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        return records_.erase(alias) == 1U ? MoonlightIdentityBackendCode::Ok
                                           : MoonlightIdentityBackendCode::NotFound;
    }

    MoonlightIdentityBackendListResult list(
        const std::string& ownerScopeFingerprint) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        MoonlightIdentityBackendListResult result;
        result.code = MoonlightIdentityBackendCode::Ok;
        for (const auto& item : records_) {
            if (item.second.metadata.ownerScopeFingerprint == ownerScopeFingerprint) {
                result.records.push_back(item.second.metadata);
            }
        }
        return result;
    }

    void setAvailable(bool value) noexcept { available_ = value; }

private:
    mutable std::mutex mutex_;
    std::map<std::string, TestStoredIdentity> records_;
    bool available_ = true;
};

class Barrier final {
public:
    void enter() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            entered_ = true;
        }
        cv_.notify_all();
    }

    bool waitEntered() {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, 2s, [&]() { return entered_; });
    }

    void release() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            released_ = true;
        }
        cv_.notify_all();
    }

    void waitReleased() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [&]() { return released_; });
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool entered_ = false;
    bool released_ = false;
};

std::string hexEncode(const std::uint8_t* bytes, std::size_t size) {
    constexpr char HEX[] = "0123456789ABCDEF";
    std::string output(size * 2U, '0');
    for (std::size_t index = 0; index < size; ++index) {
        output[index * 2U] = HEX[bytes[index] >> 4U];
        output[index * 2U + 1U] = HEX[bytes[index] & 0x0fU];
    }
    return output;
}

int nibble(char value) {
    if (value >= '0' && value <= '9')
        return value - '0';
    if (value >= 'A' && value <= 'F')
        return value - 'A' + 10;
    if (value >= 'a' && value <= 'f')
        return value - 'a' + 10;
    return -1;
}

std::vector<std::uint8_t> hexDecode(const std::string& text) {
    if ((text.size() & 1U) != 0U) {
        return {};
    }
    std::vector<std::uint8_t> output(text.size() / 2U, 0U);
    for (std::size_t index = 0; index < output.size(); ++index) {
        const int high = nibble(text[index * 2U]);
        const int low = nibble(text[index * 2U + 1U]);
        if (high < 0 || low < 0) {
            return {};
        }
        output[index] = static_cast<std::uint8_t>((high << 4) | low);
    }
    return output;
}

std::string queryValue(const std::string& url, const std::string& name) {
    const std::string needle = name + "=";
    const auto start = url.find(needle);
    if (start == std::string::npos) {
        return {};
    }
    const auto valueStart = start + needle.size();
    const auto end = url.find('&', valueStart);
    return url.substr(valueStart, end == std::string::npos ? std::string::npos : end - valueStart);
}

std::vector<std::string> queryNames(const std::string& url) {
    std::vector<std::string> output;
    auto offset = url.find('?');
    if (offset == std::string::npos) {
        return output;
    }
    ++offset;
    while (offset < url.size()) {
        const auto equals = url.find('=', offset);
        if (equals == std::string::npos)
            break;
        output.push_back(url.substr(offset, equals - offset));
        const auto ampersand = url.find('&', equals + 1U);
        if (ampersand == std::string::npos)
            break;
        offset = ampersand + 1U;
    }
    return output;
}

std::vector<std::uint8_t> digest(
    const EVP_MD* algorithm,
    const std::vector<std::pair<const std::uint8_t*, std::size_t>>& parts) {
    EVP_MD_CTX* context = EVP_MD_CTX_new();
    if (context == nullptr || EVP_DigestInit_ex(context, algorithm, nullptr) != 1) {
        EVP_MD_CTX_free(context);
        return {};
    }
    for (const auto& part : parts) {
        if (EVP_DigestUpdate(context, part.first, part.second) != 1) {
            EVP_MD_CTX_free(context);
            return {};
        }
    }
    std::vector<std::uint8_t> output(static_cast<std::size_t>(EVP_MD_get_size(algorithm)), 0U);
    unsigned int written = 0;
    const bool ok = EVP_DigestFinal_ex(context, output.data(), &written) == 1 &&
                    written == output.size();
    EVP_MD_CTX_free(context);
    return ok ? output : std::vector<std::uint8_t>{};
}

std::vector<std::uint8_t> aesTransform(bool encrypt, const std::vector<std::uint8_t>& input,
                                       const std::vector<std::uint8_t>& key) {
    const std::size_t rounded = (input.size() + 15U) & ~15U;
    std::vector<std::uint8_t> padded(rounded, 0U);
    std::copy(input.begin(), input.end(), padded.begin());
    std::vector<std::uint8_t> output(rounded, 0U);
    EVP_CIPHER_CTX* context = EVP_CIPHER_CTX_new();
    int written = 0;
    int finalBytes = 0;
    const bool ok = context != nullptr &&
                    (encrypt ? EVP_EncryptInit_ex(context, EVP_aes_128_ecb(), nullptr, key.data(),
                                                  nullptr)
                             : EVP_DecryptInit_ex(context, EVP_aes_128_ecb(), nullptr, key.data(),
                                                  nullptr)) == 1 &&
                    EVP_CIPHER_CTX_set_padding(context, 0) == 1 &&
                    (encrypt ? EVP_EncryptUpdate(context, output.data(), &written, padded.data(),
                                                 static_cast<int>(padded.size()))
                             : EVP_DecryptUpdate(context, output.data(), &written, padded.data(),
                                                 static_cast<int>(padded.size()))) == 1 &&
                    (encrypt ? EVP_EncryptFinal_ex(context, output.data() + written, &finalBytes)
                             : EVP_DecryptFinal_ex(context, output.data() + written, &finalBytes)) ==
                        1;
    EVP_CIPHER_CTX_free(context);
    return ok ? output : std::vector<std::uint8_t>{};
}

struct TestCertificate final {
    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key{nullptr, EVP_PKEY_free};
    std::unique_ptr<X509, decltype(&X509_free)> certificate{nullptr, X509_free};
    std::vector<std::uint8_t> der;
    std::vector<std::uint8_t> pem;
    std::vector<std::uint8_t> signature;
};

TestCertificate makeCertificate() {
    TestCertificate output;
    EVP_PKEY_CTX* keyContext = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
    EVP_PKEY* rawKey = nullptr;
    if (keyContext == nullptr || EVP_PKEY_keygen_init(keyContext) != 1 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(keyContext, 2048) != 1 ||
        EVP_PKEY_keygen(keyContext, &rawKey) != 1) {
        EVP_PKEY_CTX_free(keyContext);
        return output;
    }
    EVP_PKEY_CTX_free(keyContext);
    output.key.reset(rawKey);
    output.certificate.reset(X509_new());
    if (output.certificate == nullptr || X509_set_version(output.certificate.get(), 2L) != 1 ||
        ASN1_INTEGER_set(X509_get_serialNumber(output.certificate.get()), 7L) != 1 ||
        X509_set_pubkey(output.certificate.get(), output.key.get()) != 1) {
        return {};
    }
    X509_gmtime_adj(X509_getm_notBefore(output.certificate.get()), -60L);
    X509_gmtime_adj(X509_getm_notAfter(output.certificate.get()), 86400L);
    X509_NAME* name = X509_get_subject_name(output.certificate.get());
    const unsigned char commonName[] = "Sunshine Pairing Fixture";
    if (name == nullptr || X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, commonName, -1, -1,
                                                       0) != 1 ||
        X509_set_issuer_name(output.certificate.get(), name) != 1 ||
        X509_sign(output.certificate.get(), output.key.get(), EVP_sha256()) <= 0) {
        return {};
    }
    const int derSize = i2d_X509(output.certificate.get(), nullptr);
    if (derSize <= 0) {
        return {};
    }
    output.der.resize(static_cast<std::size_t>(derSize));
    unsigned char* cursor = output.der.data();
    if (i2d_X509(output.certificate.get(), &cursor) != derSize) {
        return {};
    }
    BIO* rawBio = BIO_new(BIO_s_mem());
    if (rawBio == nullptr ||
        PEM_write_bio_X509(rawBio, output.certificate.get()) != 1) {
        BIO_free(rawBio);
        return {};
    }
    const std::unique_ptr<BIO, decltype(&BIO_free)> bio(rawBio, BIO_free);
    char* pemData = nullptr;
    const long pemSize = BIO_get_mem_data(bio.get(), &pemData);
    if (pemSize <= 0 || pemData == nullptr) {
        return {};
    }
    output.pem.assign(reinterpret_cast<std::uint8_t*>(pemData),
                      reinterpret_cast<std::uint8_t*>(pemData) + pemSize);
    const ASN1_BIT_STRING* signature = nullptr;
    const X509_ALGOR* algorithm = nullptr;
    X509_get0_signature(&signature, &algorithm, output.certificate.get());
    static_cast<void>(algorithm);
    output.signature.assign(signature->data, signature->data + signature->length);
    return output;
}

std::vector<std::uint8_t> sign(EVP_PKEY* key, const std::vector<std::uint8_t>& message) {
    EVP_MD_CTX* context = EVP_MD_CTX_new();
    std::size_t size = 0;
    if (context == nullptr ||
        EVP_DigestSignInit(context, nullptr, EVP_sha256(), nullptr, key) != 1 ||
        EVP_DigestSignUpdate(context, message.data(), message.size()) != 1 ||
        EVP_DigestSignFinal(context, nullptr, &size) != 1) {
        EVP_MD_CTX_free(context);
        return {};
    }
    std::vector<std::uint8_t> signature(size, 0U);
    if (EVP_DigestSignFinal(context, signature.data(), &size) != 1) {
        EVP_MD_CTX_free(context);
        return {};
    }
    EVP_MD_CTX_free(context);
    signature.resize(size);
    return signature;
}

bool verify(EVP_PKEY* key, const std::vector<std::uint8_t>& message,
            const std::vector<std::uint8_t>& signature) {
    EVP_MD_CTX* context = EVP_MD_CTX_new();
    const bool ok = context != nullptr &&
                    EVP_DigestVerifyInit(context, nullptr, EVP_sha256(), nullptr, key) == 1 &&
                    EVP_DigestVerifyUpdate(context, message.data(), message.size()) == 1 &&
                    EVP_DigestVerifyFinal(context, signature.data(), signature.size()) == 1;
    EVP_MD_CTX_free(context);
    return ok;
}

struct BindingState final {
    std::mutex mutex;
    bool active = false;
    std::string fingerprint;
};

class TestTlsPort final : public MoonlightPairingTlsBindingPort {
public:
    explicit TestTlsPort(std::shared_ptr<BindingState> state) : state_(std::move(state)) {}

    bool available() const noexcept override { return available_; }
    MoonlightPairingPortCode bind(const MoonlightPairingOperationKey&,
                                  const MoonlightHostEndpoint&,
                                  const std::vector<std::uint8_t>& certificateDer,
                                  const std::string& fingerprint,
                                  std::chrono::steady_clock::time_point,
                                  const CancellationProbe& cancellationProbe,
                                  MoonlightIdentityLease& identityLease) override {
        if (barrier_ != nullptr) {
            barrier_->enter();
            barrier_->waitReleased();
        }
        if (cancellationProbe()) {
            return MoonlightPairingPortCode::Cancelled;
        }
        SSL_CTX* context = SSL_CTX_new(TLS_client_method());
        const unsigned char* cursor = certificateDer.data();
        const std::unique_ptr<X509, decltype(&X509_free)> canonical(
            certificateDer.empty() ? nullptr : d2i_X509(
                nullptr, &cursor, static_cast<long>(certificateDer.size())), X509_free);
        canonicalDerReceived_ = canonical != nullptr &&
            cursor == certificateDer.data() + certificateDer.size();
        const bool configured = context != nullptr && canonicalDerReceived_ &&
                                identityLease.configureTlsContext(context) ==
                                    MoonlightIdentityCode::Ok;
        SSL_CTX_free(context);
        if (!configured) {
            return MoonlightPairingPortCode::KnownFailure;
        }
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->active = true;
        state_->fingerprint = fingerprint;
        return MoonlightPairingPortCode::Ok;
    }
    void cancel(const MoonlightPairingOperationKey&) noexcept override {
        ++cancelCount_;
        if (barrier_ != nullptr) {
            barrier_->release();
        }
    }
    void unbind(const MoonlightPairingOperationKey&) noexcept override {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->active = false;
        ++unbindCount_;
    }
    void setAvailable(bool value) noexcept { available_ = value; }
    std::size_t unbindCount() const noexcept { return unbindCount_; }
    std::size_t cancelCount() const noexcept { return cancelCount_; }
    bool canonicalDerReceived() const noexcept { return canonicalDerReceived_; }
    Barrier* barrier_ = nullptr;

private:
    std::shared_ptr<BindingState> state_;
    bool available_ = true;
    bool canonicalDerReceived_ = false;
    std::atomic<std::size_t> unbindCount_{0U};
    std::atomic<std::size_t> cancelCount_{0U};
};

class TestTrustPort final : public MoonlightPairingTrustPort {
public:
    bool available() const noexcept override { return available_; }
    MoonlightTrustReview review(const MoonlightPairingOperationKey&,
                                const MoonlightTrustCandidate& candidate,
                                std::chrono::steady_clock::time_point,
                                const CancellationProbe& cancellationProbe) override {
        ++reviewCount_;
        lastCandidate_ = candidate;
        if (barrier_ != nullptr) {
            barrier_->enter();
            barrier_->waitReleased();
        }
        if (onReview_) {
            onReview_();
        }
        if (cancellationProbe()) {
            return {MoonlightTrustDecision::Cancelled, MoonlightTrustChange::Unknown};
        }
        return review_;
    }
    void cancel(const MoonlightPairingOperationKey&) noexcept override {
        ++cancelCount_;
        if (barrier_ != nullptr) {
            barrier_->release();
        }
    }

    bool available_ = true;
    MoonlightTrustReview review_{MoonlightTrustDecision::Accept, MoonlightTrustChange::FirstUse};
    Barrier* barrier_ = nullptr;
    std::function<void()> onReview_;
    std::atomic<std::size_t> reviewCount_{0U};
    std::atomic<std::size_t> cancelCount_{0U};
    MoonlightTrustCandidate lastCandidate_;
};

class TestCommitPort final : public MoonlightPairingCommitPort {
public:
    bool available() const noexcept override { return available_; }
    bool repairRequired(const std::string&, const std::string&) const noexcept override {
        return repairRequired_;
    }
    MoonlightPairingPortCode commit(const MoonlightPairingCommitRecord& record) override {
        ++commitCount_;
        record_ = record;
        if (barrier_ != nullptr) {
            barrier_->enter();
            barrier_->waitReleased();
        }
        if (code_ == MoonlightPairingPortCode::OutcomeUnknown) {
            repairRequired_ = true;
        }
        return code_;
    }
    MoonlightPairingPortCode rollback(const MoonlightPairingCommitRecord&) noexcept override {
        ++rollbackCount_;
        return rollbackCode_;
    }
    void recordRepairRequired(const MoonlightPairingCommitRecord&) noexcept override {
        repairRequired_ = true;
        ++repairRecordCount_;
    }
    void cancel(const MoonlightPairingOperationKey&) noexcept override {
        ++cancelCount_;
        if (barrier_ != nullptr) {
            barrier_->release();
        }
    }

    bool available_ = true;
    mutable bool repairRequired_ = false;
    MoonlightPairingPortCode code_ = MoonlightPairingPortCode::Ok;
    MoonlightPairingPortCode rollbackCode_ = MoonlightPairingPortCode::Ok;
    Barrier* barrier_ = nullptr;
    std::atomic<std::size_t> commitCount_{0U};
    std::atomic<std::size_t> rollbackCount_{0U};
    std::atomic<std::size_t> repairRecordCount_{0U};
    std::atomic<std::size_t> cancelCount_{0U};
    MoonlightPairingCommitRecord record_;
};

enum class ServerFault : std::uint8_t {
    None = 0,
    EmptyCertificate,
    MalformedCertificate,
    OversizedCertificate,
    BadServerSignature,
    MalformedChallenge,
    UnexpectedChallengeField,
    MalformedServerSecret,
    HttpFailureAtServerResponse,
    MalformedXmlAtServerResponse,
    RejectClientSecret,
    RejectFinalChallenge,
    MaybeSentAtClientChallenge,
    UnpairUnknown,
};

struct CapturedPairStep final {
    MoonlightHostOperation operation = MoonlightHostOperation::Pair;
    MoonlightHostScheme scheme = MoonlightHostScheme::Http;
    std::vector<std::string> queryNames;
    std::string redacted;
};

class TranscriptTransport final : public MoonlightHostTransport {
public:
    TranscriptTransport(std::shared_ptr<BindingState> binding, std::string expectedPin)
        : binding_(std::move(binding)), expectedPin_(std::move(expectedPin)),
          certificate_(makeCertificate()), serverSecret_(16U, 0x41U),
          serverChallenge_(16U, 0x52U) {}

    MoonlightTransportOutcome execute(const MoonlightTransportRequest& request,
                                      std::chrono::steady_clock::time_point,
                                      const CancellationProbe& cancellationProbe) override {
        currentResolvedAddress_ = request.connectAddress();
        currentResolvedFamily_ = request.family();
        CapturedPairStep capture;
        capture.operation = request.operation();
        capture.scheme = request.scheme();
        capture.queryNames = queryNames(request.url());
        capture.redacted = request.redactedDebugString();
        captures_.push_back(std::move(capture));
        if (cancellationProbe()) {
            return failure(MoonlightTransportError::Cancelled,
                           MoonlightTransportSendState::NotSent);
        }
        if (request.operation() == MoonlightHostOperation::Unpair) {
            ++unpairCount_;
            if (fault_ == ServerFault::UnpairUnknown) {
                return failure(MoonlightTransportError::Timeout,
                               MoonlightTransportSendState::SentResponseUnknown);
            }
            return response("<root status_code=\"200\"/>");
        }
        if (request.operation() == MoonlightHostOperation::PairChallenge) {
            std::lock_guard<std::mutex> lock(binding_->mutex);
            if (request.scheme() != MoonlightHostScheme::Https || !binding_->active ||
                binding_->fingerprint.empty()) {
                return failure(MoonlightTransportError::TrustConflict,
                               MoonlightTransportSendState::NotSent);
            }
            return fault_ == ServerFault::RejectFinalChallenge
                       ? response("<root status_code=\"200\"><paired>0</paired></root>")
                       : pairedResponse();
        }
        if (queryValue(request.url(), "phrase") == "getservercert") {
            return getCertificate(request.url());
        }
        if (!queryValue(request.url(), "clientchallenge").empty()) {
            if (fault_ == ServerFault::MaybeSentAtClientChallenge) {
                return failure(MoonlightTransportError::Timeout,
                               MoonlightTransportSendState::SentResponseUnknown);
            }
            return clientChallenge(request.url());
        }
        if (!queryValue(request.url(), "serverchallengeresp").empty()) {
            return serverChallengeResponse(request.url());
        }
        if (!queryValue(request.url(), "clientpairingsecret").empty()) {
            return clientPairingSecret(request.url());
        }
        return failure(MoonlightTransportError::ProtocolFailure,
                       MoonlightTransportSendState::NotSent);
    }

    void setFault(ServerFault fault) noexcept { fault_ = fault; }
    void setLegacySha1(bool value) noexcept { legacySha1_ = value; }
    void setPemCertificate(bool value) noexcept { pemCertificate_ = value; }
    const std::vector<CapturedPairStep>& captures() const noexcept { return captures_; }
    std::size_t unpairCount() const noexcept { return unpairCount_; }
    bool transcriptVerified() const noexcept { return transcriptVerified_; }

private:
    MoonlightTransportOutcome response(const std::string& body) const {
        MoonlightTransportOutcome result;
        result.stage = MoonlightTransportStage::Body;
        result.sendState = MoonlightTransportSendState::ConfirmedResponse;
        result.httpStatus = 200;
        result.body = body;
        result.receivedBodyBytes = body.size();
        result.resolvedAddress = currentResolvedAddress_;
        result.resolvedFamily = currentResolvedFamily_;
        return result;
    }

    MoonlightTransportOutcome pairedResponse() const {
        return response("<root status_code=\"200\"><paired>1</paired></root>");
    }

    static MoonlightTransportOutcome failure(MoonlightTransportError error,
                                             MoonlightTransportSendState sendState) {
        MoonlightTransportOutcome result;
        result.error = error;
        result.stage = MoonlightTransportStage::Body;
        result.sendState = sendState;
        return result;
    }

    static MoonlightTransportOutcome httpFailure() {
        MoonlightTransportOutcome result;
        result.stage = MoonlightTransportStage::Http;
        result.sendState = MoonlightTransportSendState::ConfirmedResponse;
        result.httpStatus = 500;
        return result;
    }

    std::vector<std::uint8_t> aesKey(const std::vector<std::uint8_t>& salt) const {
        std::vector<std::uint8_t> pin(expectedPin_.begin(), expectedPin_.end());
        auto key = digest(hashAlgorithm(), {{salt.data(), salt.size()}, {pin.data(), pin.size()}});
        key.resize(16U);
        return key;
    }

    const EVP_MD* hashAlgorithm() const noexcept {
        return legacySha1_ ? EVP_sha1() : EVP_sha256();
    }

    MoonlightTransportOutcome getCertificate(const std::string& url) {
        const auto salt = hexDecode(queryValue(url, "salt"));
        const auto clientPem = hexDecode(queryValue(url, "clientcert"));
        key_ = aesKey(salt);
        BIO* bio = BIO_new_mem_buf(clientPem.data(), static_cast<int>(clientPem.size()));
        clientCertificate_.reset(
            bio == nullptr ? nullptr : PEM_read_bio_X509(bio, nullptr, nullptr, nullptr));
        BIO_free(bio);
        if (clientCertificate_ == nullptr) {
            return pairedResponse();
        }
        const ASN1_BIT_STRING* signature = nullptr;
        const X509_ALGOR* algorithm = nullptr;
        X509_get0_signature(&signature, &algorithm, clientCertificate_.get());
        static_cast<void>(algorithm);
        clientCertificateSignature_.assign(signature->data, signature->data + signature->length);
        if (fault_ == ServerFault::EmptyCertificate) {
            return pairedResponse();
        }
        std::string certHex;
        if (fault_ == ServerFault::MalformedCertificate) {
            certHex = "00FF";
        } else if (fault_ == ServerFault::OversizedCertificate) {
            certHex.assign((64U * 1024U + 1U) * 2U, 'A');
        } else {
            const auto& encoded = pemCertificate_ ? certificate_.pem : certificate_.der;
            certHex = hexEncode(encoded.data(), encoded.size());
        }
        return response("<root status_code=\"200\"><paired>1</paired><plaincert>" + certHex +
                        "</plaincert></root>");
    }

    MoonlightTransportOutcome clientChallenge(const std::string& url) {
        const auto encrypted = hexDecode(queryValue(url, "clientchallenge"));
        clientChallenge_ = aesTransform(false, encrypted, key_);
        clientChallenge_.resize(16U);
        auto responseHash = digest(
            hashAlgorithm(), {{clientChallenge_.data(), clientChallenge_.size()},
                              {certificate_.signature.data(), certificate_.signature.size()},
                              {serverSecret_.data(), serverSecret_.size()}});
        std::vector<std::uint8_t> plaintext = responseHash;
        plaintext.insert(plaintext.end(), serverChallenge_.begin(), serverChallenge_.end());
        auto encryptedResponse = aesTransform(true, plaintext, key_);
        if (fault_ == ServerFault::MalformedChallenge) {
            encryptedResponse.pop_back();
        }
        const std::string unexpected = fault_ == ServerFault::UnexpectedChallengeField
                                           ? "<pairingsecret>00</pairingsecret>"
                                           : "";
        return response("<root status_code=\"200\"><paired>1</paired><challengeresponse>" +
                        hexEncode(encryptedResponse.data(), encryptedResponse.size()) +
                        "</challengeresponse>" + unexpected + "</root>");
    }

    MoonlightTransportOutcome serverChallengeResponse(const std::string& url) {
        if (fault_ == ServerFault::HttpFailureAtServerResponse) {
            return httpFailure();
        }
        if (fault_ == ServerFault::MalformedXmlAtServerResponse) {
            return response("<root status_code=\"200\"><paired>1</paired>");
        }
        const auto encrypted = hexDecode(queryValue(url, "serverchallengeresp"));
        clientChallengeHash_ = aesTransform(false, encrypted, key_);
        clientChallengeHash_.resize(
            static_cast<std::size_t>(EVP_MD_get_size(hashAlgorithm())));
        auto signature = sign(certificate_.key.get(), serverSecret_);
        if (fault_ == ServerFault::BadServerSignature && !signature.empty()) {
            signature[0] ^= 0x80U;
        }
        std::vector<std::uint8_t> signedSecret = serverSecret_;
        signedSecret.insert(signedSecret.end(), signature.begin(), signature.end());
        if (fault_ == ServerFault::MalformedServerSecret) {
            return response("<root status_code=\"200\"><paired>1</paired>"
                            "<pairingsecret>ABC</pairingsecret></root>");
        }
        return response("<root status_code=\"200\"><paired>1</paired><pairingsecret>" +
                        hexEncode(signedSecret.data(), signedSecret.size()) +
                        "</pairingsecret></root>");
    }

    MoonlightTransportOutcome clientPairingSecret(const std::string& url) {
        if (fault_ == ServerFault::RejectClientSecret) {
            return response("<root status_code=\"200\"><paired>0</paired></root>");
        }
        const auto signedSecret = hexDecode(queryValue(url, "clientpairingsecret"));
        if (signedSecret.size() <= 16U || clientCertificate_ == nullptr) {
            return response("<root status_code=\"200\"><paired>0</paired></root>");
        }
        const std::vector<std::uint8_t> clientSecret(signedSecret.begin(),
                                                     signedSecret.begin() + 16);
        const std::vector<std::uint8_t> signature(signedSecret.begin() + 16, signedSecret.end());
        auto expected = digest(
            hashAlgorithm(),
            {{serverChallenge_.data(), serverChallenge_.size()},
             {clientCertificateSignature_.data(), clientCertificateSignature_.size()},
             {clientSecret.data(), clientSecret.size()}});
        EVP_PKEY* rawKey = X509_get_pubkey(clientCertificate_.get());
        const std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key(rawKey, EVP_PKEY_free);
        transcriptVerified_ = key != nullptr && expected == clientChallengeHash_ &&
                              verify(key.get(), clientSecret, signature);
        return transcriptVerified_
                   ? pairedResponse()
                   : response("<root status_code=\"200\"><paired>0</paired></root>");
    }

    std::shared_ptr<BindingState> binding_;
    std::string expectedPin_;
    TestCertificate certificate_;
    std::unique_ptr<X509, decltype(&X509_free)> clientCertificate_{nullptr, X509_free};
    std::vector<std::uint8_t> clientCertificateSignature_;
    std::vector<std::uint8_t> serverSecret_;
    std::vector<std::uint8_t> serverChallenge_;
    std::vector<std::uint8_t> clientChallenge_;
    std::vector<std::uint8_t> clientChallengeHash_;
    std::vector<std::uint8_t> key_;
    std::vector<CapturedPairStep> captures_;
    std::string currentResolvedAddress_;
    MoonlightHostAddressFamily currentResolvedFamily_ =
        MoonlightHostAddressFamily::Unspecified;
    ServerFault fault_ = ServerFault::None;
    std::size_t unpairCount_ = 0U;
    bool transcriptVerified_ = false;
    bool legacySha1_ = false;
    bool pemCertificate_ = true;
};

MoonlightPairingRequest requestFor(std::uint64_t id, const std::string& pin = "1234") {
    MoonlightPairingRequest request;
    request.key = {id, id + 100U, id + 200U};
    request.identityScope = {OWNER, "install-pairing-fixture"};
    request.endpoint.serverName = "sunshine.test";
    request.endpoint.addresses = {{"192.0.2.40", MoonlightHostAddressFamily::Ipv4}};
    request.hostId = "host-fixture-01";
    request.serverUuid = "server-fixture-01";
    request.hostLabel = "Gaming PC";
    request.serverMajorVersion = 7U;
    request.timeout = 120s;
    request.pin = MoonlightSecureBuffer(std::vector<std::uint8_t>(pin.begin(), pin.end()));
    return request;
}

struct PairingFixture final {
    PairingIdentityBackend* identityBackend = nullptr;
    std::shared_ptr<MoonlightSecureIdentity> identity;
    std::shared_ptr<BindingState> binding = std::make_shared<BindingState>();
    std::shared_ptr<TestTlsPort> tls = std::make_shared<TestTlsPort>(binding);
    std::shared_ptr<TestTrustPort> trust = std::make_shared<TestTrustPort>();
    std::shared_ptr<TestCommitPort> commit = std::make_shared<TestCommitPort>();
    std::shared_ptr<TranscriptTransport> transport =
        std::make_shared<TranscriptTransport>(binding, "1234");
    std::shared_ptr<MoonlightHostApi> host = std::make_shared<MoonlightHostApi>(
        transport, []() { return std::string("00000000-0000-4000-8000-000000000001"); });
    std::unique_ptr<MoonlightPairingManager> manager;

    PairingFixture() {
        auto backend = std::make_unique<PairingIdentityBackend>();
        identityBackend = backend.get();
        identity = std::make_shared<MoonlightSecureIdentity>(std::move(backend), []() {
            return NOW_MS;
        });
        auto entropyCall = std::make_shared<std::atomic<unsigned>>(0U);
        manager = std::make_unique<MoonlightPairingManager>(
            host, identity, trust, tls, commit,
            [entropyCall](std::uint8_t* output, std::size_t size) {
                const unsigned call = entropyCall->fetch_add(1U);
                const auto base = static_cast<std::uint8_t>(0x10U + call * 0x10U);
                for (std::size_t index = 0; index < size; ++index) {
                    output[index] = static_cast<std::uint8_t>(base + index);
                }
                return true;
            });
    }
};

bool traceContains(const MoonlightPairingResult& result, MoonlightPairingStage stage) {
    return std::find(result.stageTrace.begin(), result.stageTrace.end(), stage) !=
           result.stageTrace.end();
}

} // namespace

RDP_TEST_CASE(moonlight_pairing_executes_official_sha256_transcript_and_commits_exact_record) {
    MoonlightPairingManager::resetSecureCleanseCountForTesting();
    MoonlightSecureIdentity::resetSecureCleanseCountForTesting();
    PairingFixture fixture;
    const auto result = fixture.manager->execute(requestFor(1U));
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(result.terminalStage, MoonlightPairingStage::Paired);
    RDP_ASSERT(fixture.transport->transcriptVerified());
    RDP_ASSERT(fixture.tls->canonicalDerReceived());
    RDP_ASSERT_EQ(fixture.commit->commitCount_.load(), static_cast<std::size_t>(1));
    RDP_ASSERT(fixture.commit->record_.ownerScopeFingerprint == OWNER);
    RDP_ASSERT(fixture.commit->record_.hostId == "host-fixture-01");
    RDP_ASSERT(fixture.commit->record_.pairingGeneration == 101U);
    RDP_ASSERT(!result.certificateSha256.empty());
    RDP_ASSERT(fixture.commit->record_.certificateSha256 == result.certificateSha256);
    RDP_ASSERT(fixture.trust->lastCandidate_.hostLabel == "Gaming PC");
    RDP_ASSERT(fixture.trust->lastCandidate_.maskedHost.rfind("host:", 0U) == 0U);
    RDP_ASSERT(fixture.trust->lastCandidate_.maskedHost.find("host-fixture-01") ==
               std::string::npos);
    RDP_ASSERT(traceContains(result, MoonlightPairingStage::AwaitingTrust));
    RDP_ASSERT(traceContains(result, MoonlightPairingStage::FinalChallenge));
    RDP_ASSERT_EQ(fixture.transport->captures().size(), static_cast<std::size_t>(5));
    RDP_ASSERT_EQ(fixture.transport->captures()[0].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT_EQ(fixture.transport->captures()[1].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT_EQ(fixture.transport->captures()[2].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT_EQ(fixture.transport->captures()[3].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT_EQ(fixture.transport->captures()[4].scheme, MoonlightHostScheme::Https);
    for (const auto& capture : fixture.transport->captures()) {
        RDP_ASSERT(capture.redacted.find("1234") == std::string::npos);
        RDP_ASSERT(capture.redacted.find("10111213") == std::string::npos);
    }
    RDP_ASSERT(MoonlightPairingManager::secureCleanseCountForTesting() >= 10U);
    RDP_ASSERT(MoonlightSecureIdentity::secureCleanseCountForTesting() >= 10U);
    RDP_ASSERT_EQ(fixture.tls->unbindCount(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_pairing_keeps_strict_der_compatibility_after_sunshine_pem_normalization) {
    PairingFixture fixture;
    fixture.transport->setPemCertificate(false);
    const auto result = fixture.manager->execute(requestFor(2U));
    RDP_ASSERT(result.ok());
    RDP_ASSERT(fixture.transport->transcriptVerified());
    RDP_ASSERT(fixture.tls->canonicalDerReceived());
}

RDP_TEST_CASE(moonlight_pairing_fails_closed_before_network_for_legacy_ports_identity_and_entropy) {
    {
        PairingFixture fixture;
        auto request = requestFor(10U);
        request.serverMajorVersion = 6U;
        const auto result = fixture.manager->execute(std::move(request));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::LegacySha1Disabled);
        RDP_ASSERT(fixture.transport->captures().empty());
    }
    {
        PairingFixture fixture;
        fixture.trust->available_ = false;
        const auto result = fixture.manager->execute(requestFor(11U));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::Unavailable);
        RDP_ASSERT(fixture.transport->captures().empty());
    }
    {
        PairingFixture fixture;
        fixture.identityBackend->setAvailable(false);
        const auto result = fixture.manager->execute(requestFor(12U));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::Unavailable);
        RDP_ASSERT(fixture.transport->captures().empty());
    }
    {
        PairingFixture fixture;
        fixture.manager = std::make_unique<MoonlightPairingManager>(
            fixture.host, fixture.identity, fixture.trust, fixture.tls, fixture.commit,
            [](std::uint8_t*, std::size_t) { return false; });
        const auto result = fixture.manager->execute(requestFor(13U));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::CryptoFailure);
        RDP_ASSERT(fixture.transport->captures().empty());
    }
}

RDP_TEST_CASE(moonlight_pairing_fences_serverinfo_generation_and_cross_generation_cleanup) {
    auto& fence = remotedesk::net::ProcessNetworkGenerationFence();
    const auto beforeAdmission = fence.snapshot();
    RDP_ASSERT(beforeAdmission.available);
    RDP_ASSERT(beforeAdmission.generation <
               std::numeric_limits<std::uint64_t>::max());
    {
        PairingFixture fixture;
        auto request = requestFor(14U);
        request.expectedNetworkGeneration = beforeAdmission.generation;
        RDP_ASSERT(fence.update(true, beforeAdmission.generation + 1U));
        const auto result = fixture.manager->execute(std::move(request));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::Stale);
        RDP_ASSERT(fixture.transport->captures().empty());
    }

    const auto duringPairing = fence.snapshot();
    RDP_ASSERT(duringPairing.available);
    RDP_ASSERT(duringPairing.generation <
               std::numeric_limits<std::uint64_t>::max());
    PairingFixture fixture;
    fixture.trust->onReview_ = [&fence, duringPairing]() {
        RDP_ASSERT(fence.update(true, duringPairing.generation + 1U));
    };
    auto request = requestFor(19U);
    request.expectedNetworkGeneration = duringPairing.generation;
    const auto result = fixture.manager->execute(std::move(request));
    RDP_ASSERT_EQ(result.code, MoonlightPairingCode::Stale);
    RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Failed);
    RDP_ASSERT_EQ(fixture.transport->unpairCount(), static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.transport->captures().size(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_pairing_legacy_sha1_requires_explicit_policy_and_keeps_official_shape) {
    PairingFixture fixture;
    fixture.transport->setLegacySha1(true);
    auto request = requestFor(15U);
    request.serverMajorVersion = 6U;
    request.allowLegacySha1 = true;
    const auto result = fixture.manager->execute(std::move(request));
    RDP_ASSERT(result.ok());
    RDP_ASSERT(fixture.transport->transcriptVerified());
    RDP_ASSERT_EQ(fixture.transport->captures().size(), static_cast<std::size_t>(5));
}

RDP_TEST_CASE(moonlight_pairing_rejects_invalid_pin_and_absolute_deadline_before_first_packet) {
    {
        PairingFixture fixture;
        const auto result = fixture.manager->execute(requestFor(16U, "12A4"));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::InvalidArgument);
        RDP_ASSERT(fixture.transport->captures().empty());
    }
    {
        PairingFixture fixture;
        const auto base = std::chrono::steady_clock::time_point(1000ms);
        auto clockCalls = std::make_shared<std::atomic<unsigned>>(0U);
        fixture.manager = std::make_unique<MoonlightPairingManager>(
            fixture.host, fixture.identity, fixture.trust, fixture.tls, fixture.commit,
            [](std::uint8_t* output, std::size_t size) {
                std::fill_n(output, size, static_cast<std::uint8_t>(0x55U));
                return true;
            },
            [base, clockCalls]() {
                return clockCalls->fetch_add(1U) == 0U ? base : base + 121s;
            });
        const auto result = fixture.manager->execute(requestFor(17U));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::DeadlineExceeded);
        RDP_ASSERT(fixture.transport->captures().empty());
    }
    {
        PairingFixture fixture;
        const auto base = std::chrono::steady_clock::time_point(2000ms);
        auto clockCalls = std::make_shared<std::atomic<unsigned>>(0U);
        fixture.manager = std::make_unique<MoonlightPairingManager>(
            fixture.host, fixture.identity, fixture.trust, fixture.tls, fixture.commit,
            [](std::uint8_t* output, std::size_t size) {
                std::fill_n(output, size, static_cast<std::uint8_t>(0x66U));
                return true;
            },
            [base, clockCalls]() {
                return clockCalls->fetch_add(1U) < 3U ? base : base + 119950ms;
            });
        const auto result = fixture.manager->execute(requestFor(18U));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::DeadlineExceeded);
        RDP_ASSERT(fixture.transport->captures().empty());
    }
}

RDP_TEST_CASE(moonlight_pairing_maps_wrong_pin_and_server_signature_mitm_and_cleans_remote) {
    {
        PairingFixture fixture;
        const auto result = fixture.manager->execute(requestFor(20U, "9999"));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::PinWrong);
        RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
        RDP_ASSERT_EQ(fixture.transport->unpairCount(), static_cast<std::size_t>(1));
        RDP_ASSERT_EQ(fixture.commit->commitCount_.load(), static_cast<std::size_t>(0));
    }
    {
        PairingFixture fixture;
        fixture.transport->setFault(ServerFault::BadServerSignature);
        const auto result = fixture.manager->execute(requestFor(21U));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::ServerAuthenticationFailed);
        RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
        RDP_ASSERT_EQ(fixture.commit->commitCount_.load(), static_cast<std::size_t>(0));
    }
}

RDP_TEST_CASE(moonlight_pairing_rejects_empty_malformed_certificate_and_malformed_hex_shape) {
    for (const auto item :
         {std::pair{ServerFault::EmptyCertificate, MoonlightPairingCode::AlreadyInProgress},
          std::pair{ServerFault::MalformedCertificate, MoonlightPairingCode::CertificateInvalid},
          std::pair{ServerFault::MalformedChallenge, MoonlightPairingCode::ProtocolFailure}}) {
        PairingFixture fixture;
        fixture.transport->setFault(item.first);
        const auto result = fixture.manager->execute(requestFor(30U));
        RDP_ASSERT_EQ(result.code, item.second);
        RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
        RDP_ASSERT_EQ(fixture.transport->unpairCount(), static_cast<std::size_t>(1));
    }
}

RDP_TEST_CASE(moonlight_pairing_rejects_oversized_and_late_stage_protocol_failures) {
    for (const auto item :
         {std::pair{ServerFault::OversizedCertificate,
                    MoonlightPairingCode::CertificateInvalid},
          std::pair{ServerFault::MalformedServerSecret,
                    MoonlightPairingCode::MutationOutcomeUnknown},
          std::pair{ServerFault::HttpFailureAtServerResponse,
                    MoonlightPairingCode::TransportFailure},
          std::pair{ServerFault::MalformedXmlAtServerResponse,
                    MoonlightPairingCode::MutationOutcomeUnknown},
          std::pair{ServerFault::RejectClientSecret,
                    MoonlightPairingCode::ProtocolFailure},
          std::pair{ServerFault::RejectFinalChallenge,
                    MoonlightPairingCode::ProtocolFailure}}) {
        PairingFixture fixture;
        fixture.transport->setFault(item.first);
        const auto result = fixture.manager->execute(requestFor(32U));
        RDP_ASSERT_EQ(result.code, item.second);
        RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
        RDP_ASSERT_EQ(fixture.commit->commitCount_.load(), static_cast<std::size_t>(0));
        RDP_ASSERT_EQ(fixture.transport->unpairCount(), static_cast<std::size_t>(1));
    }
}

RDP_TEST_CASE(moonlight_pairing_rejects_cross_stage_response_fields) {
    PairingFixture fixture;
    fixture.transport->setFault(ServerFault::UnexpectedChallengeField);
    const auto result = fixture.manager->execute(requestFor(31U));
    RDP_ASSERT_EQ(result.code, MoonlightPairingCode::ProtocolFailure);
    RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
    RDP_ASSERT_EQ(fixture.commit->commitCount_.load(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_pairing_trust_reject_timeout_stale_never_commits) {
    for (const auto item :
         {std::pair{MoonlightTrustDecision::Reject, MoonlightPairingCode::TrustRejected},
          std::pair{MoonlightTrustDecision::Timeout, MoonlightPairingCode::TrustTimeout},
          std::pair{MoonlightTrustDecision::Stale, MoonlightPairingCode::Stale}}) {
        PairingFixture fixture;
        fixture.trust->review_ = {item.first, MoonlightTrustChange::Changed};
        const auto result = fixture.manager->execute(requestFor(40U));
        RDP_ASSERT_EQ(result.code, item.second);
        RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
        RDP_ASSERT_EQ(fixture.commit->commitCount_.load(), static_cast<std::size_t>(0));
        RDP_ASSERT_EQ(fixture.tls->unbindCount(), static_cast<std::size_t>(0));
    }
}

RDP_TEST_CASE(moonlight_pairing_never_replays_maybe_sent_mutation_and_reports_cleanup_unknown) {
    PairingFixture fixture;
    fixture.transport->setFault(ServerFault::MaybeSentAtClientChallenge);
    const auto result = fixture.manager->execute(requestFor(50U));
    RDP_ASSERT_EQ(result.code, MoonlightPairingCode::MutationOutcomeUnknown);
    RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
    RDP_ASSERT_EQ(fixture.transport->captures().size(), static_cast<std::size_t>(3));
    RDP_ASSERT_EQ(fixture.transport->unpairCount(), static_cast<std::size_t>(1));

    PairingFixture unknownCleanup;
    unknownCleanup.transport->setFault(ServerFault::UnpairUnknown);
    unknownCleanup.trust->review_ = {MoonlightTrustDecision::Reject,
                                     MoonlightTrustChange::FirstUse};
    const auto unknown = unknownCleanup.manager->execute(requestFor(51U));
    RDP_ASSERT_EQ(unknown.code, MoonlightPairingCode::TrustRejected);
    RDP_ASSERT_EQ(unknown.remoteCleanup, MoonlightRemoteCleanup::OutcomeUnknown);
}

RDP_TEST_CASE(moonlight_pairing_commit_failure_rolls_back_and_unknown_freezes_lane) {
    {
        PairingFixture fixture;
        fixture.commit->code_ = MoonlightPairingPortCode::KnownFailure;
        const auto result = fixture.manager->execute(requestFor(60U));
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::CommitFailed);
        RDP_ASSERT(result.localRollbackAttempted);
        RDP_ASSERT(result.localRollbackSucceeded);
        RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
        RDP_ASSERT_EQ(fixture.commit->rollbackCount_.load(), static_cast<std::size_t>(1));
    }
    {
        PairingFixture fixture;
        fixture.commit->code_ = MoonlightPairingPortCode::OutcomeUnknown;
        const auto first = fixture.manager->execute(requestFor(61U));
        RDP_ASSERT_EQ(first.code, MoonlightPairingCode::RepairRequired);
        RDP_ASSERT(first.repairRequired);
        RDP_ASSERT_EQ(first.remoteCleanup, MoonlightRemoteCleanup::NotNeeded);
        RDP_ASSERT_EQ(fixture.commit->repairRecordCount_.load(), static_cast<std::size_t>(1));
        const auto captures = fixture.transport->captures().size();
        const auto second = fixture.manager->execute(requestFor(62U));
        RDP_ASSERT_EQ(second.code, MoonlightPairingCode::RepairRequired);
        RDP_ASSERT_EQ(fixture.transport->captures().size(), captures);
    }
    {
        PairingFixture fixture;
        fixture.commit->code_ = MoonlightPairingPortCode::KnownFailure;
        fixture.commit->rollbackCode_ = MoonlightPairingPortCode::OutcomeUnknown;
        const auto first = fixture.manager->execute(requestFor(63U));
        RDP_ASSERT_EQ(first.code, MoonlightPairingCode::RepairRequired);
        RDP_ASSERT(first.localRollbackAttempted);
        RDP_ASSERT(!first.localRollbackSucceeded);
        RDP_ASSERT(first.repairRequired);
        RDP_ASSERT_EQ(first.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
        RDP_ASSERT_EQ(fixture.commit->repairRecordCount_.load(), static_cast<std::size_t>(1));
        const auto captures = fixture.transport->captures().size();
        const auto second = fixture.manager->execute(requestFor(64U));
        RDP_ASSERT_EQ(second.code, MoonlightPairingCode::RepairRequired);
        RDP_ASSERT_EQ(fixture.transport->captures().size(), captures);
    }
}

RDP_TEST_CASE(moonlight_pairing_exact_cancel_and_concurrent_lane_busy_use_barriers) {
    PairingFixture fixture;
    Barrier trustBarrier;
    fixture.trust->barrier_ = &trustBarrier;
    MoonlightPairingResult first;
    std::thread worker([&]() { first = fixture.manager->execute(requestFor(70U)); });
    RDP_ASSERT(trustBarrier.waitEntered());

    const auto busy = fixture.manager->execute(requestFor(71U));
    RDP_ASSERT_EQ(busy.code, MoonlightPairingCode::Busy);
    RDP_ASSERT(!fixture.manager->cancel({70U, 999U, 270U}));
    RDP_ASSERT(fixture.manager->cancel({70U, 170U, 270U}));
    trustBarrier.release();
    worker.join();
    RDP_ASSERT_EQ(first.code, MoonlightPairingCode::Cancelled);
    RDP_ASSERT_EQ(first.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
    RDP_ASSERT_EQ(fixture.trust->cancelCount_.load(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_pairing_destructor_cancels_and_drains_trust_callback) {
    PairingFixture fixture;
    Barrier trustBarrier;
    fixture.trust->barrier_ = &trustBarrier;
    MoonlightPairingResult result;
    MoonlightPairingManager* manager = fixture.manager.get();
    std::thread worker([&]() { result = manager->execute(requestFor(75U)); });
    RDP_ASSERT(trustBarrier.waitEntered());
    std::thread destroyer([&]() { fixture.manager.reset(); });
    worker.join();
    destroyer.join();
    RDP_ASSERT_EQ(result.code, MoonlightPairingCode::Cancelled);
    RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
    RDP_ASSERT_EQ(fixture.trust->cancelCount_.load(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_pairing_cancel_drains_tls_bind_and_destructor_drains_commit) {
    {
        PairingFixture fixture;
        Barrier tlsBarrier;
        fixture.tls->barrier_ = &tlsBarrier;
        MoonlightPairingResult result;
        std::thread worker([&]() { result = fixture.manager->execute(requestFor(76U)); });
        RDP_ASSERT(tlsBarrier.waitEntered());
        RDP_ASSERT(fixture.manager->cancel({76U, 176U, 276U}));
        worker.join();
        RDP_ASSERT_EQ(result.code, MoonlightPairingCode::Cancelled);
        RDP_ASSERT_EQ(result.remoteCleanup, MoonlightRemoteCleanup::Confirmed);
        RDP_ASSERT_EQ(fixture.tls->cancelCount(), static_cast<std::size_t>(1));
        RDP_ASSERT_EQ(fixture.tls->unbindCount(), static_cast<std::size_t>(1));
    }
    {
        PairingFixture fixture;
        Barrier commitBarrier;
        fixture.commit->barrier_ = &commitBarrier;
        MoonlightPairingResult result;
        MoonlightPairingManager* manager = fixture.manager.get();
        std::thread worker([&]() { result = manager->execute(requestFor(77U)); });
        RDP_ASSERT(commitBarrier.waitEntered());
        std::thread destroyer([&]() { fixture.manager.reset(); });
        worker.join();
        destroyer.join();
        RDP_ASSERT(result.ok());
        RDP_ASSERT_EQ(fixture.commit->cancelCount_.load(), static_cast<std::size_t>(1));
    }
}

RDP_TEST_CASE(moonlight_pairing_commit_success_wins_late_cancel) {
    PairingFixture fixture;
    Barrier commitBarrier;
    fixture.commit->barrier_ = &commitBarrier;
    MoonlightPairingResult result;
    std::thread worker([&]() { result = fixture.manager->execute(requestFor(80U)); });
    RDP_ASSERT(commitBarrier.waitEntered());
    RDP_ASSERT(fixture.manager->cancel({80U, 180U, 280U}));
    commitBarrier.release();
    worker.join();
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(result.terminalStage, MoonlightPairingStage::Paired);
    RDP_ASSERT_EQ(fixture.transport->unpairCount(), static_cast<std::size_t>(0));
}
