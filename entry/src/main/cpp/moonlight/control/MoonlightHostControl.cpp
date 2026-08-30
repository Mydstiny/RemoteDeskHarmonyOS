#include "moonlight/control/MoonlightHostControl.h"

#include "common/network_generation_fence.h"

#include <openssl/crypto.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cmath>
#include <cstdio>
#include <limits>
#include <mutex>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kRiKeyBytes = 16U;
constexpr std::size_t kMaxIdentityBytes = 256U;

constexpr std::uint64_t kCodecH264 = 0x00000001U;
constexpr std::uint64_t kCodecHevc = 0x00000100U;
constexpr std::uint64_t kCodecAv1 = 0x00010000U;

std::uint64_t requiredCodecBit(
    MoonlightLaunchConfiguration::VideoCodec codec) noexcept {
    switch (codec) {
        case MoonlightLaunchConfiguration::VideoCodec::H264: return kCodecH264;
        case MoonlightLaunchConfiguration::VideoCodec::Hevc: return kCodecHevc;
        case MoonlightLaunchConfiguration::VideoCodec::Av1: return kCodecAv1;
    }
    return 0U;
}

bool adaptLaunchVideoMode(MoonlightLaunchConfiguration& configuration,
                          const MoonlightServerInfo& server) noexcept {
    const std::uint64_t codecBit = requiredCodecBit(configuration.videoCodec);
    if (codecBit == 0U || !server.codecModeSupport.has_value() ||
        ((*server.codecModeSupport & codecBit) == 0U)) {
        return false;
    }
    if (configuration.resolutionPolicy !=
        MoonlightLaunchConfiguration::ResolutionPolicy::HostCapability) {
        return true;
    }
    const std::optional<std::uint64_t> maximumLuma =
        configuration.videoCodec == MoonlightLaunchConfiguration::VideoCodec::H264 ?
            server.maxLumaPixelsH264 : server.maxLumaPixelsHevc;
    if (!maximumLuma.has_value() || *maximumLuma == 0U) {
        return true;
    }
    const std::uint64_t requestedLuma =
        static_cast<std::uint64_t>(configuration.width) * configuration.height;
    if (requestedLuma <= *maximumLuma) {
        return true;
    }
    // Sunshine's luma receipt is a pixel-area ceiling, not a list of 16:9
    // modes. Scale the admitted request directly so a 16:10/3:2 device does
    // not fall back to a hard-coded 16:9 mode and reintroduce letterboxing.
    const long double scale = std::sqrt(
        static_cast<long double>(*maximumLuma) /
        static_cast<long double>(requestedLuma));
    std::uint32_t scaledWidth = static_cast<std::uint32_t>(
        std::floor(static_cast<long double>(configuration.width) * scale));
    std::uint32_t scaledHeight = static_cast<std::uint32_t>(
        std::floor(static_cast<long double>(configuration.height) * scale));
    scaledWidth -= scaledWidth % 2U;
    scaledHeight -= scaledHeight % 2U;
    if (scaledWidth < 320U || scaledHeight < 240U ||
        static_cast<std::uint64_t>(scaledWidth) * scaledHeight > *maximumLuma) {
        return false;
    }
    configuration.width = scaledWidth;
    configuration.height = scaledHeight;
    return true;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::atomic<std::uint64_t> gControlCleanseCount {0};
#endif

void secureWipe(void* pointer, std::size_t size) noexcept {
    if (pointer != nullptr && size != 0U) {
        OPENSSL_cleanse(pointer, size);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        gControlCleanseCount.fetch_add(1U, std::memory_order_relaxed);
#endif
    }
}

void secureWipeString(std::string& value) noexcept {
    secureWipe(value.empty() ? nullptr : value.data(), value.size());
    value.clear();
}

void secureWipeOptionalString(std::optional<std::string>& value) noexcept {
    if (value.has_value()) {
        secureWipeString(*value);
        value.reset();
    }
}

void secureWipeBytes(std::vector<std::uint8_t>& value) noexcept {
    secureWipe(value.empty() ? nullptr : value.data(), value.size());
    value.clear();
}

class QueryWiper final {
public:
    explicit QueryWiper(MoonlightHostCall& call) noexcept : call_(call) {}
    ~QueryWiper() {
        for (auto& item : call_.query) {
            secureWipeString(item.value);
        }
        call_.query.clear();
    }

    QueryWiper(const QueryWiper&) = delete;
    QueryWiper& operator=(const QueryWiper&) = delete;

private:
    MoonlightHostCall& call_;
};

class StringWiper final {
public:
    explicit StringWiper(std::string& value) noexcept : value_(value) {}
    ~StringWiper() { secureWipeString(value_); }

    StringWiper(const StringWiper&) = delete;
    StringWiper& operator=(const StringWiper&) = delete;

private:
    std::string& value_;
};

class HostResultTransientWiper final {
public:
    explicit HostResultTransientWiper(MoonlightHostResult& result) noexcept : result_(result) {}
    ~HostResultTransientWiper() {
        if (result_.action.has_value()) {
            secureWipeOptionalString(result_.action->rtspSessionUrl);
        }
    }

    HostResultTransientWiper(const HostResultTransientWiper&) = delete;
    HostResultTransientWiper& operator=(const HostResultTransientWiper&) = delete;

private:
    MoonlightHostResult& result_;
};

struct ControlKeyHash final {
    std::size_t operator()(const MoonlightHostControlOperationKey& key) const noexcept {
        std::size_t value = static_cast<std::size_t>(key.requestId);
        value ^= static_cast<std::size_t>(key.generation) + 0x9e3779b9U + (value << 6U) +
                 (value >> 2U);
        value ^= static_cast<std::size_t>(key.ownerToken) + 0x9e3779b9U + (value << 6U) +
                 (value >> 2U);
        return value;
    }
};

struct ActiveControl final {
    ActiveControl(MoonlightHostControlOperationKey valueKey, std::string valueLane,
                  bool valueMutation)
        : key(valueKey), lane(std::move(valueLane)), mutation(valueMutation),
          network(remotedesk::net::ProcessNetworkGenerationFence().snapshot()) {}

    MoonlightHostControlOperationKey key {};
    std::string lane;
    bool mutation = false;
    remotedesk::net::NetworkGenerationSnapshot network {};
    std::atomic<bool> cancelled {false};
};

struct CatalogSnapshot final {
    std::uint64_t ownerToken = 0;
    std::uint64_t generation = 0;
    std::string serverUuid;
    std::unordered_set<std::uint32_t> appIds;
};

struct LaneState final {
    std::uint64_t generationOwnerToken = 0;
    std::uint64_t generationWatermark = 0;
    std::size_t readers = 0;
    bool mutation = false;
    std::optional<CatalogSnapshot> catalog;
};

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

bool contextShapeValid(const MoonlightHostControlContext& context) noexcept {
    return context.key.valid() && ownerFingerprintValid(context.ownerScopeFingerprint) &&
           boundedText(context.hostId, kMaxIdentityBytes) &&
           boundedText(context.serverUuid, kMaxIdentityBytes) &&
           context.endpoint.pinnedTrustAvailable &&
           !context.endpoint.allowHttpPairingCandidate &&
           context.timeout >= MoonlightHostLimits::kMinTimeout &&
           context.timeout <= MoonlightHostLimits::kMaxStandardTimeout;
}

std::string laneFor(const MoonlightHostControlContext& context) {
    return context.ownerScopeFingerprint + ":" + context.hostId;
}

MoonlightHostRequestKey hostKey(const MoonlightHostControlOperationKey& key) noexcept {
    return {key.requestId, key.generation, key.ownerToken};
}

std::uint64_t appIdFingerprint(std::uint32_t appId) noexcept {
    std::uint64_t value = static_cast<std::uint64_t>(appId) + 0x9e3779b97f4a7c15ULL;
    value = (value ^ (value >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27U)) * 0x94d049bb133111ebULL;
    // This diagnostic crosses the N-API boundary as a JavaScript Number.
    // Keep the privacy-preserving fingerprint within the exact-integer range
    // so a valid launch cannot be rejected by the native bridge's shape check.
    return (value ^ (value >> 31U)) & 0x1fffffffffffffULL;
}

bool possiblySent(const MoonlightHostResult& result) noexcept {
    if (result.mutationOutcomeUnknown || result.error == MoonlightHostError::ActionUnknown) {
        return true;
    }
    return std::any_of(result.diagnostics.begin(), result.diagnostics.end(), [](const auto& item) {
        return item.sendState != MoonlightTransportSendState::NotSent;
    });
}

bool responseUnknown(const MoonlightHostResult& result) noexcept {
    if (result.mutationOutcomeUnknown || result.error == MoonlightHostError::ActionUnknown) {
        return true;
    }
    return std::any_of(result.diagnostics.begin(), result.diagnostics.end(), [](const auto& item) {
        return item.sendState == MoonlightTransportSendState::SentResponseUnknown;
    });
}

void transition(MoonlightHostControlResult& result, MoonlightHostControlStage stage) {
    result.stageTrace.push_back(stage);
    result.terminalStage = stage;
}

MoonlightHostControlResult finish(MoonlightHostControlResult result,
                                  MoonlightHostControlCode code) {
    result.code = code;
    transition(result, code == MoonlightHostControlCode::Ok
                           ? MoonlightHostControlStage::Complete
                       : code == MoonlightHostControlCode::Cancelled
                           ? MoonlightHostControlStage::Cancelled
                           : MoonlightHostControlStage::Failed);
    return result;
}

MoonlightHostControlCode mapHostFailure(const MoonlightHostResult& result,
                                        bool mutationStarted) noexcept {
    if (result.error == MoonlightHostError::HostBusy) {
        return MoonlightHostControlCode::HostBusy;
    }
    if (mutationStarted && responseUnknown(result)) {
        return MoonlightHostControlCode::OutcomeUnknown;
    }
    switch (result.error) {
    case MoonlightHostError::Cancelled:
        return MoonlightHostControlCode::Cancelled;
    case MoonlightHostError::StaleRequest:
    case MoonlightHostError::TrustConflict:
        return MoonlightHostControlCode::Stale;
    case MoonlightHostError::DeadlineExceeded:
        return MoonlightHostControlCode::DeadlineExceeded;
    case MoonlightHostError::HostBusy:
        return MoonlightHostControlCode::HostBusy;
    case MoonlightHostError::HttpUnauthorized:
        return MoonlightHostControlCode::Unpaired;
    case MoonlightHostError::ActionUnknown:
        return MoonlightHostControlCode::OutcomeUnknown;
    case MoonlightHostError::InvalidRequest:
    case MoonlightHostError::InvalidEndpoint:
    case MoonlightHostError::InvalidPort:
    case MoonlightHostError::InvalidQuery:
    case MoonlightHostError::UrlTooLong:
    case MoonlightHostError::MalformedXml:
    case MoonlightHostError::XmlBudgetExceeded:
    case MoonlightHostError::MissingRequiredField:
    case MoonlightHostError::InvalidField:
    case MoonlightHostError::DuplicateApp:
    case MoonlightHostError::BodyTooLarge:
        return MoonlightHostControlCode::ProtocolFailure;
    case MoonlightHostError::XmlStatusRejected:
        return mutationStarted ? MoonlightHostControlCode::ActionRejected
                               : MoonlightHostControlCode::ProtocolFailure;
    case MoonlightHostError::RequestBusy:
        return MoonlightHostControlCode::Busy;
    case MoonlightHostError::ShuttingDown:
        return MoonlightHostControlCode::ShuttingDown;
    case MoonlightHostError::None:
        return MoonlightHostControlCode::Ok;
    default:
        return MoonlightHostControlCode::TransportFailure;
    }
}

void observeHostResult(MoonlightHostControlResult& result, MoonlightHostControlOperation operation,
                       MoonlightHostControlStage stage, const MoonlightHostResult& hostResult,
                       std::uint32_t appId = 0) {
    result.lastHostError = hostResult.error;
    result.lastHttpStatus = hostResult.httpStatus;
    result.lastXmlStatus = hostResult.xmlStatus.value_or(0);
    result.transportAttempts += hostResult.diagnostics.size();

    MoonlightHostControlDiagnostic diagnostic;
    diagnostic.operation = operation;
    diagnostic.stage = stage;
    diagnostic.code = mapHostFailure(hostResult, false);
    diagnostic.hostError = hostResult.error;
    diagnostic.httpStatus = hostResult.httpStatus;
    diagnostic.xmlStatus = hostResult.xmlStatus.value_or(0);
    diagnostic.transportAttempts = hostResult.diagnostics.size();
    diagnostic.generation = result.generation;
    diagnostic.appIdFingerprint = appId == 0U ? 0U : appIdFingerprint(appId);
    for (const auto& item : hostResult.diagnostics) {
        diagnostic.byteCount += item.byteCount;
    }
    result.diagnostics.push_back(std::move(diagnostic));
}

std::vector<MoonlightHostQueryParameter> dummyLaunchQuery(std::uint32_t appId) {
    return {
        {"appid", std::to_string(appId)},
        {"mode", "1920x1080x60"},
        {"additionalStates", "1"},
        {"sops", "1"},
        {"rikey", "00000000000000000000000000000000"},
        {"rikeyid", "0"},
        {"localAudioPlayMode", "0"},
        {"surroundAudioInfo", "196610"},
        {"remoteControllersBitmap", "0"},
        {"gcmap", "0"},
        {"gcpersist", "0"},
    };
}

} // namespace

struct MoonlightHostControl::Impl final {
    Impl(std::shared_ptr<MoonlightHostApi> valueHostApi,
         std::shared_ptr<MoonlightHostControlAccessPort> valueAccessPort,
         MonotonicClock valueMonotonicClock, WallClock valueWallClock)
        : hostApi(std::move(valueHostApi)), accessPort(std::move(valueAccessPort)),
          monotonicClock(std::move(valueMonotonicClock)), wallClock(std::move(valueWallClock)) {}

    std::shared_ptr<MoonlightHostApi> hostApi;
    std::shared_ptr<MoonlightHostControlAccessPort> accessPort;
    MonotonicClock monotonicClock;
    WallClock wallClock;
    std::mutex mutex;
    std::condition_variable cv;
    bool shuttingDown = false;
    std::unordered_map<MoonlightHostControlOperationKey, std::shared_ptr<ActiveControl>,
                       ControlKeyHash>
        active;
    std::unordered_map<std::string, LaneState> lanes;
    std::optional<std::uint64_t> activeMutationOwner;
    std::size_t activeMutations = 0;
};

namespace {

class ActiveLease final {
public:
    ActiveLease(std::shared_ptr<MoonlightHostControl::Impl> impl,
                std::shared_ptr<ActiveControl> active)
        : impl_(std::move(impl)), active_(std::move(active)) {}

    ~ActiveLease() {
        if (impl_ == nullptr || active_ == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        const auto activeIterator = impl_->active.find(active_->key);
        if (activeIterator != impl_->active.end() && activeIterator->second == active_) {
            impl_->active.erase(activeIterator);
        }
        const auto laneIterator = impl_->lanes.find(active_->lane);
        if (laneIterator != impl_->lanes.end()) {
            if (active_->mutation) {
                laneIterator->second.mutation = false;
                if (impl_->activeMutations != 0U) {
                    --impl_->activeMutations;
                }
                if (impl_->activeMutations == 0U) {
                    impl_->activeMutationOwner.reset();
                }
            } else if (laneIterator->second.readers != 0U) {
                --laneIterator->second.readers;
            }
        }
        impl_->cv.notify_all();
    }

    ActiveLease(const ActiveLease&) = delete;
    ActiveLease& operator=(const ActiveLease&) = delete;

private:
    std::shared_ptr<MoonlightHostControl::Impl> impl_;
    std::shared_ptr<ActiveControl> active_;
};

struct Admission final {
    MoonlightHostControlCode code = MoonlightHostControlCode::InvalidArgument;
    std::shared_ptr<ActiveControl> active;
};

Admission admit(const std::shared_ptr<MoonlightHostControl::Impl>& impl,
                const MoonlightHostControlContext& context, bool mutation) {
    Admission admission;
    if (impl == nullptr) {
        admission.code = MoonlightHostControlCode::ShuttingDown;
        return admission;
    }
    const std::string lane = laneFor(context);
    auto active = std::make_shared<ActiveControl>(context.key, lane, mutation);
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->shuttingDown) {
        admission.code = MoonlightHostControlCode::ShuttingDown;
        return admission;
    }
    if (impl->active.find(context.key) != impl->active.end()) {
        admission.code = MoonlightHostControlCode::Busy;
        return admission;
    }
    auto& laneState = impl->lanes[lane];
    if (laneState.generationOwnerToken == context.key.ownerToken &&
        context.key.generation < laneState.generationWatermark) {
        admission.code = MoonlightHostControlCode::Stale;
        return admission;
    }
    if ((laneState.mutation || laneState.readers != 0U) &&
        laneState.generationOwnerToken != context.key.ownerToken) {
        admission.code = MoonlightHostControlCode::Busy;
        return admission;
    }
    if ((mutation && (laneState.mutation || laneState.readers != 0U)) ||
        (!mutation && laneState.mutation) ||
        (mutation && impl->activeMutations != 0U)) {
        admission.code = MoonlightHostControlCode::Busy;
        return admission;
    }

    const auto previousOwnerToken = laneState.generationOwnerToken;
    const auto previousWatermark = laneState.generationWatermark;
    if (laneState.generationOwnerToken != context.key.ownerToken) {
        // Generations are monotonic within an ArkTS owner, not process-global.
        // A newly admitted owner starts its own watermark after the prior
        // owner has fully drained this host lane.
        laneState.generationOwnerToken = context.key.ownerToken;
        laneState.generationWatermark = 0U;
    }
    laneState.generationWatermark =
        std::max(laneState.generationWatermark, context.key.generation);
    if (mutation) {
        laneState.mutation = true;
        ++impl->activeMutations;
        if (!impl->activeMutationOwner.has_value()) {
            impl->activeMutationOwner = context.key.ownerToken;
        }
    } else {
        ++laneState.readers;
    }
    try {
        impl->active.emplace(context.key, active);
    } catch (...) {
        laneState.generationOwnerToken = previousOwnerToken;
        laneState.generationWatermark = previousWatermark;
        if (mutation) {
            laneState.mutation = false;
            --impl->activeMutations;
            if (impl->activeMutations == 0U) {
                impl->activeMutationOwner.reset();
            }
        } else {
            --laneState.readers;
        }
        throw;
    }
    admission.code = MoonlightHostControlCode::Ok;
    admission.active = std::move(active);
    return admission;
}

bool generationStale(const std::shared_ptr<MoonlightHostControl::Impl>& impl,
                     const std::shared_ptr<ActiveControl>& active) noexcept {
    try {
        std::lock_guard<std::mutex> lock(impl->mutex);
        const auto iterator = impl->lanes.find(active->lane);
        return iterator == impl->lanes.end() ||
               iterator->second.generationOwnerToken != active->key.ownerToken ||
               iterator->second.generationWatermark > active->key.generation;
    } catch (...) {
        return true;
    }
}

std::optional<MoonlightHostControlCode> stopped(
    const std::shared_ptr<MoonlightHostControl::Impl>& impl,
    const std::shared_ptr<ActiveControl>& active,
    std::chrono::steady_clock::time_point deadline) noexcept {
    if (active->cancelled.load(std::memory_order_acquire)) {
        return MoonlightHostControlCode::Cancelled;
    }
    if (generationStale(impl, active)) {
        return MoonlightHostControlCode::Stale;
    }
    if (!active->network.available ||
        remotedesk::net::ProcessNetworkGenerationFence().shouldCancel(
            active->network)) {
        return MoonlightHostControlCode::Stale;
    }
    try {
        if (impl->monotonicClock() >= deadline) {
            return MoonlightHostControlCode::DeadlineExceeded;
        }
    } catch (...) {
        return MoonlightHostControlCode::Unavailable;
    }
    return std::nullopt;
}

std::chrono::milliseconds remainingTimeout(
    const std::shared_ptr<MoonlightHostControl::Impl>& impl,
    std::chrono::steady_clock::time_point deadline) noexcept {
    try {
        const auto now = impl->monotonicClock();
        if (now >= deadline) {
            return std::chrono::milliseconds(0);
        }
        return std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
    } catch (...) {
        return std::chrono::milliseconds(0);
    }
}

MoonlightHostResult executeHostCall(
    const std::shared_ptr<MoonlightHostControl::Impl>& impl,
    const std::shared_ptr<ActiveControl>& active,
    const MoonlightHostControlContext& context,
    std::chrono::steady_clock::time_point deadline, MoonlightHostCall& call) {
    call.key = hostKey(context.key);
    call.endpoint = context.endpoint;
    call.expectedNetworkGeneration = active->network.generation;
    if (const auto stop = stopped(impl, active, deadline); stop.has_value()) {
        MoonlightHostResult result;
        result.key = call.key;
        result.error = *stop == MoonlightHostControlCode::Cancelled
                           ? MoonlightHostError::Cancelled
                       : *stop == MoonlightHostControlCode::Stale
                           ? MoonlightHostError::StaleRequest
                           : MoonlightHostError::DeadlineExceeded;
        return result;
    }
    const auto remaining = remainingTimeout(impl, deadline);
    if (remaining < MoonlightHostLimits::kMinTimeout) {
        MoonlightHostResult result;
        result.key = call.key;
        result.error = MoonlightHostError::DeadlineExceeded;
        return result;
    }
    call.timeout = remaining;
    return impl->hostApi->execute(call);
}

MoonlightHostControlCode authorize(
    const std::shared_ptr<MoonlightHostControl::Impl>& impl,
    const std::shared_ptr<ActiveControl>& active,
    const MoonlightHostControlContext& context,
    std::chrono::steady_clock::time_point deadline) {
    if (impl->accessPort == nullptr || !impl->accessPort->available()) {
        return MoonlightHostControlCode::Unavailable;
    }
    if (const auto stop = stopped(impl, active, deadline); stop.has_value()) {
        return *stop;
    }
    const auto accessCode = impl->accessPort->authorize(
        context, deadline, [impl, active, deadline]() {
            return stopped(impl, active, deadline).has_value();
        });
    if (const auto stop = stopped(impl, active, deadline); stop.has_value()) {
        return *stop;
    }
    switch (accessCode) {
    case MoonlightHostControlAccessCode::Ready:
        return MoonlightHostControlCode::Ok;
    case MoonlightHostControlAccessCode::Cancelled:
        return MoonlightHostControlCode::Cancelled;
    case MoonlightHostControlAccessCode::Stale:
        return MoonlightHostControlCode::Stale;
    case MoonlightHostControlAccessCode::DeadlineExceeded:
        return MoonlightHostControlCode::DeadlineExceeded;
    case MoonlightHostControlAccessCode::Unavailable:
    default:
        return MoonlightHostControlCode::Unavailable;
    }
}

bool appPresent(const std::shared_ptr<MoonlightHostControl::Impl>& impl,
                const std::shared_ptr<ActiveControl>& active,
                const MoonlightHostControlContext& context, std::uint32_t appId,
                std::uint64_t catalogGeneration) {
    std::lock_guard<std::mutex> lock(impl->mutex);
    const auto iterator = impl->lanes.find(active->lane);
    if (iterator == impl->lanes.end() || !iterator->second.catalog.has_value()) {
        return false;
    }
    const auto& catalog = *iterator->second.catalog;
    return catalog.ownerToken == context.key.ownerToken &&
           catalog.generation == catalogGeneration &&
           catalogGeneration == context.key.generation &&
           catalog.serverUuid == context.serverUuid &&
           catalog.appIds.find(appId) != catalog.appIds.end();
}

} // namespace

MoonlightLaunchMaterial::MoonlightLaunchMaterial(
    std::vector<std::uint8_t> riKey, std::int32_t riKeyId,
    MoonlightLaunchConfiguration configuration) noexcept
    : riKey_(std::move(riKey)), riKeyId_(riKeyId), configuration_(configuration) {}

MoonlightLaunchMaterial::~MoonlightLaunchMaterial() { secureWipeBytes(riKey_); }

MoonlightLaunchMaterial::MoonlightLaunchMaterial(MoonlightLaunchMaterial&& other) noexcept
    : riKey_(std::move(other.riKey_)), riKeyId_(other.riKeyId_),
      configuration_(other.configuration_) {
    other.riKeyId_ = 0;
    other.configuration_ = {};
}

MoonlightLaunchMaterial& MoonlightLaunchMaterial::operator=(
    MoonlightLaunchMaterial&& other) noexcept {
    if (this != &other) {
        secureWipeBytes(riKey_);
        riKey_ = std::move(other.riKey_);
        riKeyId_ = other.riKeyId_;
        configuration_ = other.configuration_;
        other.riKeyId_ = 0;
        other.configuration_ = {};
    }
    return *this;
}

bool MoonlightLaunchMaterial::valid() const noexcept {
    return riKey_.size() == kRiKeyBytes && configuration_.width >= 320U &&
           configuration_.width <= 16384U && configuration_.height >= 200U &&
           configuration_.height <= 16384U && configuration_.refreshRate <= 1000U;
}

MoonlightHostControlResult::~MoonlightHostControlResult() {
    secureWipeOptionalString(rtspSessionUrl);
}

MoonlightHostControlResult::MoonlightHostControlResult(
    MoonlightHostControlResult&& other) noexcept
    : code(other.code), terminalStage(other.terminalStage),
      preflightTruth(other.preflightTruth), actionTruth(other.actionTruth),
      postconditionTruth(other.postconditionTruth), lastHostError(other.lastHostError),
      lastHttpStatus(other.lastHttpStatus), lastXmlStatus(other.lastXmlStatus),
      transportAttempts(other.transportAttempts), partialAppCount(other.partialAppCount),
      generation(other.generation), observedAtMs(other.observedAtMs),
      idempotent(other.idempotent), mutationMayHaveBeenSent(other.mutationMayHaveBeenSent),
      apps(std::move(other.apps)), asset(std::move(other.asset)),
      rtspSessionUrl(std::move(other.rtspSessionUrl)),
      sessionAddress(std::move(other.sessionAddress)),
      sessionNetworkGeneration(other.sessionNetworkGeneration),
      sessionServerInfo(std::move(other.sessionServerInfo)),
      effectiveLaunchConfiguration(std::move(other.effectiveLaunchConfiguration)),
      stageTrace(std::move(other.stageTrace)),
      diagnostics(std::move(other.diagnostics)) {
    secureWipeOptionalString(other.rtspSessionUrl);
}

MoonlightHostControlResult& MoonlightHostControlResult::operator=(
    MoonlightHostControlResult&& other) noexcept {
    if (this != &other) {
        secureWipeOptionalString(rtspSessionUrl);
        code = other.code;
        terminalStage = other.terminalStage;
        preflightTruth = other.preflightTruth;
        actionTruth = other.actionTruth;
        postconditionTruth = other.postconditionTruth;
        lastHostError = other.lastHostError;
        lastHttpStatus = other.lastHttpStatus;
        lastXmlStatus = other.lastXmlStatus;
        transportAttempts = other.transportAttempts;
        partialAppCount = other.partialAppCount;
        generation = other.generation;
        observedAtMs = other.observedAtMs;
        idempotent = other.idempotent;
        mutationMayHaveBeenSent = other.mutationMayHaveBeenSent;
        apps = std::move(other.apps);
        asset = std::move(other.asset);
        rtspSessionUrl = std::move(other.rtspSessionUrl);
        sessionAddress = std::move(other.sessionAddress);
        sessionNetworkGeneration = other.sessionNetworkGeneration;
        sessionServerInfo = std::move(other.sessionServerInfo);
        effectiveLaunchConfiguration = std::move(other.effectiveLaunchConfiguration);
        stageTrace = std::move(other.stageTrace);
        diagnostics = std::move(other.diagnostics);
        secureWipeOptionalString(other.rtspSessionUrl);
    }
    return *this;
}

MoonlightHostControl::MoonlightHostControl(
    std::shared_ptr<MoonlightHostApi> hostApi,
    std::shared_ptr<MoonlightHostControlAccessPort> accessPort,
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
    impl_ = std::make_shared<Impl>(std::move(hostApi), std::move(accessPort),
                                   std::move(monotonicClock), std::move(wallClock));
}

MoonlightHostControl::~MoonlightHostControl() {
    const auto impl = std::atomic_exchange_explicit(
        &impl_, std::shared_ptr<Impl> {}, std::memory_order_acq_rel);
    if (impl == nullptr) {
        return;
    }
    std::vector<MoonlightHostControlOperationKey> keys;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        impl->shuttingDown = true;
        keys.reserve(impl->active.size());
        for (const auto& item : impl->active) {
            item.second->cancelled.store(true, std::memory_order_release);
            keys.push_back(item.first);
        }
    }
    for (const auto& key : keys) {
        if (impl->hostApi != nullptr) {
            impl->hostApi->cancel(hostKey(key));
        }
        if (impl->accessPort != nullptr) {
            impl->accessPort->cancel(key);
        }
    }
    std::unique_lock<std::mutex> lock(impl->mutex);
    impl->cv.wait(lock, [&]() { return impl->active.empty(); });
}

MoonlightHostControlResult MoonlightHostControl::catalog(
    MoonlightCatalogRequest request) noexcept {
    MoonlightHostControlResult result;
    result.generation = request.context.key.generation;
    transition(result, MoonlightHostControlStage::Preflight);
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (!contextShapeValid(request.context)) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        if (impl == nullptr || impl->hostApi == nullptr) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::Unavailable);
        }
        MoonlightHostCall validation;
        validation.key = hostKey(request.context.key);
        validation.operation = MoonlightHostOperation::AppList;
        validation.endpoint = request.context.endpoint;
        validation.timeout = request.context.timeout;
        if (impl->hostApi->validate(validation) != MoonlightHostError::None) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        const auto admission = admit(impl, request.context, false);
        if (admission.code != MoonlightHostControlCode::Ok) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), admission.code);
        }
        ActiveLease lease(impl, admission.active);
        const auto deadline = impl->monotonicClock() + request.context.timeout;
        transition(result, MoonlightHostControlStage::Authorizing);
        const auto accessCode = authorize(impl, admission.active, request.context, deadline);
        if (accessCode != MoonlightHostControlCode::Ok) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), accessCode);
        }
        result.preflightTruth = MoonlightHostControlTruth::Confirmed;
        transition(result, MoonlightHostControlStage::ReadingCatalog);
        MoonlightHostCall call;
        call.operation = MoonlightHostOperation::AppList;
        auto hostResult = executeHostCall(impl, admission.active, request.context, deadline,
                                          call);
        observeHostResult(result, MoonlightHostControlOperation::Catalog,
                          MoonlightHostControlStage::ReadingCatalog, hostResult);
        if (!hostResult.ok()) {
            if (hostResult.error == MoonlightHostError::DuplicateApp) {
                return finish(std::move(result), MoonlightHostControlCode::InvalidCatalog);
            }
            return finish(std::move(result), mapHostFailure(hostResult, false));
        }
        result.partialAppCount = hostResult.partialAppCount;
        if (hostResult.partialAppCount != 0U) {
            result.apps.clear();
            return finish(std::move(result), MoonlightHostControlCode::InvalidCatalog);
        }
        if (const auto stop = stopped(impl, admission.active, deadline); stop.has_value()) {
            return finish(std::move(result), *stop);
        }
        CatalogSnapshot snapshot;
        snapshot.ownerToken = request.context.key.ownerToken;
        snapshot.generation = request.context.key.generation;
        snapshot.serverUuid = request.context.serverUuid;
        for (const auto& app : hostResult.apps) {
            if (app.id == 0U || app.title.empty() || !snapshot.appIds.insert(app.id).second) {
                result.apps.clear();
                return finish(std::move(result), MoonlightHostControlCode::InvalidCatalog);
            }
        }
        const auto observedAtMs = impl->wallClock();
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            auto& lane = impl->lanes[admission.active->lane];
            if (lane.generationOwnerToken != request.context.key.ownerToken ||
                lane.generationWatermark != request.context.key.generation) {
                return finish(std::move(result), MoonlightHostControlCode::Stale);
            }
            lane.catalog = std::move(snapshot);
        }
        result.apps = std::move(hostResult.apps);
        result.observedAtMs = observedAtMs;
        return finish(std::move(result), MoonlightHostControlCode::Ok);
    } catch (...) {
        result.preflightTruth = result.preflightTruth == MoonlightHostControlTruth::NotAttempted
                                    ? MoonlightHostControlTruth::Failed
                                    : result.preflightTruth;
        return finish(std::move(result), MoonlightHostControlCode::ProtocolFailure);
    }
}

MoonlightHostControlResult MoonlightHostControl::asset(MoonlightAssetRequest request) noexcept {
    MoonlightHostControlResult result;
    result.generation = request.context.key.generation;
    transition(result, MoonlightHostControlStage::Preflight);
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (!contextShapeValid(request.context) || request.appId == 0U ||
            request.catalogGeneration == 0U) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        if (impl == nullptr || impl->hostApi == nullptr) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::Unavailable);
        }
        MoonlightHostCall validation;
        validation.key = hostKey(request.context.key);
        validation.operation = MoonlightHostOperation::AppAsset;
        validation.endpoint = request.context.endpoint;
        validation.timeout = request.context.timeout;
        validation.query = {{"appid", std::to_string(request.appId)}};
        QueryWiper validationWiper(validation);
        if (impl->hostApi->validate(validation) != MoonlightHostError::None) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        const auto admission = admit(impl, request.context, false);
        if (admission.code != MoonlightHostControlCode::Ok) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), admission.code);
        }
        ActiveLease lease(impl, admission.active);
        const auto deadline = impl->monotonicClock() + request.context.timeout;
        transition(result, MoonlightHostControlStage::Authorizing);
        const auto accessCode = authorize(impl, admission.active, request.context, deadline);
        if (accessCode != MoonlightHostControlCode::Ok) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), accessCode);
        }
        if (!appPresent(impl, admission.active, request.context, request.appId,
                        request.catalogGeneration)) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), request.catalogGeneration == request.context.key.generation
                                                 ? MoonlightHostControlCode::AppNotFound
                                                 : MoonlightHostControlCode::Stale);
        }
        result.preflightTruth = MoonlightHostControlTruth::Confirmed;
        transition(result, MoonlightHostControlStage::ReadingAsset);
        MoonlightHostCall call;
        call.operation = MoonlightHostOperation::AppAsset;
        call.query = {{"appid", std::to_string(request.appId)}};
        QueryWiper callWiper(call);
        auto hostResult = executeHostCall(impl, admission.active, request.context, deadline,
                                          call);
        observeHostResult(result, MoonlightHostControlOperation::Asset,
                          MoonlightHostControlStage::ReadingAsset, hostResult, request.appId);
        if (!hostResult.ok()) {
            return finish(std::move(result), mapHostFailure(hostResult, false));
        }
        if (const auto stop = stopped(impl, admission.active, deadline); stop.has_value()) {
            return finish(std::move(result), *stop);
        }
        if (!appPresent(impl, admission.active, request.context, request.appId,
                        request.catalogGeneration)) {
            return finish(std::move(result), MoonlightHostControlCode::Stale);
        }
        result.asset = std::move(hostResult.asset);
        result.observedAtMs = impl->wallClock();
        return finish(std::move(result), MoonlightHostControlCode::Ok);
    } catch (...) {
        return finish(std::move(result), MoonlightHostControlCode::ProtocolFailure);
    }
}

MoonlightHostControlResult MoonlightHostControl::launch(MoonlightLaunchRequest request) noexcept {
    return runLaunch(MoonlightHostControlOperation::Launch, std::move(request));
}

MoonlightHostControlResult MoonlightHostControl::resume(MoonlightLaunchRequest request) noexcept {
    return runLaunch(MoonlightHostControlOperation::Resume, std::move(request));
}

MoonlightHostControlResult MoonlightHostControl::runLaunch(
    MoonlightHostControlOperation operation, MoonlightLaunchRequest request) noexcept {
    MoonlightHostControlResult result;
    result.generation = request.context.key.generation;
    transition(result, MoonlightHostControlStage::Preflight);
    try {
        const bool isLaunch = operation == MoonlightHostControlOperation::Launch;
        if (!isLaunch && operation != MoonlightHostControlOperation::Resume) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (!contextShapeValid(request.context) || request.appId == 0U ||
            !request.material.valid()) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        if (impl == nullptr || impl->hostApi == nullptr) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::Unavailable);
        }
        MoonlightHostCall validation;
        validation.key = hostKey(request.context.key);
        validation.operation = isLaunch ? MoonlightHostOperation::Launch
                                        : MoonlightHostOperation::Resume;
        validation.endpoint = request.context.endpoint;
        validation.timeout = request.context.timeout;
        validation.query = dummyLaunchQuery(request.appId);
        QueryWiper validationWiper(validation);
        if (impl->hostApi->validate(validation) != MoonlightHostError::None) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        const auto admission = admit(impl, request.context, true);
        if (admission.code != MoonlightHostControlCode::Ok) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), admission.code);
        }
        ActiveLease lease(impl, admission.active);
        const auto deadline = impl->monotonicClock() + request.context.timeout;
        transition(result, MoonlightHostControlStage::Authorizing);
        const auto accessCode = authorize(impl, admission.active, request.context, deadline);
        if (accessCode != MoonlightHostControlCode::Ok) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), accessCode);
        }
        if (!appPresent(impl, admission.active, request.context, request.appId,
                        request.context.key.generation)) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::AppNotFound);
        }

        transition(result, MoonlightHostControlStage::ReadingHostState);
        MoonlightHostCall preconditionCall;
        preconditionCall.operation = MoonlightHostOperation::ServerInfo;
        auto precondition = executeHostCall(impl, admission.active, request.context, deadline,
                                            preconditionCall);
        observeHostResult(result, operation, MoonlightHostControlStage::ReadingHostState,
                          precondition, request.appId);
        if (!precondition.ok() || !precondition.serverInfo.has_value()) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), mapHostFailure(precondition, false));
        }
        if (precondition.candidateOnly || !precondition.serverInfo->paired) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::Unpaired);
        }
        if (precondition.serverInfo->uniqueId != request.context.serverUuid) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::Stale);
        }
        if (!adaptLaunchVideoMode(request.material.configuration_,
                                  *precondition.serverInfo)) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result),
                          MoonlightHostControlCode::ActionRejected);
        }
        const auto currentGame = precondition.serverInfo->currentGame;
        result.preflightTruth = MoonlightHostControlTruth::Confirmed;
        if (isLaunch && currentGame == request.appId) {
            return finish(std::move(result), MoonlightHostControlCode::ResumeRequired);
        }
        if ((isLaunch && currentGame != 0U) ||
            (!isLaunch && currentGame != request.appId && currentGame != 0U)) {
            return finish(std::move(result), MoonlightHostControlCode::HostBusy);
        }
        if (!isLaunch && currentGame == 0U) {
            return finish(std::move(result), MoonlightHostControlCode::ActionRejected);
        }

        auto makeQuery = [&]() {
            constexpr char hex[] = "0123456789ABCDEF";
            std::string riKeyHex(request.material.riKey_.size() * 2U, '0');
            StringWiper riKeyHexWiper(riKeyHex);
            for (std::size_t index = 0; index < request.material.riKey_.size(); ++index) {
                riKeyHex[index * 2U] = hex[request.material.riKey_[index] >> 4U];
                riKeyHex[index * 2U + 1U] = hex[request.material.riKey_[index] & 0x0fU];
            }
            const auto& config = request.material.configuration_;
            std::vector<MoonlightHostQueryParameter> query {
                {"appid", std::to_string(request.appId)},
                {"mode", std::to_string(config.width) + "x" + std::to_string(config.height) +
                             "x" + std::to_string(config.refreshRate)},
                {"additionalStates", config.additionalStates ? "1" : "0"},
                {"sops", config.sops ? "1" : "0"},
                {"rikey", riKeyHex},
                {"rikeyid", std::to_string(request.material.riKeyId_)},
                {"localAudioPlayMode", config.playAudioOnHost ? "1" : "0"},
                {"surroundAudioInfo", std::to_string(config.surroundAudioInfo)},
                {"remoteControllersBitmap", std::to_string(config.remoteControllersBitmap)},
                {"gcmap", std::to_string(config.gamepadMask)},
                {"gcpersist", config.persistGamepads ? "1" : "0"},
            };
            if (config.hdr) {
                query.push_back({"hdrMode", "1"});
                query.push_back({"clientHdrCapVersion", "0"});
                query.push_back({"clientHdrCapSupportedFlagsInUint32", "0"});
                query.push_back({"clientHdrCapMetaDataId", "NV_STATIC_METADATA_TYPE_1"});
                query.push_back({"clientHdrCapDisplayData", "0x0x0x0x0x0x0x0x0x0x0"});
            }
            return query;
        };

        transition(result, MoonlightHostControlStage::DispatchingAction);
        MoonlightHostCall actionCall;
        actionCall.operation = isLaunch ? MoonlightHostOperation::Launch
                                        : MoonlightHostOperation::Resume;
        actionCall.query = makeQuery();
        QueryWiper actionWiper(actionCall);
        auto action = executeHostCall(impl, admission.active, request.context, deadline,
                                      actionCall);
        HostResultTransientWiper actionWiperResult(action);
        secureWipeBytes(request.material.riKey_);
        observeHostResult(result, operation, MoonlightHostControlStage::DispatchingAction,
                          action, request.appId);
        result.mutationMayHaveBeenSent = possiblySent(action);
        if (!action.ok()) {
            const auto code = mapHostFailure(action, true);
            result.actionTruth = code == MoonlightHostControlCode::OutcomeUnknown
                                     ? MoonlightHostControlTruth::Unknown
                                     : MoonlightHostControlTruth::Failed;
            return finish(std::move(result), code);
        }
        if (!action.action.has_value() || !action.action->accepted) {
            result.actionTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::ActionRejected);
        }
        result.actionTruth = MoonlightHostControlTruth::Confirmed;
        if (!action.action->rtspSessionUrl.has_value() ||
            action.action->rtspSessionUrl->empty()) {
            result.postconditionTruth = MoonlightHostControlTruth::Unknown;
            return finish(std::move(result), MoonlightHostControlCode::OutcomeUnknown);
        }
        result.rtspSessionUrl = std::move(action.action->rtspSessionUrl);
        result.sessionAddress = std::move(action.resolvedAddress);
        result.sessionNetworkGeneration = action.networkGeneration;
        if (!result.sessionAddress.has_value() || result.sessionAddress->empty() ||
            result.sessionNetworkGeneration == 0U ||
            result.sessionNetworkGeneration != admission.active->network.generation) {
            result.postconditionTruth = MoonlightHostControlTruth::Unknown;
            secureWipeOptionalString(result.rtspSessionUrl);
            return finish(std::move(result), MoonlightHostControlCode::OutcomeUnknown);
        }

        // Do not issue a second /serverinfo before RTSP starts. Sunshine keeps
        // the launch event pending until the RTSP client connects and may
        // block that request until its ping timeout, creating a client/server
        // deadlock. The pre-launch serverinfo was authenticated and proved the
        // exact paired host was idle; the accepted launch response supplies the
        // mutation receipt and RTSP URL. Carry that snapshot into common-c and
        // leave the postcondition truth explicit rather than claiming a check
        // that cannot safely run at this point in the protocol.
        result.postconditionTruth = MoonlightHostControlTruth::Unknown;
        MoonlightServerInfo launchSnapshot = *precondition.serverInfo;
        launchSnapshot.currentGame = request.appId;
        result.sessionServerInfo = std::move(launchSnapshot);
        result.effectiveLaunchConfiguration =
            request.material.configuration_;
        result.observedAtMs = impl->wallClock();
        return finish(std::move(result), MoonlightHostControlCode::Ok);
    } catch (...) {
        secureWipeOptionalString(result.rtspSessionUrl);
        return finish(std::move(result), result.mutationMayHaveBeenSent
                                             ? MoonlightHostControlCode::OutcomeUnknown
                                             : MoonlightHostControlCode::ProtocolFailure);
    }
}

MoonlightHostControlResult MoonlightHostControl::quit(MoonlightQuitRequest request) noexcept {
    MoonlightHostControlResult result;
    result.generation = request.context.key.generation;
    transition(result, MoonlightHostControlStage::Preflight);
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (!contextShapeValid(request.context)) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        if (impl == nullptr || impl->hostApi == nullptr) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::Unavailable);
        }
        MoonlightHostCall validation;
        validation.key = hostKey(request.context.key);
        validation.operation = MoonlightHostOperation::Cancel;
        validation.endpoint = request.context.endpoint;
        validation.timeout = request.context.timeout;
        if (impl->hostApi->validate(validation) != MoonlightHostError::None) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::InvalidArgument);
        }
        const auto admission = admit(impl, request.context, true);
        if (admission.code != MoonlightHostControlCode::Ok) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), admission.code);
        }
        ActiveLease lease(impl, admission.active);
        const auto deadline = impl->monotonicClock() + request.context.timeout;
        transition(result, MoonlightHostControlStage::Authorizing);
        const auto accessCode = authorize(impl, admission.active, request.context, deadline);
        if (accessCode != MoonlightHostControlCode::Ok) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), accessCode);
        }
        transition(result, MoonlightHostControlStage::ReadingHostState);
        MoonlightHostCall preconditionCall;
        preconditionCall.operation = MoonlightHostOperation::ServerInfo;
        auto precondition = executeHostCall(impl, admission.active, request.context, deadline,
                                            preconditionCall);
        observeHostResult(result, MoonlightHostControlOperation::Quit,
                          MoonlightHostControlStage::ReadingHostState, precondition,
                          request.expectedCurrentAppId);
        if (!precondition.ok() || !precondition.serverInfo.has_value()) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), mapHostFailure(precondition, false));
        }
        if (precondition.candidateOnly || !precondition.serverInfo->paired) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::Unpaired);
        }
        if (precondition.serverInfo->uniqueId != request.context.serverUuid) {
            result.preflightTruth = MoonlightHostControlTruth::Failed;
            return finish(std::move(result), MoonlightHostControlCode::Stale);
        }
        result.preflightTruth = MoonlightHostControlTruth::Confirmed;
        const auto currentGame = precondition.serverInfo->currentGame;
        if (currentGame == 0U) {
            result.idempotent = true;
            result.postconditionTruth = MoonlightHostControlTruth::Confirmed;
            result.observedAtMs = impl->wallClock();
            return finish(std::move(result), MoonlightHostControlCode::Ok);
        }
        if (request.expectedCurrentAppId != 0U &&
            request.expectedCurrentAppId != currentGame) {
            return finish(std::move(result), MoonlightHostControlCode::Stale);
        }
        if (!request.userConfirmedTermination) {
            return finish(std::move(result), MoonlightHostControlCode::ConfirmationRequired);
        }

        transition(result, MoonlightHostControlStage::DispatchingAction);
        MoonlightHostCall cancelCall;
        cancelCall.operation = MoonlightHostOperation::Cancel;
        auto action = executeHostCall(impl, admission.active, request.context, deadline,
                                      cancelCall);
        observeHostResult(result, MoonlightHostControlOperation::Quit,
                          MoonlightHostControlStage::DispatchingAction, action, currentGame);
        result.mutationMayHaveBeenSent = possiblySent(action);
        if (!action.ok() || !action.action.has_value() || !action.action->accepted) {
            const auto code = action.ok() ? MoonlightHostControlCode::ActionRejected
                                          : mapHostFailure(action, true);
            result.actionTruth = code == MoonlightHostControlCode::OutcomeUnknown
                                     ? MoonlightHostControlTruth::Unknown
                                     : MoonlightHostControlTruth::Failed;
            result.postconditionTruth = code == MoonlightHostControlCode::OutcomeUnknown
                                            ? MoonlightHostControlTruth::Unknown
                                            : MoonlightHostControlTruth::Failed;
            return finish(std::move(result), code);
        }
        result.actionTruth = MoonlightHostControlTruth::Confirmed;
        result.postconditionTruth = MoonlightHostControlTruth::Confirmed;
        result.observedAtMs = impl->wallClock();
        return finish(std::move(result), MoonlightHostControlCode::Ok);
    } catch (...) {
        return finish(std::move(result), result.mutationMayHaveBeenSent
                                             ? MoonlightHostControlCode::OutcomeUnknown
                                             : MoonlightHostControlCode::ProtocolFailure);
    }
}

bool MoonlightHostControl::cancel(const MoonlightHostControlOperationKey& key) noexcept {
    if (!key.valid()) {
        return false;
    }
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            return false;
        }
        std::shared_ptr<ActiveControl> active;
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            const auto iterator = impl->active.find(key);
            if (iterator == impl->active.end()) {
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
        if (impl->accessPort != nullptr) {
            impl->accessPort->cancel(key);
        }
        return true;
    } catch (...) {
        return false;
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::uint64_t MoonlightHostControl::secureCleanseCountForTesting() noexcept {
    return gControlCleanseCount.load(std::memory_order_relaxed);
}

void MoonlightHostControl::resetSecureCleanseCountForTesting() noexcept {
    gControlCleanseCount.store(0U, std::memory_order_relaxed);
}
#endif

} // namespace remotedesk::moonlight
