#include "moonlight/security/MoonlightSecureIdentity.h"
#include "test_runner.h"

#include <openssl/asn1.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

constexpr std::uint64_t TEST_NOW_MS = 1760000000000ULL;
const std::string OWNER_A(64U, 'a');
const std::string OWNER_B(64U, 'b');

MoonlightIdentityScope scopeFor(const std::string& owner,
                                const std::string& installation) {
    return {owner, installation};
}

MoonlightIdentityOperationKey keyFor(std::uint64_t request) {
    return {request, request + 100U, request + 200U};
}

class Gate final {
public:
    void enterAndWait() noexcept {
        std::unique_lock<std::mutex> lock(mutex_);
        entered_ = true;
        cv_.notify_all();
        cv_.wait(lock, [this]() { return released_; });
    }

    bool waitEntered() {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, 2s, [this]() { return entered_; });
    }

    void release() noexcept {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            released_ = true;
        }
        cv_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool entered_ = false;
    bool released_ = false;
};

struct StoredBlob final {
    MoonlightIdentityMetadata metadata;
    std::vector<std::uint8_t> certificateDer;
    std::string certificatePem;
    std::vector<std::uint8_t> privateKeyPkcs8;
};

std::unique_ptr<MoonlightIdentityStoredRecord> cloneRecord(
    const StoredBlob& source) {
    auto result = std::make_unique<MoonlightIdentityStoredRecord>();
    result->metadata = source.metadata;
    result->certificateDer = source.certificateDer;
    result->certificatePem = source.certificatePem;
    result->privateKeyPkcs8 = MoonlightSecureBuffer(source.privateKeyPkcs8);
    return result;
}

class MemoryIdentityBackend final : public MoonlightIdentityBackend {
public:
    MoonlightIdentityCapability capability() const noexcept override {
        MoonlightIdentityCapability result;
        result.status = MoonlightIdentityCapabilityStatus::RuntimeReady;
        result.storageMode = MoonlightIdentityStorageMode::HuksWrappedPkcs8;
        result.huksApiLinked = true;
        result.assetApiLinked = true;
        result.wrappedPkcs8Ready = true;
        result.encryptedBlobAtomic = true;
        result.secureBufferPageLockSupported = true;
        return result;
    }

    MoonlightIdentityBackendLoadResult load(
        const std::string& alias) noexcept override {
        invoke(loadHook_);
        std::lock_guard<std::mutex> lock(mutex_);
        if (nextLoadCode_.has_value()) {
            const auto code = *nextLoadCode_;
            nextLoadCode_.reset();
            return {code, nullptr};
        }
        const auto iterator = records_.find(alias);
        if (iterator == records_.end()) {
            return {MoonlightIdentityBackendCode::NotFound, nullptr};
        }
        return {MoonlightIdentityBackendCode::Ok,
                cloneRecord(iterator->second)};
    }

    MoonlightIdentityBackendCode store(
        const MoonlightIdentityStoredRecord& record,
        bool replaceExisting) noexcept override {
        invoke(storeHook_);
        std::lock_guard<std::mutex> lock(mutex_);
        if (nextStoreCode_.has_value()) {
            const auto code = *nextStoreCode_;
            nextStoreCode_.reset();
            return code;
        }
        const std::string& alias = record.metadata.localSecureStoreRef;
        const bool exists = records_.find(alias) != records_.end();
        if (exists != replaceExisting) {
            return MoonlightIdentityBackendCode::Conflict;
        }
        StoredBlob blob;
        blob.metadata = record.metadata;
        blob.certificateDer = record.certificateDer;
        blob.certificatePem = record.certificatePem;
        blob.privateKeyPkcs8.assign(
            record.privateKeyPkcs8.data(),
            record.privateKeyPkcs8.data() + record.privateKeyPkcs8.size());
        records_[alias] = std::move(blob);
        return MoonlightIdentityBackendCode::Ok;
    }

    MoonlightIdentityBackendCode erase(
        const std::string& alias) noexcept override {
        invoke(eraseHook_);
        std::lock_guard<std::mutex> lock(mutex_);
        if (nextEraseCode_.has_value()) {
            const auto code = *nextEraseCode_;
            nextEraseCode_.reset();
            return code;
        }
        return records_.erase(alias) == 1U
                   ? MoonlightIdentityBackendCode::Ok
                   : MoonlightIdentityBackendCode::NotFound;
    }

    MoonlightIdentityBackendListResult list(
        const std::string& ownerScopeFingerprint) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (listOverride_.has_value()) {
            return {MoonlightIdentityBackendCode::Ok, *listOverride_};
        }
        MoonlightIdentityBackendListResult result;
        result.code = MoonlightIdentityBackendCode::Ok;
        for (const auto& [alias, record] : records_) {
            static_cast<void>(alias);
            if (record.metadata.ownerScopeFingerprint ==
                ownerScopeFingerprint) {
                result.records.push_back(record.metadata);
            }
        }
        return result;
    }

    void setLoadHook(std::function<void()> hook) {
        std::lock_guard<std::mutex> lock(mutex_);
        loadHook_ = std::move(hook);
    }

    void setStoreHook(std::function<void()> hook) {
        std::lock_guard<std::mutex> lock(mutex_);
        storeHook_ = std::move(hook);
    }

    void setNextLoadCode(MoonlightIdentityBackendCode code) {
        std::lock_guard<std::mutex> lock(mutex_);
        nextLoadCode_ = code;
    }

    void setNextStoreCode(MoonlightIdentityBackendCode code) {
        std::lock_guard<std::mutex> lock(mutex_);
        nextStoreCode_ = code;
    }

    bool contains(const std::string& alias) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return records_.find(alias) != records_.end();
    }

    std::size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return records_.size();
    }

    void flipPrivateByte(const std::string& alias) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& bytes = records_.at(alias).privateKeyPkcs8;
        bytes.at(bytes.size() / 2U) ^= 0x5aU;
    }

    MoonlightIdentityMetadata metadata(const std::string& alias) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return records_.at(alias).metadata;
    }

    void replaceMetadata(const std::string& alias,
                         MoonlightIdentityMetadata metadata) {
        std::lock_guard<std::mutex> lock(mutex_);
        records_.at(alias).metadata = std::move(metadata);
    }

    void setListOverride(std::vector<MoonlightIdentityMetadata> records) {
        std::lock_guard<std::mutex> lock(mutex_);
        listOverride_ = std::move(records);
    }

private:
    void invoke(const std::function<void()>& hook) noexcept {
        std::function<void()> copy;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            copy = hook;
        }
        if (copy) {
            copy();
        }
    }

    mutable std::mutex mutex_;
    std::map<std::string, StoredBlob> records_;
    std::function<void()> loadHook_;
    std::function<void()> storeHook_;
    std::function<void()> eraseHook_;
    std::optional<MoonlightIdentityBackendCode> nextLoadCode_;
    std::optional<MoonlightIdentityBackendCode> nextStoreCode_;
    std::optional<MoonlightIdentityBackendCode> nextEraseCode_;
    std::optional<std::vector<MoonlightIdentityMetadata>> listOverride_;
};

struct IdentityFixture final {
    MemoryIdentityBackend* backend = nullptr;
    std::unique_ptr<MoonlightSecureIdentity> identity;

    IdentityFixture() {
        auto ownedBackend = std::make_unique<MemoryIdentityBackend>();
        backend = ownedBackend.get();
        identity = std::make_unique<MoonlightSecureIdentity>(
            std::move(ownedBackend), []() { return TEST_NOW_MS; });
    }
};

bool verifySignature(const std::vector<std::uint8_t>& certificateDer,
                     const std::vector<std::uint8_t>& message,
                     const std::vector<std::uint8_t>& signature) {
    const unsigned char* cursor = certificateDer.data();
    X509* certificate = d2i_X509(
        nullptr, &cursor, static_cast<long>(certificateDer.size()));
    if (certificate == nullptr) {
        return false;
    }
    EVP_PKEY* publicKey = X509_get_pubkey(certificate);
    EVP_MD_CTX* context = EVP_MD_CTX_new();
    const bool verified =
        publicKey != nullptr && context != nullptr &&
        EVP_DigestVerifyInit(context, nullptr, EVP_sha256(), nullptr,
                             publicKey) == 1 &&
        EVP_DigestVerifyUpdate(context, message.data(), message.size()) == 1 &&
        EVP_DigestVerifyFinal(context, signature.data(), signature.size()) == 1;
    EVP_MD_CTX_free(context);
    EVP_PKEY_free(publicKey);
    X509_free(certificate);
    return verified;
}

} // namespace

RDP_TEST_CASE(moonlight_secure_identity_alias_is_scoped_bounded_and_opaque) {
    const auto firstScope = scopeFor(OWNER_A, "install-alpha-01");
    std::string first;
    std::string repeated;
    std::string otherOwner;
    std::string otherInstall;
    RDP_ASSERT(MoonlightSecureIdentity::deriveAlias(firstScope, first));
    RDP_ASSERT(MoonlightSecureIdentity::deriveAlias(firstScope, repeated));
    RDP_ASSERT(MoonlightSecureIdentity::deriveAlias(
        scopeFor(OWNER_B, "install-alpha-01"), otherOwner));
    RDP_ASSERT(MoonlightSecureIdentity::deriveAlias(
        scopeFor(OWNER_A, "install-alpha-02"), otherInstall));
    RDP_ASSERT(first == repeated);
    RDP_ASSERT(first != otherOwner);
    RDP_ASSERT(first != otherInstall);
    RDP_ASSERT_EQ(first.size(), MOONLIGHT_HUKS_ALIAS_LIMIT);
    RDP_ASSERT(first.substr(0U, 8U) == std::string("rdml-v1-"));
    RDP_ASSERT(first.find(OWNER_A) == std::string::npos);
    RDP_ASSERT(first.find("install-alpha-01") == std::string::npos);
    RDP_ASSERT(MoonlightSecureIdentity::validAlias(first));
    RDP_ASSERT(!MoonlightSecureIdentity::validAlias(first + "0"));

    std::string invalid;
    RDP_ASSERT(!MoonlightSecureIdentity::deriveAlias(
        scopeFor(std::string(63U, 'a'), "install-alpha-01"), invalid));
    RDP_ASSERT(!MoonlightSecureIdentity::deriveAlias(
        scopeFor(OWNER_A, "short"), invalid));
}

RDP_TEST_CASE(moonlight_secure_identity_matches_official_certificate_contract) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-cert-01");
    const auto ensured = fixture.identity->ensure(scope, keyFor(1U));
    RDP_ASSERT_EQ(ensured.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(ensured.created);
    RDP_ASSERT(ensured.hasMetadata);
    RDP_ASSERT_EQ(ensured.metadata.identityVersion, 1U);
    RDP_ASSERT(ensured.metadata.ownerScopeFingerprint == OWNER_A);
    RDP_ASSERT(ensured.diagnostic.maskedAlias.find(OWNER_A) ==
               std::string::npos);

    const auto acquired = fixture.identity->acquire(scope, keyFor(2U));
    RDP_ASSERT_EQ(acquired.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(acquired.lease.valid());
    RDP_ASSERT(acquired.lease.privateMaterialPageLockApplied());
    RDP_ASSERT(acquired.lease.certificatePem().find('\r') == std::string::npos);

    const auto& der = acquired.lease.certificateDer();
    const unsigned char* cursor = der.data();
    X509* certificate =
        d2i_X509(nullptr, &cursor, static_cast<long>(der.size()));
    RDP_ASSERT(certificate != nullptr);
    RDP_ASSERT_EQ(X509_get_version(certificate), 2L);
    RDP_ASSERT_EQ(X509_get_signature_nid(certificate),
                  NID_sha256WithRSAEncryption);
    std::uint64_t serial = 0U;
    RDP_ASSERT_EQ(ASN1_INTEGER_get_uint64(
                      &serial, X509_get0_serialNumber(certificate)),
                  1);
    RDP_ASSERT(serial != 0U);
    char commonName[64] {};
    RDP_ASSERT_EQ(X509_NAME_get_text_by_NID(
                      X509_get_subject_name(certificate), NID_commonName,
                      commonName, static_cast<int>(sizeof(commonName))),
                  24);
    RDP_ASSERT(std::string(commonName) ==
               std::string("NVIDIA GameStream Client"));
    RDP_ASSERT_EQ(X509_NAME_cmp(X509_get_subject_name(certificate),
                                X509_get_issuer_name(certificate)),
                  0);
    int validityDays = 0;
    int validitySeconds = 0;
    RDP_ASSERT_EQ(ASN1_TIME_diff(
                      &validityDays, &validitySeconds,
                      X509_get0_notBefore(certificate),
                      X509_get0_notAfter(certificate)),
                  1);
    RDP_ASSERT_EQ(validityDays, 7305);
    RDP_ASSERT_EQ(validitySeconds, 0);

    EVP_PKEY* publicKey = X509_get_pubkey(certificate);
    RDP_ASSERT(publicKey != nullptr);
    RDP_ASSERT_EQ(EVP_PKEY_get_base_id(publicKey), EVP_PKEY_RSA);
    RDP_ASSERT_EQ(EVP_PKEY_get_bits(publicKey), 2048);
    BIGNUM* exponent = nullptr;
    RDP_ASSERT_EQ(EVP_PKEY_get_bn_param(publicKey, OSSL_PKEY_PARAM_RSA_E,
                                        &exponent),
                  1);
    RDP_ASSERT(exponent != nullptr);
    RDP_ASSERT(BN_is_word(exponent, RSA_F4));
    BN_free(exponent);
    EVP_PKEY_free(publicKey);
    X509_free(certificate);
}

RDP_TEST_CASE(moonlight_secure_identity_lease_signs_tls_and_cleanses) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-lease-01");
    RDP_ASSERT_EQ(fixture.identity->ensure(scope, keyFor(10U)).code,
                  MoonlightIdentityCode::Ok);
    MoonlightSecureIdentity::resetSecureCleanseCountForTesting();
    auto acquired = fixture.identity->acquire(scope, keyFor(11U));
    RDP_ASSERT_EQ(acquired.code, MoonlightIdentityCode::Ok);
    const std::vector<std::uint8_t> message {'p', 'a', 'i', 'r'};
    std::vector<std::uint8_t> signature;
    RDP_ASSERT_EQ(acquired.lease.signSha256(message, signature),
                  MoonlightIdentityCode::Ok);
    RDP_ASSERT(verifySignature(acquired.lease.certificateDer(), message,
                               signature));
    SSL_CTX* context = SSL_CTX_new(TLS_client_method());
    RDP_ASSERT(context != nullptr);
    RDP_ASSERT_EQ(acquired.lease.configureTlsContext(context),
                  MoonlightIdentityCode::Ok);
    RDP_ASSERT_EQ(SSL_CTX_check_private_key(context), 1);
    SSL_CTX_free(context);
    acquired.lease.reset();
    RDP_ASSERT(MoonlightSecureIdentity::secureCleanseCountForTesting() >= 1U);

    const auto repeated = fixture.identity->ensure(scope, keyFor(12U));
    RDP_ASSERT_EQ(repeated.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(!repeated.created);
    RDP_ASSERT(repeated.metadata.certificateSha256 ==
               fixture.backend->metadata(
                   repeated.metadata.localSecureStoreRef)
                   .certificateSha256);
}

RDP_TEST_CASE(moonlight_secure_identity_isolates_inventory_and_exact_deletion) {
    IdentityFixture fixture;
    const auto scopeA = scopeFor(OWNER_A, "install-owner-a");
    const auto scopeB = scopeFor(OWNER_B, "install-owner-b");
    const auto first = fixture.identity->ensure(scopeA, keyFor(20U));
    const auto second = fixture.identity->ensure(scopeB, keyFor(21U));
    RDP_ASSERT_EQ(first.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT_EQ(second.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT_EQ(fixture.identity->inventory(OWNER_A).records.size(), 1U);
    RDP_ASSERT_EQ(fixture.identity->inventory(OWNER_B).records.size(), 1U);

    const auto crossOwner = fixture.identity->eraseAlias(
        OWNER_B, first.metadata.localSecureStoreRef, keyFor(22U), 100ms);
    RDP_ASSERT_EQ(crossOwner.code, MoonlightIdentityCode::Conflict);
    RDP_ASSERT(fixture.backend->contains(first.metadata.localSecureStoreRef));
    auto stillAcquirable = fixture.identity->acquire(scopeA, keyFor(220U));
    RDP_ASSERT_EQ(stillAcquirable.code, MoonlightIdentityCode::Ok);
    stillAcquirable.lease.reset();

    const auto deleted = fixture.identity->erase(
        scopeA, keyFor(23U), 100ms);
    RDP_ASSERT_EQ(deleted.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(deleted.deleted);
    RDP_ASSERT(!fixture.backend->contains(first.metadata.localSecureStoreRef));
    const auto idempotent = fixture.identity->erase(
        scopeA, keyFor(24U), 100ms);
    RDP_ASSERT_EQ(idempotent.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(idempotent.deleted);
    RDP_ASSERT(fixture.backend->contains(second.metadata.localSecureStoreRef));
}

RDP_TEST_CASE(moonlight_secure_identity_delete_timeout_and_cancel_keep_fences_exact) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-delete-drain");
    const auto ensured = fixture.identity->ensure(scope, keyFor(25U));
    auto acquired = fixture.identity->acquire(scope, keyFor(26U));
    RDP_ASSERT_EQ(ensured.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT_EQ(acquired.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT_EQ(fixture.identity->erase(scope, keyFor(27U), 1ms).code,
                  MoonlightIdentityCode::DrainTimeout);
    RDP_ASSERT_EQ(fixture.identity->acquire(scope, keyFor(28U)).code,
                  MoonlightIdentityCode::Busy);
    acquired.lease.reset();

    auto reopened = fixture.identity->erase(scope, keyFor(29U), 100ms);
    RDP_ASSERT_EQ(reopened.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(reopened.deleted);

    const auto second = fixture.identity->ensure(scope, keyFor(290U));
    auto secondLease = fixture.identity->acquire(scope, keyFor(291U));
    RDP_ASSERT_EQ(second.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT_EQ(secondLease.code, MoonlightIdentityCode::Ok);
    const auto operationKey = keyFor(292U);
    MoonlightIdentityResult cancelled;
    std::thread worker([&]() {
        cancelled = fixture.identity->erase(scope, operationKey, 2s);
    });
    bool cancelAccepted = false;
    const auto cancelDeadline = std::chrono::steady_clock::now() + 2s;
    while (!cancelAccepted &&
           std::chrono::steady_clock::now() < cancelDeadline) {
        cancelAccepted = fixture.identity->cancel(operationKey);
        if (!cancelAccepted) {
            std::this_thread::yield();
        }
    }
    RDP_ASSERT(cancelAccepted);
    worker.join();
    RDP_ASSERT_EQ(cancelled.code, MoonlightIdentityCode::Cancelled);
    auto afterCancel = fixture.identity->acquire(scope, keyFor(293U));
    RDP_ASSERT_EQ(afterCancel.code, MoonlightIdentityCode::Ok);
    afterCancel.lease.reset();
    secondLease.lease.reset();
}

RDP_TEST_CASE(moonlight_secure_identity_rotation_drains_active_lease) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-rotate-01");
    const auto first = fixture.identity->ensure(scope, keyFor(30U));
    auto acquired = fixture.identity->acquire(scope, keyFor(31U));
    RDP_ASSERT_EQ(first.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT_EQ(acquired.code, MoonlightIdentityCode::Ok);
    const auto timedOut = fixture.identity->rotate(
        scope, keyFor(32U), 1ms);
    RDP_ASSERT_EQ(timedOut.code, MoonlightIdentityCode::DrainTimeout);
    acquired.lease.reset();
    const auto rotated = fixture.identity->rotate(
        scope, keyFor(33U), 100ms);
    RDP_ASSERT_EQ(rotated.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(rotated.rotated);
    RDP_ASSERT_EQ(rotated.metadata.identityVersion, 2U);
    RDP_ASSERT_EQ(rotated.metadata.createdAtMs, first.metadata.createdAtMs);
    RDP_ASSERT_EQ(rotated.metadata.rotatedAtMs, TEST_NOW_MS);
    RDP_ASSERT(rotated.metadata.certificateSha256 !=
               first.metadata.certificateSha256);
}

RDP_TEST_CASE(moonlight_secure_identity_serializes_and_cancels_before_commit) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-cancel-01");
    Gate loadGate;
    std::atomic<bool> blockOnce {true};
    fixture.backend->setLoadHook([&]() {
        if (blockOnce.exchange(false)) {
            loadGate.enterAndWait();
        }
    });
    const auto operationKey = keyFor(40U);
    MoonlightIdentityResult first;
    std::thread worker([&]() {
        first = fixture.identity->ensure(scope, operationKey);
    });
    RDP_ASSERT(loadGate.waitEntered());
    RDP_ASSERT_EQ(fixture.identity->ensure(scope, keyFor(41U)).code,
                  MoonlightIdentityCode::Busy);
    RDP_ASSERT(!fixture.identity->cancel(keyFor(42U)));
    RDP_ASSERT(fixture.identity->cancel(operationKey));
    loadGate.release();
    worker.join();
    RDP_ASSERT_EQ(first.code, MoonlightIdentityCode::Cancelled);
    RDP_ASSERT_EQ(fixture.backend->size(), 0U);
}

RDP_TEST_CASE(moonlight_secure_identity_cancel_never_erases_existing_identity) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-cancel-existing");
    const auto initial = fixture.identity->ensure(scope, keyFor(50U));
    RDP_ASSERT_EQ(initial.code, MoonlightIdentityCode::Ok);
    Gate loadGate;
    fixture.backend->setLoadHook([&]() { loadGate.enterAndWait(); });
    const auto operationKey = keyFor(51U);
    MoonlightIdentityResult result;
    std::thread worker([&]() {
        result = fixture.identity->ensure(scope, operationKey);
    });
    RDP_ASSERT(loadGate.waitEntered());
    RDP_ASSERT(fixture.identity->cancel(operationKey));
    loadGate.release();
    worker.join();
    RDP_ASSERT_EQ(result.code, MoonlightIdentityCode::Cancelled);
    RDP_ASSERT(fixture.backend->contains(initial.metadata.localSecureStoreRef));
}

RDP_TEST_CASE(moonlight_secure_identity_atomic_store_commit_wins_cancel_race) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-commit-race");
    Gate storeGate;
    fixture.backend->setStoreHook([&]() { storeGate.enterAndWait(); });
    const auto operationKey = keyFor(60U);
    MoonlightIdentityResult result;
    std::thread worker([&]() {
        result = fixture.identity->ensure(scope, operationKey);
    });
    RDP_ASSERT(storeGate.waitEntered());
    RDP_ASSERT(fixture.identity->cancel(operationKey));
    storeGate.release();
    worker.join();
    RDP_ASSERT_EQ(result.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(result.created);
    RDP_ASSERT_EQ(fixture.backend->size(), 1U);
}

RDP_TEST_CASE(moonlight_secure_identity_fails_closed_on_corruption_and_unknown_outcome) {
    IdentityFixture corruptFixture;
    const auto corruptScope = scopeFor(OWNER_A, "install-corrupt-01");
    const auto ensured =
        corruptFixture.identity->ensure(corruptScope, keyFor(70U));
    RDP_ASSERT_EQ(ensured.code, MoonlightIdentityCode::Ok);
    corruptFixture.backend->flipPrivateByte(
        ensured.metadata.localSecureStoreRef);
    RDP_ASSERT_EQ(corruptFixture.identity->acquire(
                      corruptScope, keyFor(71U)).code,
                  MoonlightIdentityCode::Corrupt);

    IdentityFixture aadFixture;
    const auto aadScope = scopeFor(OWNER_A, "install-aad-01");
    const auto aadIdentity = aadFixture.identity->ensure(aadScope, keyFor(710U));
    RDP_ASSERT_EQ(aadIdentity.code, MoonlightIdentityCode::Ok);
    auto wrongOwner = aadIdentity.metadata;
    wrongOwner.ownerScopeFingerprint = OWNER_B;
    aadFixture.backend->replaceMetadata(
        aadIdentity.metadata.localSecureStoreRef, wrongOwner);
    RDP_ASSERT_EQ(aadFixture.identity->acquire(aadScope, keyFor(711U)).code,
                  MoonlightIdentityCode::Corrupt);

    IdentityFixture unknownFixture;
    const auto unknownScope = scopeFor(OWNER_A, "install-unknown-01");
    unknownFixture.backend->setNextStoreCode(
        MoonlightIdentityBackendCode::OutcomeUnknown);
    const auto unknown =
        unknownFixture.identity->ensure(unknownScope, keyFor(72U));
    RDP_ASSERT_EQ(unknown.code,
                  MoonlightIdentityCode::StorageOutcomeUnknown);
    RDP_ASSERT_EQ(unknownFixture.identity->ensure(
                      unknownScope, keyFor(73U)).code,
                  MoonlightIdentityCode::Busy);
    RDP_ASSERT_EQ(unknownFixture.identity->erase(
                      unknownScope, keyFor(74U), 100ms).code,
                  MoonlightIdentityCode::Ok);
}

RDP_TEST_CASE(moonlight_secure_identity_known_rotation_failure_rolls_back) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-rollback-01");
    const auto initial = fixture.identity->ensure(scope, keyFor(76U));
    RDP_ASSERT_EQ(initial.code, MoonlightIdentityCode::Ok);
    fixture.backend->setNextStoreCode(MoonlightIdentityBackendCode::IoFailure);
    const auto failed = fixture.identity->rotate(scope, keyFor(77U), 100ms);
    RDP_ASSERT_EQ(failed.code, MoonlightIdentityCode::StorageFailure);
    auto acquired = fixture.identity->acquire(scope, keyFor(78U));
    RDP_ASSERT_EQ(acquired.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT(acquired.metadata.certificateSha256 ==
               initial.metadata.certificateSha256);
    RDP_ASSERT_EQ(acquired.metadata.identityVersion, 1U);
    acquired.lease.reset();
}

RDP_TEST_CASE(moonlight_secure_identity_entropy_failure_leaves_no_partial_record) {
    auto backend = std::make_unique<MemoryIdentityBackend>();
    MemoryIdentityBackend* backendView = backend.get();
    auto identity = MoonlightSecureIdentity::createForTesting(
        std::move(backend), []() { return TEST_NOW_MS; },
        [](std::uint8_t* output, std::size_t size) {
            if (output != nullptr && size > 0U) {
                std::memset(output, 0x5a, size);
            }
            return false;
        });
    RDP_ASSERT(identity != nullptr);
    const auto result = identity->ensure(
        scopeFor(OWNER_A, "install-no-entropy"), keyFor(75U));
    RDP_ASSERT_EQ(result.code, MoonlightIdentityCode::CryptoFailure);
    RDP_ASSERT_EQ(backendView->size(), 0U);
    RDP_ASSERT(!result.hasMetadata);
}

RDP_TEST_CASE(moonlight_secure_identity_rejects_invalid_inventory_records) {
    IdentityFixture fixture;
    const auto scope = scopeFor(OWNER_A, "install-inventory-01");
    const auto ensured = fixture.identity->ensure(scope, keyFor(80U));
    RDP_ASSERT_EQ(ensured.code, MoonlightIdentityCode::Ok);
    std::string orphanAlias;
    RDP_ASSERT(MoonlightSecureIdentity::deriveAlias(
        scopeFor(OWNER_A, "install-orphan-01"), orphanAlias));
    auto orphan = ensured.metadata;
    orphan.localSecureStoreRef = orphanAlias;
    fixture.backend->setListOverride({orphan});
    const auto orphanInventory = fixture.identity->inventory(OWNER_A);
    RDP_ASSERT_EQ(orphanInventory.code, MoonlightIdentityCode::Ok);
    RDP_ASSERT_EQ(orphanInventory.records.size(), 1U);
    RDP_ASSERT_EQ(fixture.identity->eraseAlias(
                      OWNER_A, orphanAlias, keyFor(801U), 100ms).code,
                  MoonlightIdentityCode::Ok);
    auto foreign = ensured.metadata;
    foreign.ownerScopeFingerprint = OWNER_B;
    fixture.backend->setListOverride({ensured.metadata, foreign});
    RDP_ASSERT_EQ(fixture.identity->inventory(OWNER_A).code,
                  MoonlightIdentityCode::Corrupt);
    fixture.backend->setListOverride({ensured.metadata, ensured.metadata});
    RDP_ASSERT_EQ(fixture.identity->inventory(OWNER_A).code,
                  MoonlightIdentityCode::Corrupt);
}

RDP_TEST_CASE(moonlight_secure_identity_rejects_unproven_backend_capability) {
    class UnprovenBackend final : public MoonlightIdentityBackend {
    public:
        MoonlightIdentityCapability capability() const noexcept override {
            MoonlightIdentityCapability result;
            result.status =
                MoonlightIdentityCapabilityStatus::RuntimeProofRequired;
            result.huksApiLinked = true;
            result.assetApiLinked = true;
            return result;
        }
        MoonlightIdentityBackendLoadResult load(
            const std::string&) noexcept override { return {}; }
        MoonlightIdentityBackendCode store(
            const MoonlightIdentityStoredRecord&, bool) noexcept override {
            return MoonlightIdentityBackendCode::Unavailable;
        }
        MoonlightIdentityBackendCode erase(
            const std::string&) noexcept override {
            return MoonlightIdentityBackendCode::Unavailable;
        }
        MoonlightIdentityBackendListResult list(
            const std::string&) noexcept override { return {}; }
    };

    MoonlightSecureIdentity identity(std::make_unique<UnprovenBackend>(),
                                     []() { return TEST_NOW_MS; });
    const auto capability = identity.capability();
    RDP_ASSERT_EQ(capability.status,
                  MoonlightIdentityCapabilityStatus::RuntimeProofRequired);
    RDP_ASSERT_EQ(capability.huksAliasLimit, MOONLIGHT_HUKS_ALIAS_LIMIT);
    RDP_ASSERT_EQ(capability.assetSecretLimit, MOONLIGHT_ASSET_SECRET_LIMIT);
    RDP_ASSERT_EQ(identity.ensure(scopeFor(OWNER_A, "install-closed-01"),
                                  keyFor(90U)).code,
                  MoonlightIdentityCode::Unavailable);

    class DirectProbeFalseBackend final : public MoonlightIdentityBackend {
    public:
        MoonlightIdentityCapability capability() const noexcept override {
            MoonlightIdentityCapability result;
            result.status = MoonlightIdentityCapabilityStatus::RuntimeReady;
            result.storageMode = MoonlightIdentityStorageMode::HuksDirectSigner;
            result.huksApiLinked = true;
            result.directRsaTlsSignerReady = false;
            return result;
        }
        MoonlightIdentityBackendLoadResult load(
            const std::string&) noexcept override { return {}; }
        MoonlightIdentityBackendCode store(
            const MoonlightIdentityStoredRecord&, bool) noexcept override {
            return MoonlightIdentityBackendCode::Unavailable;
        }
        MoonlightIdentityBackendCode erase(
            const std::string&) noexcept override {
            return MoonlightIdentityBackendCode::Unavailable;
        }
        MoonlightIdentityBackendListResult list(
            const std::string&) noexcept override { return {}; }
    };
    MoonlightSecureIdentity directProbeFalse(
        std::make_unique<DirectProbeFalseBackend>(),
        []() { return TEST_NOW_MS; });
    RDP_ASSERT_EQ(directProbeFalse.ensure(
                      scopeFor(OWNER_A, "install-direct-false"), keyFor(91U)).code,
                  MoonlightIdentityCode::Unavailable);
}
