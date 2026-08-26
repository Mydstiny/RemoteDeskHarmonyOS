#ifndef REMOTEDESK_MOONLIGHT_PAIRING_MANAGER_H
#define REMOTEDESK_MOONLIGHT_PAIRING_MANAGER_H

#include "moonlight/core/MoonlightHostApi.h"
#include "moonlight/security/MoonlightSecureIdentity.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#if defined(__GNUC__)
#define REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN
#endif

namespace remotedesk::moonlight {

enum class MoonlightPairingStage : std::uint8_t {
    Idle = 0,
    Preflight,
    WaitingForServerCertificate,
    AwaitingTrust,
    ClientChallenge,
    ServerChallenge,
    SecretVerification,
    ClientSecret,
    FinalChallenge,
    Committing,
    Paired,
    Cancelling,
    Failed,
    Cancelled,
};

enum class MoonlightPairingCode : std::uint8_t {
    Ok = 0,
    InvalidArgument,
    Busy,
    Unavailable,
    LegacySha1Disabled,
    IdentityFailure,
    TransportFailure,
    MutationOutcomeUnknown,
    AlreadyInProgress,
    CertificateInvalid,
    TrustRejected,
    TrustTimeout,
    Stale,
    PinWrong,
    ServerAuthenticationFailed,
    ProtocolFailure,
    CryptoFailure,
    Cancelled,
    DeadlineExceeded,
    CommitFailed,
    RepairRequired,
    ShuttingDown,
};

enum class MoonlightTrustDecision : std::uint8_t {
    Accept = 0,
    Reject,
    Timeout,
    Cancelled,
    Stale,
    Unavailable,
};

enum class MoonlightTrustChange : std::uint8_t {
    Unknown = 0,
    FirstUse,
    Matched,
    Changed,
};

enum class MoonlightPairingPortCode : std::uint8_t {
    Ok = 0,
    KnownFailure,
    OutcomeUnknown,
    Cancelled,
    Stale,
    Unavailable,
};

enum class MoonlightRemoteCleanup : std::uint8_t {
    NotNeeded = 0,
    Confirmed,
    Failed,
    OutcomeUnknown,
};

struct REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightPairingOperationKey final {
    std::uint64_t requestId = 0;
    std::uint64_t generation = 0;
    std::uint64_t ownerToken = 0;

    constexpr bool valid() const noexcept {
        return requestId != 0 && generation != 0 && ownerToken != 0;
    }
};

REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN constexpr bool operator==(
    const MoonlightPairingOperationKey& left,
    const MoonlightPairingOperationKey& right) noexcept {
    return left.requestId == right.requestId &&
           left.generation == right.generation &&
           left.ownerToken == right.ownerToken;
}

struct REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightPairingRequest final {
    MoonlightPairingRequest() = default;
    ~MoonlightPairingRequest() = default;
    MoonlightPairingRequest(const MoonlightPairingRequest&) = delete;
    MoonlightPairingRequest& operator=(const MoonlightPairingRequest&) = delete;
    MoonlightPairingRequest(MoonlightPairingRequest&&) noexcept = default;
    MoonlightPairingRequest& operator=(MoonlightPairingRequest&&) noexcept = default;

    MoonlightPairingOperationKey key {};
    MoonlightIdentityScope identityScope {};
    MoonlightHostEndpoint endpoint {};
    std::string hostId;
    std::string serverUuid;
    std::string hostLabel;
    std::uint32_t serverMajorVersion = 0;
    std::chrono::milliseconds timeout {120000};
    bool allowLegacySha1 = false;
    MoonlightSecureBuffer pin;
};

struct REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightTrustCandidate final {
    std::string maskedHost;
    std::string hostLabel;
    std::string certificateSha256;
    std::string subject;
    std::string issuer;
    std::string notBefore;
    std::string notAfter;
    std::string publicKeyAlgorithm;
    std::uint32_t publicKeyBits = 0;
};

struct REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightTrustReview final {
    MoonlightTrustDecision decision = MoonlightTrustDecision::Unavailable;
    MoonlightTrustChange change = MoonlightTrustChange::Unknown;
};

struct REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightPairingCommitRecord final {
    MoonlightPairingOperationKey key {};
    std::string ownerScopeFingerprint;
    std::string hostId;
    std::string serverUuid;
    std::string certificateSha256;
    std::string localSecureStoreRef;
    std::uint32_t identityVersion = 0;
    std::uint64_t pairingGeneration = 0;
    std::uint64_t observedAtMs = 0;
    MoonlightTrustChange trustChange = MoonlightTrustChange::Unknown;
};

struct REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightPairingResult final {
    MoonlightPairingCode code = MoonlightPairingCode::InvalidArgument;
    MoonlightPairingStage terminalStage = MoonlightPairingStage::Failed;
    MoonlightHostError lastHostError = MoonlightHostError::None;
    int lastHttpStatus = 0;
    std::int32_t lastXmlStatus = 0;
    std::size_t transportAttempts = 0;
    std::string certificateSha256;
    MoonlightTrustChange trustChange = MoonlightTrustChange::Unknown;
    MoonlightRemoteCleanup remoteCleanup = MoonlightRemoteCleanup::NotNeeded;
    bool localRollbackAttempted = false;
    bool localRollbackSucceeded = false;
    bool repairRequired = false;
    std::vector<MoonlightPairingStage> stageTrace;

    bool ok() const noexcept { return code == MoonlightPairingCode::Ok; }
};

class REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightPairingTrustPort {
public:
    using CancellationProbe = std::function<bool()>;

    virtual ~MoonlightPairingTrustPort() = default;
    virtual bool available() const noexcept = 0;
    virtual MoonlightTrustReview review(
        const MoonlightPairingOperationKey& key,
        const MoonlightTrustCandidate& candidate,
        std::chrono::steady_clock::time_point absoluteDeadline,
        const CancellationProbe& cancellationProbe) = 0;
    virtual void cancel(const MoonlightPairingOperationKey& key) noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightPairingTlsBindingPort {
public:
    using CancellationProbe = std::function<bool()>;

    virtual ~MoonlightPairingTlsBindingPort() = default;
    virtual bool available() const noexcept = 0;
    virtual MoonlightPairingPortCode bind(
        const MoonlightPairingOperationKey& key,
        const MoonlightHostEndpoint& endpoint,
        const std::vector<std::uint8_t>& serverCertificateDer,
        const std::string& certificateSha256,
        std::chrono::steady_clock::time_point absoluteDeadline,
        const CancellationProbe& cancellationProbe,
        MoonlightIdentityLease& identityLease) = 0;
    virtual void cancel(const MoonlightPairingOperationKey& key) noexcept = 0;
    virtual void unbind(const MoonlightPairingOperationKey& key) noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightPairingCommitPort {
public:
    virtual ~MoonlightPairingCommitPort() = default;
    virtual bool available() const noexcept = 0;
    virtual bool repairRequired(
        const std::string& ownerScopeFingerprint,
        const std::string& hostId) const noexcept = 0;
    virtual MoonlightPairingPortCode commit(
        const MoonlightPairingCommitRecord& record) = 0;
    virtual MoonlightPairingPortCode rollback(
        const MoonlightPairingCommitRecord& record) noexcept = 0;
    // Persists an admission fence when commit or rollback truth is unknown.
    // It stores no PIN, certificate bytes, or private material.
    virtual void recordRepairRequired(
        const MoonlightPairingCommitRecord& record) noexcept = 0;
    virtual void cancel(const MoonlightPairingOperationKey& key) noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN MoonlightPairingManager final {
public:
    struct Impl;

    using Entropy = std::function<bool(std::uint8_t*, std::size_t)>;
    using MonotonicClock =
        std::function<std::chrono::steady_clock::time_point()>;
    using WallClock = std::function<std::uint64_t()>;

    MoonlightPairingManager(
        std::shared_ptr<MoonlightHostApi> hostApi,
        std::shared_ptr<MoonlightSecureIdentity> secureIdentity,
        std::shared_ptr<MoonlightPairingTrustPort> trustPort,
        std::shared_ptr<MoonlightPairingTlsBindingPort> tlsBindingPort,
        std::shared_ptr<MoonlightPairingCommitPort> commitPort,
        Entropy entropy,
        MonotonicClock monotonicClock = {},
        WallClock wallClock = {});
    ~MoonlightPairingManager();

    MoonlightPairingManager(const MoonlightPairingManager&) = delete;
    MoonlightPairingManager& operator=(const MoonlightPairingManager&) = delete;

    MoonlightPairingResult execute(MoonlightPairingRequest request) noexcept;
    bool cancel(const MoonlightPairingOperationKey& key) noexcept;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::uint64_t secureCleanseCountForTesting() noexcept;
    static void resetSecureCleanseCountForTesting() noexcept;
#endif

private:
    std::shared_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_PAIRING_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_PAIRING_MANAGER_H
