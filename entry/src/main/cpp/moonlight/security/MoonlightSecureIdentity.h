#ifndef REMOTEDESK_MOONLIGHT_SECURE_IDENTITY_H
#define REMOTEDESK_MOONLIGHT_SECURE_IDENTITY_H

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#if defined(__GNUC__)
#define REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN
#endif

struct ssl_ctx_st;

namespace remotedesk::moonlight {

constexpr std::size_t MOONLIGHT_HUKS_ALIAS_LIMIT = 64;
constexpr std::size_t MOONLIGHT_ASSET_SECRET_LIMIT = 1023;

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityOperationKey final {
    std::uint64_t requestId = 0;
    std::uint64_t generation = 0;
    std::uint64_t ownerToken = 0;

    constexpr bool valid() const noexcept {
        return requestId != 0 && generation != 0 && ownerToken != 0;
    }
};

REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN constexpr bool operator==(
    const MoonlightIdentityOperationKey& left,
    const MoonlightIdentityOperationKey& right) noexcept {
    return left.requestId == right.requestId &&
           left.generation == right.generation &&
           left.ownerToken == right.ownerToken;
}

REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN constexpr bool operator!=(
    const MoonlightIdentityOperationKey& left,
    const MoonlightIdentityOperationKey& right) noexcept {
    return !(left == right);
}

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityScope final {
    // Lowercase SHA-256 hex produced by the existing owner-scope policy. The
    // raw account/UnionID must never cross this native boundary.
    std::string ownerScopeFingerprint;
    // Random installation identifier. It is only hashed into the HUKS alias
    // and is never persisted by this component.
    std::string installationId;
};

enum class MoonlightIdentityStorageMode : std::uint8_t {
    HuksDirectSigner = 0,
    HuksWrappedPkcs8,
};

enum class MoonlightIdentityCapabilityStatus : std::uint8_t {
    RuntimeReady = 0,
    RuntimeProofRequired,
    Unavailable,
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityCapability final {
    MoonlightIdentityCapabilityStatus status =
        MoonlightIdentityCapabilityStatus::Unavailable;
    MoonlightIdentityStorageMode storageMode =
        MoonlightIdentityStorageMode::HuksWrappedPkcs8;
    bool huksApiLinked = false;
    bool assetApiLinked = false;
    bool directRsaTlsSignerReady = false;
    bool wrappedPkcs8Ready = false;
    bool encryptedBlobAtomic = false;
    bool secureBufferPageLockSupported = false;
    std::size_t huksAliasLimit = MOONLIGHT_HUKS_ALIAS_LIMIT;
    std::size_t assetSecretLimit = MOONLIGHT_ASSET_SECRET_LIMIT;
};

enum class MoonlightIdentityBackendCode : std::uint8_t {
    Ok = 0,
    NotFound,
    Busy,
    Unavailable,
    Conflict,
    Corrupt,
    IoFailure,
    OutcomeUnknown,
};

enum class MoonlightIdentityCode : std::uint8_t {
    Ok = 0,
    InvalidArgument,
    Busy,
    NotFound,
    Unavailable,
    Cancelled,
    Stale,
    Corrupt,
    CryptoFailure,
    StorageFailure,
    StorageOutcomeUnknown,
    Conflict,
    DrainTimeout,
    ShuttingDown,
};

enum class MoonlightIdentityOperation : std::uint8_t {
    None = 0,
    Ensure,
    Acquire,
    Rotate,
    Delete,
    Inventory,
    Sign,
    ConfigureTls,
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityMetadata final {
    std::uint32_t identityVersion = 0;
    std::string certificateSha256;
    std::string ownerScopeFingerprint;
    MoonlightIdentityStorageMode storageMode =
        MoonlightIdentityStorageMode::HuksWrappedPkcs8;
    std::string localSecureStoreRef;
    std::uint64_t createdAtMs = 0;
    std::uint64_t rotatedAtMs = 0;
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityDiagnostic final {
    MoonlightIdentityOperation operation = MoonlightIdentityOperation::None;
    MoonlightIdentityCode code = MoonlightIdentityCode::InvalidArgument;
    MoonlightIdentityBackendCode backendCode =
        MoonlightIdentityBackendCode::Unavailable;
    std::string maskedAlias;
    std::uint64_t durationMs = 0;
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityResult final {
    MoonlightIdentityCode code = MoonlightIdentityCode::InvalidArgument;
    MoonlightIdentityMetadata metadata {};
    MoonlightIdentityDiagnostic diagnostic {};
    bool hasMetadata = false;
    bool created = false;
    bool rotated = false;
    bool deleted = false;
};

class REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightSecureBuffer final {
public:
    MoonlightSecureBuffer() noexcept = default;
    explicit MoonlightSecureBuffer(std::vector<std::uint8_t> bytes) noexcept;
    ~MoonlightSecureBuffer();

    MoonlightSecureBuffer(const MoonlightSecureBuffer&) = delete;
    MoonlightSecureBuffer& operator=(const MoonlightSecureBuffer&) = delete;
    MoonlightSecureBuffer(MoonlightSecureBuffer&& other) noexcept;
    MoonlightSecureBuffer& operator=(MoonlightSecureBuffer&& other) noexcept;

    const std::uint8_t* data() const noexcept;
    std::uint8_t* data() noexcept;
    std::size_t size() const noexcept;
    bool empty() const noexcept;
    bool pageLocked() const noexcept;
    void clear() noexcept;

private:
    std::vector<std::uint8_t> bytes_;
    bool pageLocked_ = false;
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityStoredRecord final {
    MoonlightIdentityStoredRecord() = default;
    MoonlightIdentityStoredRecord(const MoonlightIdentityStoredRecord&) = delete;
    MoonlightIdentityStoredRecord& operator=(const MoonlightIdentityStoredRecord&) = delete;
    MoonlightIdentityStoredRecord(MoonlightIdentityStoredRecord&&) noexcept = default;
    MoonlightIdentityStoredRecord& operator=(MoonlightIdentityStoredRecord&&) noexcept = default;

    MoonlightIdentityMetadata metadata {};
    std::vector<std::uint8_t> certificateDer;
    std::string certificatePem;
    MoonlightSecureBuffer privateKeyPkcs8;
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityBackendLoadResult final {
    MoonlightIdentityBackendCode code = MoonlightIdentityBackendCode::Unavailable;
    std::unique_ptr<MoonlightIdentityStoredRecord> record;
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityBackendListResult final {
    MoonlightIdentityBackendCode code = MoonlightIdentityBackendCode::Unavailable;
    std::vector<MoonlightIdentityMetadata> records;
};

// Implementations must encrypt privateKeyPkcs8 before returning from store(),
// must never retain the caller's plaintext pointer, and must return a freshly
// decrypted move-only buffer from load(). Every operation must also have its
// own finite platform deadline: manager destruction can cancel admission but
// cannot safely interrupt a backend call already inside HUKS/Asset/file I/O.
// Product code must fail closed when a HUKS-backed, atomically persisted
// implementation is not runtime-proven.
class REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityBackend {
public:
    virtual ~MoonlightIdentityBackend() = default;

    virtual MoonlightIdentityCapability capability() const noexcept = 0;
    virtual MoonlightIdentityBackendLoadResult load(
        const std::string& alias) noexcept = 0;
    virtual MoonlightIdentityBackendCode store(
        const MoonlightIdentityStoredRecord& record,
        bool replaceExisting) noexcept = 0;
    virtual MoonlightIdentityBackendCode erase(
        const std::string& alias) noexcept = 0;
    virtual MoonlightIdentityBackendListResult list(
        const std::string& ownerScopeFingerprint) noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityLease final {
private:
    struct Impl;

public:
    MoonlightIdentityLease() noexcept;
    ~MoonlightIdentityLease();

    MoonlightIdentityLease(const MoonlightIdentityLease&) = delete;
    MoonlightIdentityLease& operator=(const MoonlightIdentityLease&) = delete;
    MoonlightIdentityLease(MoonlightIdentityLease&& other) noexcept;
    MoonlightIdentityLease& operator=(MoonlightIdentityLease&& other) noexcept;

    bool valid() const noexcept;
    const MoonlightIdentityMetadata& metadata() const noexcept;
    const std::vector<std::uint8_t>& certificateDer() const noexcept;
    const std::string& certificatePem() const noexcept;
    bool privateMaterialPageLockApplied() const noexcept;

    // SHA256withRSA, matching the official pairing client's client-secret
    // signature. The private key never leaves this lease.
    MoonlightIdentityCode signSha256(
        const std::vector<std::uint8_t>& message,
        std::vector<std::uint8_t>& signature) noexcept;

    // Configures an OpenSSL client context for mTLS. The caller must keep this
    // lease alive until every SSL object created from the context is destroyed.
    MoonlightIdentityCode configureTlsContext(struct ssl_ctx_st* context) noexcept;
    void reset() noexcept;

private:
    friend class MoonlightSecureIdentity;
    explicit MoonlightIdentityLease(std::unique_ptr<Impl> impl) noexcept;

    std::unique_ptr<Impl> impl_;
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityAcquireResult final {
    MoonlightIdentityCode code = MoonlightIdentityCode::InvalidArgument;
    MoonlightIdentityMetadata metadata {};
    MoonlightIdentityDiagnostic diagnostic {};
    MoonlightIdentityLease lease {};
};

struct REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightIdentityInventoryResult final {
    MoonlightIdentityCode code = MoonlightIdentityCode::InvalidArgument;
    std::vector<MoonlightIdentityMetadata> records;
    MoonlightIdentityDiagnostic diagnostic {};
};

class REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN MoonlightSecureIdentity final {
private:
    struct SharedState;
    struct Impl;

public:
    using Clock = std::function<std::uint64_t()>;

    explicit MoonlightSecureIdentity(
        std::unique_ptr<MoonlightIdentityBackend> backend,
        Clock clock = {});
    ~MoonlightSecureIdentity();

    MoonlightSecureIdentity(const MoonlightSecureIdentity&) = delete;
    MoonlightSecureIdentity& operator=(const MoonlightSecureIdentity&) = delete;

    static bool deriveAlias(const MoonlightIdentityScope& scope,
                            std::string& alias) noexcept;
    static bool validAlias(const std::string& alias) noexcept;
    MoonlightIdentityCapability capability() const noexcept;

    MoonlightIdentityResult ensure(
        const MoonlightIdentityScope& scope,
        const MoonlightIdentityOperationKey& key) noexcept;
    MoonlightIdentityAcquireResult acquire(
        const MoonlightIdentityScope& scope,
        const MoonlightIdentityOperationKey& key) noexcept;
    MoonlightIdentityResult rotate(
        const MoonlightIdentityScope& scope,
        const MoonlightIdentityOperationKey& key,
        std::chrono::milliseconds drainTimeout) noexcept;
    MoonlightIdentityResult erase(
        const MoonlightIdentityScope& scope,
        const MoonlightIdentityOperationKey& key,
        std::chrono::milliseconds drainTimeout) noexcept;
    MoonlightIdentityResult eraseAlias(
        const std::string& ownerScopeFingerprint,
        const std::string& alias,
        const MoonlightIdentityOperationKey& key,
        std::chrono::milliseconds drainTimeout) noexcept;
    MoonlightIdentityInventoryResult inventory(
        const std::string& ownerScopeFingerprint) noexcept;
    bool cancel(const MoonlightIdentityOperationKey& key) noexcept;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    using EntropyForTesting =
        std::function<bool(std::uint8_t*, std::size_t)>;
    static std::unique_ptr<MoonlightSecureIdentity> createForTesting(
        std::unique_ptr<MoonlightIdentityBackend> backend,
        Clock clock,
        EntropyForTesting entropy);
    static std::uint64_t secureCleanseCountForTesting() noexcept;
    static void resetSecureCleanseCountForTesting() noexcept;
#endif

private:
    MoonlightIdentityResult ensureOrRotate(
        const MoonlightIdentityScope& scope,
        const MoonlightIdentityOperationKey& key,
        bool rotate,
        std::chrono::milliseconds drainTimeout) noexcept;
    MoonlightIdentityResult eraseResolved(
        const std::string& ownerScopeFingerprint,
        const std::string& alias,
        const MoonlightIdentityOperationKey& key,
        std::chrono::milliseconds drainTimeout) noexcept;
    MoonlightSecureIdentity(
        std::unique_ptr<MoonlightIdentityBackend> backend,
        Clock clock,
        std::function<bool(std::uint8_t*, std::size_t)> entropy);

    std::unique_ptr<Impl> impl_;
};

// API-23 product backend. It deliberately remains unavailable until a HAP /
// AppSpawn runtime receipt proves either direct HUKS TLS signing or HUKS-wrapped
// PKCS#8 plus atomic encrypted-blob persistence. No plaintext fallback exists.
REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN
std::unique_ptr<MoonlightIdentityBackend> createMoonlightPlatformIdentityBackend();

// Build-only probe used by scripts/probe_moonlight_platform.sh. It references
// the exact HUKS and Asset NDK entry points without invoking app-scoped services.
REMOTEDESK_MOONLIGHT_IDENTITY_HIDDEN
bool moonlightSecureIdentityPlatformCompileProbe() noexcept;

} // namespace remotedesk::moonlight

#endif
