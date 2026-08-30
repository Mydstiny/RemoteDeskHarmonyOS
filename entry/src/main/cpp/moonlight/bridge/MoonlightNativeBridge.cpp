#include "moonlight/bridge/MoonlightNativeBridge.h"

#include <openssl/crypto.h>

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <limits>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kPinBytes = 4U;
constexpr std::size_t kMaxIdentityBytes = 256U;
constexpr std::size_t kMaxAddressBytes = 512U;
constexpr std::size_t kMaxEvents = 256U;
constexpr std::size_t kMaxPollEvents = 128U;
constexpr std::size_t kMaxSeenKeysPerLaneGeneration = 4096U;
constexpr std::size_t kMaxDiagnostics = 64U;
constexpr std::size_t kMaxDiagnosticTokenBytes = 64U;
constexpr std::size_t kMaxRtspSessionUrlBytes = 4096U;
constexpr std::size_t kMaxIdentityInventoryCount = 256U;
constexpr std::uint64_t kMaxSafeInteger = 9007199254740991ULL;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::atomic<std::uint64_t> gBridgeCleanseCount {0U};
#endif

void secureWipe(void* pointer, std::size_t size) noexcept {
    if (pointer == nullptr || size == 0U) {
        return;
    }
    OPENSSL_cleanse(pointer, size);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    gBridgeCleanseCount.fetch_add(1U, std::memory_order_relaxed);
#endif
}

void secureWipeBytes(std::vector<std::uint8_t>& value) noexcept {
    secureWipe(value.empty() ? nullptr : value.data(), value.size());
    value.clear();
}

void secureWipeString(std::string& value) noexcept {
    secureWipe(value.empty() ? nullptr : value.data(), value.size());
    value.clear();
}

void secureWipeOptionalString(std::optional<std::string>& value) noexcept {
    if (!value.has_value()) {
        return;
    }
    secureWipeString(*value);
    value.reset();
}

bool boundedText(const std::string& value, std::size_t maximum) noexcept {
    if (value.empty() || value.size() > maximum) {
        return false;
    }
    return std::none_of(value.begin(), value.end(), [](char character) {
        const auto byte = static_cast<unsigned char>(character);
        return byte < 0x20U || byte == 0x7fU;
    });
}

bool ownerFingerprintValid(const std::string& value) noexcept {
    return value.size() == 64U &&
           std::all_of(value.begin(), value.end(), [](char character) {
               return (character >= '0' && character <= '9') ||
                      (character >= 'a' && character <= 'f');
           });
}

bool endpointValid(const MoonlightBridgeRequest& request) noexcept {
    const auto& endpoint = request.endpoint;
    if (!boundedText(endpoint.serverName, kMaxIdentityBytes) ||
        endpoint.addresses.empty() ||
        endpoint.addresses.size() > MoonlightHostLimits::kMaxAddresses ||
        endpoint.httpPort == 0U || endpoint.httpsPort == 0U) {
        return false;
    }
    for (const auto& address : endpoint.addresses) {
        if (!boundedText(address.value, kMaxAddressBytes) ||
            (!address.scope.empty() &&
             (!boundedText(address.scope, 32U) ||
              address.family != MoonlightHostAddressFamily::Ipv6)) ||
            (address.family != MoonlightHostAddressFamily::Unspecified &&
             address.family != MoonlightHostAddressFamily::Ipv4 &&
             address.family != MoonlightHostAddressFamily::Ipv6)) {
            return false;
        }
    }
    if (request.operation == MoonlightBridgeOperation::Pair) {
        return endpoint.allowHttpPairingCandidate;
    }
    return endpoint.pinnedTrustAvailable && !endpoint.allowHttpPairingCandidate;
}

bool launchConfigurationValid(
    const MoonlightBridgeLaunchConfiguration& configuration) noexcept {
    return configuration.width >= 320U && configuration.width <= 16384U &&
           configuration.height >= 200U && configuration.height <= 16384U &&
           configuration.refreshRate >= 1U && configuration.refreshRate <= 1000U;
}

bool digitsOnly(const std::vector<std::uint8_t>& value) noexcept {
    return value.size() == kPinBytes &&
           std::all_of(value.begin(), value.end(), [](std::uint8_t byte) {
               return byte >= static_cast<std::uint8_t>('0') &&
                      byte <= static_cast<std::uint8_t>('9');
           });
}

bool sha256HexOrEmpty(const std::string& value) noexcept {
    return value.empty() ||
        (value.size() == 64U &&
         std::all_of(value.begin(), value.end(), [](char character) {
             return (character >= '0' && character <= '9') ||
                    (character >= 'a' && character <= 'f');
         }));
}

bool requestValid(const MoonlightBridgeRequest& request) noexcept {
    if (!request.key.valid() ||
        !ownerFingerprintValid(request.ownerScopeFingerprint)) {
        return false;
    }
    if (request.operation == MoonlightBridgeOperation::DeleteIdentity) {
        return request.timeout >= MoonlightHostLimits::kMinTimeout &&
               request.timeout <= MoonlightHostLimits::kMaxStandardTimeout &&
               request.installationId.empty() && request.hostId.empty() &&
               request.serverUuid.empty() &&
               request.pinnedCertificateSha256.empty() &&
               request.endpoint.serverName.empty() &&
               request.endpoint.addresses.empty() &&
               !request.endpoint.pinnedTrustAvailable &&
               !request.endpoint.allowHttpPairingCandidate &&
               request.pin.empty() && request.riKey.empty() &&
               request.riKeyId == 0 && request.appId == 0U &&
               request.catalogGeneration == 0U &&
               request.expectedCurrentAppId == 0U &&
               !request.userConfirmedTermination &&
               !request.allowLegacySha1;
    }
    if (!boundedText(request.hostId, kMaxIdentityBytes) ||
        !boundedText(request.serverUuid, kMaxIdentityBytes) ||
        !sha256HexOrEmpty(request.pinnedCertificateSha256) ||
        !endpointValid(request)) {
        return false;
    }
    const auto maximumTimeout = request.operation == MoonlightBridgeOperation::Pair
                                    ? MoonlightHostLimits::kMaxTimeout
                                    : MoonlightHostLimits::kMaxStandardTimeout;
    if (request.timeout < MoonlightHostLimits::kMinTimeout ||
        request.timeout > maximumTimeout) {
        return false;
    }

    switch (request.operation) {
    case MoonlightBridgeOperation::Pair:
        return boundedText(request.installationId, kMaxIdentityBytes) &&
               digitsOnly(request.pin) && request.riKey.empty() &&
               request.appId == 0U && request.catalogGeneration == 0U &&
               request.expectedCurrentAppId == 0U &&
               !request.userConfirmedTermination;
    case MoonlightBridgeOperation::Unpair:
        return (request.installationId.empty() ||
                boundedText(request.installationId, kMaxIdentityBytes)) &&
               request.pinnedCertificateSha256.size() == 64U &&
               request.pin.empty() && request.riKey.empty() &&
               request.appId == 0U && request.catalogGeneration == 0U &&
               request.expectedCurrentAppId == 0U &&
               !request.userConfirmedTermination && !request.allowLegacySha1;
    case MoonlightBridgeOperation::Catalog:
        return (request.installationId.empty() ||
                boundedText(request.installationId, kMaxIdentityBytes)) &&
               request.pin.empty() &&
               request.riKey.empty() && request.appId == 0U &&
               request.catalogGeneration == 0U &&
               request.expectedCurrentAppId == 0U &&
               !request.userConfirmedTermination && !request.allowLegacySha1;
    case MoonlightBridgeOperation::Asset:
        return (request.installationId.empty() ||
                boundedText(request.installationId, kMaxIdentityBytes)) &&
               request.pin.empty() &&
               request.riKey.empty() && request.appId != 0U &&
               request.catalogGeneration == request.key.generation &&
               request.expectedCurrentAppId == 0U &&
               !request.userConfirmedTermination && !request.allowLegacySha1;
    case MoonlightBridgeOperation::Launch:
    case MoonlightBridgeOperation::Resume:
        return (request.installationId.empty() ||
                boundedText(request.installationId, kMaxIdentityBytes)) &&
               request.pin.empty() &&
               request.appId != 0U &&
               request.catalogGeneration == request.key.generation &&
               request.riKey.empty() && request.riKeyId == 0 &&
               launchConfigurationValid(request.launchConfiguration) &&
               request.expectedCurrentAppId == 0U &&
               !request.userConfirmedTermination && !request.allowLegacySha1;
    case MoonlightBridgeOperation::Quit:
        return (request.installationId.empty() ||
                boundedText(request.installationId, kMaxIdentityBytes)) &&
               request.pin.empty() &&
               request.riKey.empty() && request.appId == 0U &&
               request.catalogGeneration == 0U && !request.allowLegacySha1;
    case MoonlightBridgeOperation::DeleteIdentity:
        return false;
    default:
        return false;
    }
}

bool runtimeReadyFor(const MoonlightBridgeCapabilities& capabilities,
                     MoonlightBridgeOperation operation) noexcept {
    if (operation == MoonlightBridgeOperation::Pair) {
        return capabilities.pairingReady;
    }
    if (operation == MoonlightBridgeOperation::Unpair) {
        // Sunshine exposes /unpair over HTTP. Local trust revocation must not
        // become unavailable just because the client identity backend is not
        // currently usable.
        return capabilities.transportReady;
    }
    if (operation == MoonlightBridgeOperation::DeleteIdentity) {
        return capabilities.identityDeletionReady;
    }
    return capabilities.hostControlReady;
}

bool cancellationRequested(
    const MoonlightNativeRuntimePort::CancellationProbe& probe) noexcept {
    try {
        return probe && probe();
    } catch (...) {
        return true;
    }
}

bool bridgeCodeValid(MoonlightBridgeCode code) noexcept {
    return code >= MoonlightBridgeCode::Ok &&
           code <= MoonlightBridgeCode::ShuttingDown;
}

bool terminalStageValid(MoonlightBridgeTerminalStage stage) noexcept {
    return stage >= MoonlightBridgeTerminalStage::Complete &&
           stage <= MoonlightBridgeTerminalStage::Cancelled;
}

bool truthValid(MoonlightBridgeTruth truth) noexcept {
    return truth >= MoonlightBridgeTruth::NotAttempted &&
           truth <= MoonlightBridgeTruth::Unknown;
}

struct KeyHash final {
    std::size_t operator()(const MoonlightBridgeRequestKey& key) const noexcept {
        std::size_t value = static_cast<std::size_t>(key.requestId);
        value ^= static_cast<std::size_t>(key.generation) + 0x9e3779b9U +
                 (value << 6U) + (value >> 2U);
        value ^= static_cast<std::size_t>(key.ownerToken) + 0x9e3779b9U +
                 (value << 6U) + (value >> 2U);
        return value;
    }
};

struct ActiveRequest final {
    MoonlightBridgeRequestKey key {};
    std::string lane;
    std::atomic<bool> cancelled {false};
};

struct LaneState final {
    std::uint64_t ownerToken = 0U;
    std::uint64_t generationWatermark = 0U;
    std::unordered_set<MoonlightBridgeRequestKey, KeyHash> seenKeys;
};

std::string laneFor(const MoonlightBridgeRequest& request) {
    const std::string ownerLane = request.ownerScopeFingerprint + ":" +
                                  std::to_string(request.key.ownerToken);
    if (request.operation == MoonlightBridgeOperation::DeleteIdentity) {
        return ownerLane + ":identity-admin";
    }
    return ownerLane + ":" + request.hostId;
}

MoonlightBridgeResult terminalResult(MoonlightBridgeOperation operation,
                                     const MoonlightBridgeRequestKey& key,
                                     MoonlightBridgeCode code) {
    MoonlightBridgeResult result;
    result.operation = operation;
    result.key = key;
    result.code = code;
    result.terminalStage = code == MoonlightBridgeCode::Ok
                               ? MoonlightBridgeTerminalStage::Complete
                           : code == MoonlightBridgeCode::Cancelled
                               ? MoonlightBridgeTerminalStage::Cancelled
                               : MoonlightBridgeTerminalStage::Failed;
    result.preflightTruth = code == MoonlightBridgeCode::Ok
                                ? MoonlightBridgeTruth::Confirmed
                                : MoonlightBridgeTruth::Failed;
    return result;
}

bool resultValid(const MoonlightBridgeResult& result,
                 MoonlightBridgeOperation operation,
                 const MoonlightBridgeRequestKey& key) {
    if (result.operation != operation || result.key != key ||
        !bridgeCodeValid(result.code) || !terminalStageValid(result.terminalStage) ||
        !truthValid(result.preflightTruth) || !truthValid(result.actionTruth) ||
        !truthValid(result.postconditionTruth) ||
        result.partialAppCount > MoonlightHostLimits::kMaxApps ||
        result.identityExistingCount > kMaxIdentityInventoryCount ||
        result.identityDeletedCount > result.identityExistingCount ||
        result.identityRemainingCount > kMaxIdentityInventoryCount ||
        result.observedAtMs > kMaxSafeInteger ||
        result.apps.size() > MoonlightHostLimits::kMaxApps ||
        result.asset.size() > MoonlightHostLimits::kMaxBodyBytes ||
        result.diagnostics.size() > kMaxDiagnostics ||
        !sha256HexOrEmpty(result.certificateSha256) ||
        (result.rtspSessionUrl.has_value() &&
         !boundedText(*result.rtspSessionUrl, kMaxRtspSessionUrlBytes))) {
        return false;
    }
    if (operation == MoonlightBridgeOperation::DeleteIdentity) {
        if (!result.apps.empty() || !result.asset.empty() ||
            !result.certificateSha256.empty() ||
            result.rtspSessionUrl.has_value() ||
            result.partialAppCount != 0U ||
            result.mutationMayHaveBeenSent) {
            return false;
        }
        if (result.code == MoonlightBridgeCode::Ok &&
            result.identityRemainingCount != 0U) {
            return false;
        }
    } else if (result.identityExistingCount != 0U ||
               result.identityDeletedCount != 0U ||
               result.identityRemainingCount != 0U) {
        return false;
    }
    if ((result.code == MoonlightBridgeCode::Ok &&
         result.terminalStage != MoonlightBridgeTerminalStage::Complete) ||
        (result.code == MoonlightBridgeCode::Cancelled &&
         result.terminalStage != MoonlightBridgeTerminalStage::Cancelled) ||
        (result.code != MoonlightBridgeCode::Ok &&
         result.code != MoonlightBridgeCode::Cancelled &&
         result.terminalStage != MoonlightBridgeTerminalStage::Failed)) {
        return false;
    }
    std::unordered_set<std::uint32_t> appIds;
    appIds.reserve(result.apps.size());
    for (const auto& app : result.apps) {
        if (app.id == 0U ||
            !boundedText(app.title, MoonlightHostLimits::kMaxAppTitleBytes) ||
            !appIds.insert(app.id).second) {
            return false;
        }
    }
    for (const auto& diagnostic : result.diagnostics) {
        if (!boundedText(diagnostic.stage, kMaxDiagnosticTokenBytes) ||
            !boundedText(diagnostic.code, kMaxDiagnosticTokenBytes) ||
            diagnostic.transportAttempts > kMaxSafeInteger ||
            diagnostic.byteCount > kMaxSafeInteger ||
            diagnostic.appIdFingerprint > kMaxSafeInteger) {
            return false;
        }
    }
    return true;
}

} // namespace

struct MoonlightNativeBridge::Impl final {
    Impl(std::shared_ptr<MoonlightNativeRuntimePort> valueRuntimePort,
         MonotonicClock valueClock)
        : runtimePort(std::move(valueRuntimePort)), clock(std::move(valueClock)) {}

    std::shared_ptr<MoonlightNativeRuntimePort> runtimePort;
    MonotonicClock clock;
    mutable std::mutex mutex;
    std::condition_variable cv;
    bool shuttingDown = false;
    std::unordered_map<MoonlightBridgeRequestKey, std::shared_ptr<ActiveRequest>, KeyHash>
        active;
    std::unordered_map<std::string, LaneState> lanes;
    std::deque<MoonlightBridgeEvent> events;
    std::uint64_t nextSequence = 1U;
};

namespace {

class ActiveLease final {
public:
    ActiveLease(std::shared_ptr<MoonlightNativeBridge::Impl> impl,
                std::shared_ptr<ActiveRequest> active) noexcept
        : impl_(std::move(impl)), active_(std::move(active)) {}

    ~ActiveLease() {
        if (impl_ == nullptr || active_ == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        const auto iterator = impl_->active.find(active_->key);
        if (iterator != impl_->active.end() && iterator->second == active_) {
            impl_->active.erase(iterator);
        }
        impl_->cv.notify_all();
    }

    ActiveLease(const ActiveLease&) = delete;
    ActiveLease& operator=(const ActiveLease&) = delete;

private:
    std::shared_ptr<MoonlightNativeBridge::Impl> impl_;
    std::shared_ptr<ActiveRequest> active_;
};

bool stale(const std::shared_ptr<MoonlightNativeBridge::Impl>& impl,
           const std::shared_ptr<ActiveRequest>& active) noexcept {
    try {
        std::lock_guard<std::mutex> lock(impl->mutex);
        const auto iterator = impl->lanes.find(active->lane);
        return iterator == impl->lanes.end() ||
               iterator->second.generationWatermark > active->key.generation;
    } catch (...) {
        return true;
    }
}

void publishEvent(const std::shared_ptr<MoonlightNativeBridge::Impl>& impl,
                  const MoonlightBridgeResult& result) noexcept {
    if (impl == nullptr || !result.key.valid()) {
        return;
    }
    try {
        MoonlightBridgeEvent event;
        event.operation = result.operation;
        event.key = result.key;
        event.code = result.code;
        event.terminalStage = result.terminalStage;
        event.monotonicTimestampMs = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                impl->clock().time_since_epoch())
                .count());
        std::lock_guard<std::mutex> lock(impl->mutex);
        event.sequence = impl->nextSequence++;
        if (impl->events.size() >= kMaxEvents) {
            impl->events.pop_front();
        }
        impl->events.push_back(std::move(event));
    } catch (...) {
        // Event telemetry must never change the operation result.
    }
}

MoonlightBridgeResult publishAndReturn(
    const std::shared_ptr<MoonlightNativeBridge::Impl>& impl,
    MoonlightBridgeResult result) noexcept {
    publishEvent(impl, result);
    return result;
}

} // namespace

MoonlightBridgeRequest::~MoonlightBridgeRequest() {
    secureWipeBytes(pin);
    secureWipeBytes(riKey);
}

MoonlightBridgeRequest::MoonlightBridgeRequest(MoonlightBridgeRequest&& other) noexcept
    : operation(other.operation), key(other.key),
      ownerScopeFingerprint(std::move(other.ownerScopeFingerprint)),
      installationId(std::move(other.installationId)), hostId(std::move(other.hostId)),
      serverUuid(std::move(other.serverUuid)),
      pinnedCertificateSha256(std::move(other.pinnedCertificateSha256)),
      endpoint(std::move(other.endpoint)),
      timeout(other.timeout), appId(other.appId),
      catalogGeneration(other.catalogGeneration),
      expectedCurrentAppId(other.expectedCurrentAppId),
      userConfirmedTermination(other.userConfirmedTermination),
      allowLegacySha1(other.allowLegacySha1), pin(std::move(other.pin)),
      riKey(std::move(other.riKey)), riKeyId(other.riKeyId),
      launchConfiguration(other.launchConfiguration) {
    other.key = {};
    other.timeout = MoonlightHostLimits::kDefaultTimeout;
    other.appId = 0U;
    other.catalogGeneration = 0U;
    other.expectedCurrentAppId = 0U;
    other.userConfirmedTermination = false;
    other.allowLegacySha1 = false;
    other.riKeyId = 0;
    other.launchConfiguration = {};
}

MoonlightBridgeRequest& MoonlightBridgeRequest::operator=(
    MoonlightBridgeRequest&& other) noexcept {
    if (this != &other) {
        secureWipeBytes(pin);
        secureWipeBytes(riKey);
        operation = other.operation;
        key = other.key;
        ownerScopeFingerprint = std::move(other.ownerScopeFingerprint);
        installationId = std::move(other.installationId);
        hostId = std::move(other.hostId);
        serverUuid = std::move(other.serverUuid);
        pinnedCertificateSha256 = std::move(other.pinnedCertificateSha256);
        endpoint = std::move(other.endpoint);
        timeout = other.timeout;
        appId = other.appId;
        catalogGeneration = other.catalogGeneration;
        expectedCurrentAppId = other.expectedCurrentAppId;
        userConfirmedTermination = other.userConfirmedTermination;
        allowLegacySha1 = other.allowLegacySha1;
        pin = std::move(other.pin);
        riKey = std::move(other.riKey);
        riKeyId = other.riKeyId;
        launchConfiguration = other.launchConfiguration;
        other.key = {};
        other.appId = 0U;
        other.catalogGeneration = 0U;
        other.expectedCurrentAppId = 0U;
        other.userConfirmedTermination = false;
        other.allowLegacySha1 = false;
        other.riKeyId = 0;
        other.launchConfiguration = {};
    }
    return *this;
}

MoonlightBridgeResult::~MoonlightBridgeResult() {
    secureWipeString(certificateSha256);
    secureWipeOptionalString(rtspSessionUrl);
}

MoonlightBridgeResult::MoonlightBridgeResult(MoonlightBridgeResult&& other) noexcept
    : operation(other.operation), key(other.key), code(other.code),
      terminalStage(other.terminalStage), preflightTruth(other.preflightTruth),
      actionTruth(other.actionTruth), postconditionTruth(other.postconditionTruth),
      partialAppCount(other.partialAppCount), observedAtMs(other.observedAtMs),
      idempotent(other.idempotent),
      mutationMayHaveBeenSent(other.mutationMayHaveBeenSent),
      identityExistingCount(other.identityExistingCount),
      identityDeletedCount(other.identityDeletedCount),
      identityRemainingCount(other.identityRemainingCount),
      apps(std::move(other.apps)), asset(std::move(other.asset)),
      certificateSha256(std::move(other.certificateSha256)),
      rtspSessionUrl(std::move(other.rtspSessionUrl)),
      diagnostics(std::move(other.diagnostics)) {
    other.identityExistingCount = 0U;
    other.identityDeletedCount = 0U;
    other.identityRemainingCount = 0U;
    secureWipeString(other.certificateSha256);
    secureWipeOptionalString(other.rtspSessionUrl);
}

MoonlightBridgeResult& MoonlightBridgeResult::operator=(
    MoonlightBridgeResult&& other) noexcept {
    if (this != &other) {
        secureWipeString(certificateSha256);
        secureWipeOptionalString(rtspSessionUrl);
        operation = other.operation;
        key = other.key;
        code = other.code;
        terminalStage = other.terminalStage;
        preflightTruth = other.preflightTruth;
        actionTruth = other.actionTruth;
        postconditionTruth = other.postconditionTruth;
        partialAppCount = other.partialAppCount;
        observedAtMs = other.observedAtMs;
        idempotent = other.idempotent;
        mutationMayHaveBeenSent = other.mutationMayHaveBeenSent;
        identityExistingCount = other.identityExistingCount;
        identityDeletedCount = other.identityDeletedCount;
        identityRemainingCount = other.identityRemainingCount;
        apps = std::move(other.apps);
        asset = std::move(other.asset);
        certificateSha256 = std::move(other.certificateSha256);
        rtspSessionUrl = std::move(other.rtspSessionUrl);
        diagnostics = std::move(other.diagnostics);
        other.identityExistingCount = 0U;
        other.identityDeletedCount = 0U;
        other.identityRemainingCount = 0U;
        secureWipeString(other.certificateSha256);
        secureWipeOptionalString(other.rtspSessionUrl);
    }
    return *this;
}

MoonlightBridgeCapabilities MoonlightUnavailableRuntimePort::capabilities() const noexcept {
    return {};
}

MoonlightBridgeResult MoonlightUnavailableRuntimePort::execute(
    MoonlightBridgeRequest request,
    const CancellationProbe& cancellationProbe) {
    const auto code = cancellationProbe && cancellationProbe()
                          ? MoonlightBridgeCode::Cancelled
                          : MoonlightBridgeCode::RuntimeProofRequired;
    return terminalResult(request.operation, request.key, code);
}

void MoonlightUnavailableRuntimePort::cancel(
    const MoonlightBridgeRequestKey& /*key*/) noexcept {}

MoonlightNativeBridge::MoonlightNativeBridge(
    std::shared_ptr<MoonlightNativeRuntimePort> runtimePort,
    MonotonicClock monotonicClock) {
    if (runtimePort == nullptr) {
        runtimePort = std::make_shared<MoonlightUnavailableRuntimePort>();
    }
    if (!monotonicClock) {
        monotonicClock = []() { return std::chrono::steady_clock::now(); };
    }
    impl_ = std::make_shared<Impl>(std::move(runtimePort), std::move(monotonicClock));
}

MoonlightNativeBridge::~MoonlightNativeBridge() {
    shutdown();
    std::atomic_store_explicit(&impl_, std::shared_ptr<Impl> {},
                               std::memory_order_release);
}

MoonlightBridgeCapabilities MoonlightNativeBridge::capabilities() const noexcept {
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr || impl->runtimePort == nullptr) {
            return {};
        }
        auto capabilities = impl->runtimePort->capabilities();
        capabilities.bridgeCompiled = true;
        std::lock_guard<std::mutex> lock(impl->mutex);
        if (impl->shuttingDown) {
            capabilities.pairingReady = false;
            capabilities.hostControlReady = false;
            capabilities.blocker = "shutting_down";
        }
        return capabilities;
    } catch (...) {
        return {};
    }
}

MoonlightBridgeResult MoonlightNativeBridge::execute(
    MoonlightBridgeRequest request,
    MoonlightNativeRuntimePort::CancellationProbe externalCancellation) noexcept {
    const auto operation = request.operation;
    const auto key = request.key;
    const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
    if (impl == nullptr) {
        return terminalResult(operation, key, MoonlightBridgeCode::ShuttingDown);
    }
    try {
        if (!requestValid(request)) {
            return publishAndReturn(
                impl, terminalResult(operation, key, MoonlightBridgeCode::InvalidArgument));
        }
        auto active = std::make_shared<ActiveRequest>();
        active->key = key;
        active->lane = laneFor(request);
        std::optional<MoonlightBridgeCode> admissionFailure;
        std::vector<MoonlightBridgeRequestKey> supersededKeys;
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            if (impl->shuttingDown) {
                admissionFailure = MoonlightBridgeCode::ShuttingDown;
            } else if (impl->active.find(key) != impl->active.end()) {
                admissionFailure = MoonlightBridgeCode::Busy;
            } else {
                auto& lane = impl->lanes[active->lane];
                if (lane.ownerToken == 0U) {
                    lane.ownerToken = key.ownerToken;
                }
                if (lane.ownerToken != key.ownerToken) {
                    admissionFailure = MoonlightBridgeCode::ProtocolFailure;
                } else if (key.generation < lane.generationWatermark) {
                    admissionFailure = MoonlightBridgeCode::Stale;
                } else if (key.generation == lane.generationWatermark &&
                           lane.seenKeys.find(key) != lane.seenKeys.end()) {
                    admissionFailure = MoonlightBridgeCode::Busy;
                } else if (key.generation == lane.generationWatermark &&
                           lane.seenKeys.size() >= kMaxSeenKeysPerLaneGeneration) {
                    admissionFailure = MoonlightBridgeCode::Busy;
                } else {
                    const bool advancesGeneration =
                        key.generation > lane.generationWatermark;
                    if (advancesGeneration) {
                        supersededKeys.reserve(impl->active.size());
                    }
                    bool seenInserted = false;
                    bool activeInserted = false;
                    try {
                        seenInserted = lane.seenKeys.insert(key).second;
                        if (seenInserted) {
                            activeInserted = impl->active.emplace(key, active).second;
                        }
                    } catch (...) {
                        if (activeInserted) {
                            impl->active.erase(key);
                        }
                        if (seenInserted) {
                            lane.seenKeys.erase(key);
                        }
                        throw;
                    }
                    if (!seenInserted || !activeInserted) {
                        if (seenInserted) {
                            lane.seenKeys.erase(key);
                        }
                        admissionFailure = MoonlightBridgeCode::Busy;
                    } else if (advancesGeneration) {
                        // Publish the generation only after both admission
                        // indexes own the new request. From this point onward,
                        // retiring the old generation is allocation-free.
                        lane.generationWatermark = key.generation;
                        for (auto iterator = lane.seenKeys.begin();
                             iterator != lane.seenKeys.end();) {
                            if (*iterator == key) {
                                ++iterator;
                            } else {
                                iterator = lane.seenKeys.erase(iterator);
                            }
                        }
                        for (const auto& item : impl->active) {
                            if (item.second == active ||
                                item.second->lane != active->lane ||
                                item.first.generation >= key.generation) {
                                continue;
                            }
                            bool expected = false;
                            if (item.second->cancelled.compare_exchange_strong(
                                    expected, true, std::memory_order_acq_rel)) {
                                supersededKeys.push_back(item.first);
                            }
                        }
                    }
                }
            }
        }
        if (admissionFailure.has_value()) {
            return publishAndReturn(
                impl, terminalResult(operation, key, *admissionFailure));
        }
        ActiveLease lease(impl, active);
        if (impl->runtimePort != nullptr) {
            for (const auto& supersededKey : supersededKeys) {
                impl->runtimePort->cancel(supersededKey);
            }
        }
        auto cancelled = [impl, active, externalCancellation]() {
            return active->cancelled.load(std::memory_order_acquire) ||
                   cancellationRequested(externalCancellation) || stale(impl, active);
        };
        if (cancelled() && operation != MoonlightBridgeOperation::Unpair) {
            return publishAndReturn(
                impl, terminalResult(operation, key, MoonlightBridgeCode::Cancelled));
        }
        if (impl->runtimePort == nullptr) {
            return publishAndReturn(
                impl, terminalResult(operation, key, MoonlightBridgeCode::Unavailable));
        }
        const auto capabilities = impl->runtimePort->capabilities();
        if (!runtimeReadyFor(capabilities, operation)) {
            return publishAndReturn(
                impl, terminalResult(operation, key,
                                     MoonlightBridgeCode::RuntimeProofRequired));
        }
        auto result = impl->runtimePort->execute(
            std::move(request), cancelled);
        if (active->cancelled.load(std::memory_order_acquire) ||
            cancellationRequested(externalCancellation)) {
            result = terminalResult(operation, key, MoonlightBridgeCode::Cancelled);
        } else if (stale(impl, active)) {
            result = terminalResult(operation, key, MoonlightBridgeCode::Stale);
        } else if (!resultValid(result, operation, key)) {
            result = terminalResult(operation, key, MoonlightBridgeCode::ProtocolFailure);
        }
        return publishAndReturn(impl, std::move(result));
    } catch (...) {
        return publishAndReturn(
            impl, terminalResult(operation, key, MoonlightBridgeCode::ProtocolFailure));
    }
}

bool MoonlightNativeBridge::cancel(const MoonlightBridgeRequestKey& key) noexcept {
    if (!key.valid()) {
        return false;
    }
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            return false;
        }
        std::shared_ptr<ActiveRequest> active;
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            const auto iterator = impl->active.find(key);
            if (iterator == impl->active.end()) {
                return false;
            }
            active = iterator->second;
            bool expected = false;
            if (!active->cancelled.compare_exchange_strong(
                    expected, true, std::memory_order_acq_rel)) {
                return false;
            }
        }
        if (impl->runtimePort != nullptr) {
            impl->runtimePort->cancel(key);
        }
        return true;
    } catch (...) {
        return false;
    }
}

std::size_t MoonlightNativeBridge::cancelOwner(std::uint64_t ownerToken) noexcept {
    if (ownerToken == 0U) {
        return 0U;
    }
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            return 0U;
        }
        std::vector<MoonlightBridgeRequestKey> keys;
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            for (const auto& item : impl->active) {
                if (item.first.ownerToken != ownerToken) {
                    continue;
                }
                bool expected = false;
                if (item.second->cancelled.compare_exchange_strong(
                        expected, true, std::memory_order_acq_rel)) {
                    keys.push_back(item.first);
                }
            }
            for (auto iterator = impl->lanes.begin();
                 iterator != impl->lanes.end();) {
                if (iterator->second.ownerToken == ownerToken) {
                    iterator = impl->lanes.erase(iterator);
                } else {
                    ++iterator;
                }
            }
        }
        if (impl->runtimePort != nullptr) {
            for (const auto& key : keys) {
                impl->runtimePort->cancel(key);
            }
        }
        return keys.size();
    } catch (...) {
        return 0U;
    }
}

std::vector<MoonlightBridgeEvent> MoonlightNativeBridge::pollEvents(
    std::uint64_t ownerToken, std::uint64_t afterSequence,
    std::size_t limit) const noexcept {
    std::vector<MoonlightBridgeEvent> result;
    if (ownerToken == 0U || limit == 0U) {
        return result;
    }
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            return result;
        }
        const auto boundedLimit = std::min(limit, kMaxPollEvents);
        std::lock_guard<std::mutex> lock(impl->mutex);
        result.reserve(std::min(boundedLimit, impl->events.size()));
        for (const auto& event : impl->events) {
            if (event.key.ownerToken != ownerToken || event.sequence <= afterSequence) {
                continue;
            }
            result.push_back(event);
            if (result.size() >= boundedLimit) {
                break;
            }
        }
    } catch (...) {
        result.clear();
    }
    return result;
}

void MoonlightNativeBridge::shutdown() noexcept {
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            return;
        }
        std::vector<MoonlightBridgeRequestKey> keys;
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            if (!impl->shuttingDown) {
                impl->shuttingDown = true;
                keys.reserve(impl->active.size());
                for (const auto& item : impl->active) {
                    item.second->cancelled.store(true, std::memory_order_release);
                    keys.push_back(item.first);
                }
            }
        }
        if (impl->runtimePort != nullptr) {
            for (const auto& key : keys) {
                impl->runtimePort->cancel(key);
            }
        }
        std::unique_lock<std::mutex> lock(impl->mutex);
        impl->cv.wait(lock, [&]() { return impl->active.empty(); });
    } catch (...) {
        // Destruction and NAPI environment cleanup cannot propagate exceptions.
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::uint64_t MoonlightNativeBridge::secureCleanseCountForTesting() noexcept {
    return gBridgeCleanseCount.load(std::memory_order_relaxed);
}

void MoonlightNativeBridge::resetSecureCleanseCountForTesting() noexcept {
    gBridgeCleanseCount.store(0U, std::memory_order_relaxed);
}
#endif

const char* moonlightBridgeOperationName(MoonlightBridgeOperation operation) noexcept {
    switch (operation) {
    case MoonlightBridgeOperation::Pair:
        return "pair";
    case MoonlightBridgeOperation::Catalog:
        return "catalog";
    case MoonlightBridgeOperation::Asset:
        return "asset";
    case MoonlightBridgeOperation::Launch:
        return "launch";
    case MoonlightBridgeOperation::Resume:
        return "resume";
    case MoonlightBridgeOperation::Quit:
        return "quit";
    case MoonlightBridgeOperation::Unpair:
        return "unpair";
    case MoonlightBridgeOperation::DeleteIdentity:
        return "delete_identity";
    default:
        return "unknown";
    }
}

const char* moonlightBridgeCodeName(MoonlightBridgeCode code) noexcept {
    switch (code) {
    case MoonlightBridgeCode::Ok:
        return "ok";
    case MoonlightBridgeCode::InvalidArgument:
        return "invalid_argument";
    case MoonlightBridgeCode::Busy:
        return "busy";
    case MoonlightBridgeCode::RuntimeProofRequired:
        return "runtime_proof_required";
    case MoonlightBridgeCode::Unavailable:
        return "unavailable";
    case MoonlightBridgeCode::Unpaired:
        return "unpaired";
    case MoonlightBridgeCode::AppNotFound:
        return "app_not_found";
    case MoonlightBridgeCode::InvalidCatalog:
        return "invalid_catalog";
    case MoonlightBridgeCode::ResumeRequired:
        return "resume_required";
    case MoonlightBridgeCode::HostBusy:
        return "host_busy";
    case MoonlightBridgeCode::ConfirmationRequired:
        return "confirmation_required";
    case MoonlightBridgeCode::ActionRejected:
        return "action_rejected";
    case MoonlightBridgeCode::OutcomeUnknown:
        return "outcome_unknown";
    case MoonlightBridgeCode::Cancelled:
        return "cancelled";
    case MoonlightBridgeCode::Stale:
        return "stale";
    case MoonlightBridgeCode::DeadlineExceeded:
        return "deadline_exceeded";
    case MoonlightBridgeCode::TransportFailure:
        return "transport_failure";
    case MoonlightBridgeCode::ProtocolFailure:
        return "protocol_failure";
    case MoonlightBridgeCode::RepairRequired:
        return "repair_required";
    case MoonlightBridgeCode::ShuttingDown:
        return "shutting_down";
    default:
        return "protocol_failure";
    }
}

const char* moonlightBridgeTruthName(MoonlightBridgeTruth truth) noexcept {
    switch (truth) {
    case MoonlightBridgeTruth::NotAttempted:
        return "not_attempted";
    case MoonlightBridgeTruth::Confirmed:
        return "confirmed";
    case MoonlightBridgeTruth::Failed:
        return "failed";
    case MoonlightBridgeTruth::Unknown:
        return "unknown";
    default:
        return "unknown";
    }
}

const char* moonlightBridgeTerminalStageName(
    MoonlightBridgeTerminalStage stage) noexcept {
    switch (stage) {
    case MoonlightBridgeTerminalStage::Complete:
        return "complete";
    case MoonlightBridgeTerminalStage::Cancelled:
        return "cancelled";
    case MoonlightBridgeTerminalStage::Failed:
    default:
        return "failed";
    }
}

} // namespace remotedesk::moonlight
