#include "moonlight/runtime/MoonlightProductStreamingRuntime.h"

#include "moonlight/media/MoonlightProductSessionMediaPort.h"
#include "moonlight/media/MoonlightStreamConfig.h"
#include "moonlight/input/MoonlightProductInputRuntime.h"

#include <algorithm>
#include <chrono>
#include <mutex>
#include <optional>
#include <utility>

namespace remotedesk::moonlight {
namespace {

std::uint64_t monotonicMs() noexcept {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<
        std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

bool sameLaunchKey(const MoonlightBridgeRequestKey& left,
                   const MoonlightBridgeRequestKey& right) noexcept {
    return left == right;
}

constexpr std::uint64_t kServerCodecH264 = 0x00000001U;
constexpr std::uint32_t kMinimumWidth = 320U;
constexpr std::uint32_t kMaximumWidth = 7680U;
constexpr std::uint32_t kMinimumHeight = 240U;
constexpr std::uint32_t kMaximumHeight = 4320U;
constexpr std::uint32_t kMinimumFps = 30U;
constexpr std::uint32_t kMaximumFps = 240U;
constexpr std::int32_t kMinimumBitrateKbps = 1000;
constexpr std::int32_t kMaximumBitrateKbps = 200000;

std::optional<MoonlightStreamConfigResult> conservativeOffer(
    const MoonlightProductLaunchStage& stage,
    const MoonlightProductStreamStartRequest& request) noexcept {
    const auto width = stage.configuration.width;
    const auto height = stage.configuration.height;
    const auto fps = stage.configuration.refreshRate;
    const auto pixels = static_cast<std::uint64_t>(width) * height;
    if (width < kMinimumWidth || width > kMaximumWidth ||
        height < kMinimumHeight || height > kMaximumHeight ||
        (width % 2U) != 0U || (height % 2U) != 0U ||
        fps < kMinimumFps || fps > kMaximumFps ||
        request.configuredBitrateKbps < kMinimumBitrateKbps ||
        request.configuredBitrateKbps > kMaximumBitrateKbps ||
        !moonlightProductStreamingPolicyAllows(
            request.latencyMode, request.encryptionPolicy) ||
        request.codec != MoonlightStreamCodec::H264 || request.hdr || request.yuv444 ||
        !moonlightProductAudioContractAllows(
            request.audioEnabled, request.audioLayout,
            stage.configuration.surroundAudioInfo) ||
        stage.configuration.hdr != request.hdr ||
        stage.configuration.playAudioOnHost != request.playAudioOnHost ||
        !stage.serverInfo.paired ||
        stage.serverInfo.currentGame != stage.appId ||
        stage.serverInfo.uniqueId != stage.serverUuid ||
        !stage.serverInfo.codecModeSupport.has_value() ||
        ((*stage.serverInfo.codecModeSupport & kServerCodecH264) == 0U) ||
        (stage.serverInfo.maxLumaPixelsH264.has_value() &&
         pixels > *stage.serverInfo.maxLumaPixelsH264)) {
        return std::nullopt;
    }

    try {
        MoonlightStreamConfigResult result;
        result.status = MoonlightStreamResultStatus::OfferReady;
        result.code = MoonlightStreamResultCode::None;
        result.identity.ownerToken = stage.key.ownerToken;
        result.identity.sessionGeneration = stage.key.generation;
        result.identity.hostId = stage.hostId;
        result.identity.serverUuid = stage.serverUuid;
        result.identity.settingsRevision = stage.key.generation;
        result.identity.hostCapabilityGeneration = stage.key.generation;
        // These remain zero until the admitted owner binds real media. Network
        // path classification is likewise deferred to common-c after address
        // resolution rather than inferred from address spelling.
        result.identity.platformProbeGeneration = 0U;
        result.identity.networkCapabilityGeneration = 0U;
        result.identity.displayCapabilityGeneration = 0U;

        MoonlightEffectiveStreamOffer offer;
        offer.dimensions = {static_cast<std::int32_t>(width),
                            static_cast<std::int32_t>(height)};
        offer.fps = static_cast<std::int32_t>(fps);
        offer.launchRefreshRate = offer.fps;
        offer.clientRefreshRateX100 = 0;
        offer.configuredBitrateKbps = request.configuredBitrateKbps;
        offer.estimatedEncoderBitrateKbps =
            request.configuredBitrateKbps * 4 / 5;
        // Limelight.h explicitly prescribes 1024 when path MTU is unknown.
        offer.packetSizeBytes = 1024;
        offer.networkPath = MoonlightStreamNetworkPath::Unknown;
        offer.latencyMode = request.latencyMode;
        offer.offeredCodecs = {{MoonlightStreamCodec::H264,
            MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420,
            true, true, true}};
        offer.hdr = false;
        offer.yuv444 = false;
        offer.colorSpace = MoonlightStreamColorSpace::Rec709;
        offer.colorRange = MoonlightStreamColorRange::Limited;
        offer.audioLayout = request.audioEnabled ? request.audioLayout :
            MoonlightStreamAudioLayout::Disabled;
        offer.playAudioOnHost = request.playAudioOnHost;
        offer.highQualityAudioCandidate = false;
        offer.encryptionPolicy = request.encryptionPolicy;
        offer.requiredEncryptionStreams = MoonlightStreamEncryptNone;
        offer.candidateEncryptionStreams = request.encryptionPolicy ==
                MoonlightStreamEncryptionPolicy::Compatible ?
            MoonlightStreamEncryptNone :
            MoonlightStreamEncryptAudio | MoonlightStreamEncryptVideo;
        offer.remoteInputEncryptionRequired = true;
        result.offer = offer;

        MoonlightLaunchProjection launch;
        launch.dimensions = offer.dimensions;
        launch.fps = offer.fps;
        launch.hdr = false;
        launch.audioLayout = offer.audioLayout;
        launch.playAudioOnHost = offer.playAudioOnHost;
        result.launchProjection = launch;
        return result;
    } catch (...) {
        return std::nullopt;
    }
}

const char* startCode(MoonlightCommonCStartStatus status) noexcept {
    switch (status) {
        case MoonlightCommonCStartStatus::Accepted: return "accepted";
        case MoonlightCommonCStartStatus::Busy: return "busy";
        case MoonlightCommonCStartStatus::RuntimeProofRequired: return "runtime_proof_required";
        case MoonlightCommonCStartStatus::InvalidRequest: return "invalid_request";
        case MoonlightCommonCStartStatus::InternalFailure: return "internal_failure";
    }
    return "internal_failure";
}

const char* snapshotCode(const MoonlightCommonCSnapshot& source,
                         bool inputActivationFailed) noexcept {
    if (inputActivationFailed) {
        return "input_failed";
    }
    if (!source.terminal) {
        return source.firstFrameReady ? "first_frame" :
            source.transportReady ? "transport_ready" : "starting";
    }
    switch (source.terminalCode) {
        case MoonlightCommonCCode::Cancelled: return "cancelled";
        case MoonlightCommonCCode::DeadlineExceeded: return "deadline_exceeded";
        case MoonlightCommonCCode::VideoNegotiationRejected:
            return "codec_unsupported";
        case MoonlightCommonCCode::AudioNegotiationRejected: return "audio_failed";
        case MoonlightCommonCCode::MediaPortRejected: return "decoder_failed";
        case MoonlightCommonCCode::StaleOwner: return "stale_owner";
        case MoonlightCommonCCode::ConnectionTerminated:
            return "connection_terminated";
        case MoonlightCommonCCode::CommonCStartFailed: return "connection_failed";
        case MoonlightCommonCCode::StageFailed: return "stage_failed";
        case MoonlightCommonCCode::ProtocolViolation: return "protocol_violation";
        case MoonlightCommonCCode::RuntimeProofRequired:
            return "runtime_proof_required";
        case MoonlightCommonCCode::InvalidRequest: return "invalid_request";
        case MoonlightCommonCCode::Busy: return "busy";
        case MoonlightCommonCCode::DriverException: return "internal_failure";
        case MoonlightCommonCCode::None: return "terminal";
    }
    return "terminal";
}

} // namespace

struct MoonlightProductStreamingRuntime::State final {
    std::mutex mutex;
    MoonlightBridgeRequestKey reservedLaunchKey {};
    std::optional<MoonlightProductLaunchStage> staged;
    MoonlightBridgeRequestKey activeLaunchKey {};
    MoonlightSessionKey activeSessionKey {};
    MoonlightBridgeRequestKey startingLaunchKey {};
    bool startingCancelRequested = false;
    MoonlightSessionKey terminalDuringStart {};
    MoonlightBridgeRequestKey terminalLaunchKey {};
    MoonlightProductStreamSnapshot terminalReceipt {};
    bool inputActivationAttempted = false;
    bool inputActivationFailed = false;
};

MoonlightProductStreamingRuntime& MoonlightProductStreamingRuntime::process() noexcept {
    static MoonlightProductStreamingRuntime runtime;
    return runtime;
}

MoonlightProductStreamingRuntime::State&
MoonlightProductStreamingRuntime::state() noexcept {
    static State value;
    return value;
}

bool MoonlightProductStreamingRuntime::reserveLaunch(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    if (!launchKey.valid()) {
        return false;
    }
    try {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.reservedLaunchKey.valid() || value.staged.has_value() ||
            value.startingLaunchKey.valid() || value.activeSessionKey.valid()) {
            return false;
        }
        value.reservedLaunchKey = launchKey;
        return true;
    } catch (...) {
        return false;
    }
}

bool MoonlightProductStreamingRuntime::releaseLaunchReservation(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    if (!launchKey.valid()) {
        return false;
    }
    try {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.reservedLaunchKey != launchKey) {
            return false;
        }
        value.reservedLaunchKey = {};
        return true;
    } catch (...) {
        return false;
    }
}

bool MoonlightProductStreamingRuntime::stageLaunch(
    MoonlightProductLaunchStage stage) noexcept {
    if (!stage.key.valid() || stage.hostId.empty() || stage.serverUuid.empty() ||
        stage.address.empty() || stage.appId == 0U || stage.rtspSessionUrl.empty() ||
        stage.expiresAtMonotonicMs <= monotonicMs()) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return false;
    }
    try {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.reservedLaunchKey != stage.key || value.staged.has_value() ||
            value.startingLaunchKey.valid() || value.activeSessionKey.valid()) {
            std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
            return false;
        }
        value.reservedLaunchKey = {};
        value.terminalLaunchKey = {};
        value.terminalReceipt = {};
        value.staged = std::move(stage);
        return true;
    } catch (...) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return false;
    }
}

MoonlightProductStreamStartResult MoonlightProductStreamingRuntime::start(
    MoonlightProductStreamStartRequest request) noexcept {
    MoonlightProductLaunchStage stage;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeSessionKey.valid() || value.startingLaunchKey.valid()) {
            return {false, "busy", {}};
        }
        if (!value.staged.has_value() ||
            !sameLaunchKey(value.staged->key, request.launchKey) ||
            value.staged->hostId != request.hostId ||
            value.staged->serverUuid != request.serverUuid ||
            value.staged->appId != request.appId ||
            value.staged->expiresAtMonotonicMs <= monotonicMs()) {
            return {false, "launch_lease_missing", {}};
        }
        stage = std::move(*value.staged);
        value.staged.reset();
        value.startingLaunchKey = request.launchKey;
        value.startingCancelRequested = false;
        value.terminalDuringStart = {};
    }
    auto finishBeforeCommonC = [&](const char* code) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        const bool cancelled = value.startingLaunchKey == request.launchKey &&
            value.startingCancelRequested;
        if (value.startingLaunchKey == request.launchKey) {
            value.startingLaunchKey = {};
            value.startingCancelRequested = false;
            value.terminalDuringStart = {};
        }
        return MoonlightProductStreamStartResult{
            false, cancelled ? "cancelled" : code, {}};
    };
    if (request.rendererHandle <= 0 || request.surfaceWidth <= 0 ||
        request.surfaceHeight <= 0) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return finishBeforeCommonC("invalid_surface");
    }
    const auto now = monotonicMs();
    auto streamConfig = conservativeOffer(stage, request);
    if (!streamConfig.has_value()) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return finishBeforeCommonC("stream_config_rejected");
    }
    auto media = MoonlightProductSessionMediaPort::create(
        request.rendererHandle,
        static_cast<std::int32_t>(stage.configuration.width),
        static_cast<std::int32_t>(stage.configuration.height),
        request.audioEnabled);
    if (media == nullptr) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return finishBeforeCommonC("media_unavailable");
    }
    MoonlightCommonCRequest common;
    common.sessionId = stage.key.requestId;
    common.generation = stage.key.generation;
    common.accountOwnerToken = stage.key.ownerToken;
    common.deferRuntimeCapabilityProof = true;
    common.streamConfig = std::move(*streamConfig);
    common.server.address = stage.address;
    common.server.appVersion = stage.serverInfo.appVersion;
    common.server.gfeVersion = stage.serverInfo.gfeVersion;
    common.server.authenticated = true;
    common.server.hostCapabilityGeneration = stage.key.generation;
    // The profile is admitted only because conservativeOffer() verified the
    // authenticated server launch receipt's SCM_H264 bit.
    common.server.codecProfiles = {{MoonlightStreamCodec::H264,
        MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420}};
    common.launchLease = MoonlightRtspLaunchLease(
        stage.remoteInputKey, stage.remoteInputKeyId,
        std::move(stage.rtspSessionUrl), stage.key.ownerToken,
        stage.key.generation, stage.hostId, stage.serverUuid,
        stage.key.generation, stage.key.generation);
    std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
    common.deadlines.overallMonotonicMs = now + 30000U;
    common.deadlines.stageMonotonicMs.fill(now + 15000U);
    const auto launchKey = request.launchKey;
    common.terminalInputTeardown = [](const MoonlightSessionKey& key) noexcept {
        (void)MoonlightProductInputRuntime::process().stop(key);
    };
    common.terminalComplete = [launchKey](const MoonlightSessionKey& key) noexcept {
        MoonlightProductStreamingRuntime::process().completeTerminal(launchKey, key);
    };
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.startingLaunchKey != launchKey ||
            value.startingCancelRequested) {
            value.startingLaunchKey = {};
            value.startingCancelRequested = false;
            value.terminalDuringStart = {};
            return {false, "cancelled", {}};
        }
    }
    const auto started = MoonlightCommonCAdapter::process().startWithMedia(
        std::move(common), std::move(media));
    if (started.status != MoonlightCommonCStartStatus::Accepted) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        const bool cancelled = value.startingLaunchKey == launchKey &&
            value.startingCancelRequested;
        if (value.startingLaunchKey == launchKey) {
            value.startingLaunchKey = {};
            value.startingCancelRequested = false;
            value.terminalDuringStart = {};
        }
        return {false, cancelled ? "cancelled" : startCode(started.status), {}};
    }
    bool cancelDuringStart = false;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        const bool alreadyTerminal = value.startingLaunchKey == launchKey &&
            value.terminalDuringStart == started.key;
        cancelDuringStart = value.startingLaunchKey == launchKey &&
            value.startingCancelRequested;
        value.startingLaunchKey = {};
        value.startingCancelRequested = false;
        value.terminalDuringStart = {};
        if (alreadyTerminal) {
            return {false, cancelDuringStart ? "cancelled" : "terminal",
                    started.key};
        }
        value.activeLaunchKey = launchKey;
        value.activeSessionKey = started.key;
        value.inputActivationAttempted = false;
        value.inputActivationFailed = false;
    }
    if (cancelDuringStart) {
        (void)requestStop(launchKey);
        return {false, "cancelled", started.key};
    }
    return {true, "accepted", started.key};
}

MoonlightProductStreamSnapshot MoonlightProductStreamingRuntime::snapshot(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey || !value.activeSessionKey.valid()) {
            if (value.terminalLaunchKey == launchKey &&
                value.terminalReceipt.matched) {
                return value.terminalReceipt;
            }
            return {};
        }
        key = value.activeSessionKey;
    }
    const auto source = MoonlightCommonCAdapter::process().snapshot(key);
    bool activateInput = false;
    if (source.transportReady && !source.terminal) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key &&
            !value.inputActivationAttempted) {
            value.inputActivationAttempted = true;
            activateInput = true;
        }
    }
    if (activateInput && !MoonlightProductInputRuntime::process().activate(key)) {
        bool shouldStop = false;
        {
            auto& value = state();
            std::lock_guard<std::mutex> lock(value.mutex);
            if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
                value.inputActivationFailed = true;
                shouldStop = true;
            }
        }
        if (shouldStop) {
            (void)requestStop(launchKey);
        }
    }
    const auto input = MoonlightProductInputRuntime::process().snapshot(key);
    bool inputActivationFailed = false;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
            inputActivationFailed = value.inputActivationFailed;
        } else if (value.terminalLaunchKey == launchKey &&
                   value.terminalReceipt.matched) {
            return value.terminalReceipt;
        } else {
            return {};
        }
    }
    MoonlightProductStreamSnapshot result;
    result.matched = source.matched;
    result.key = source.key;
    result.code = snapshotCode(source, inputActivationFailed);
    result.transportReady = source.transportReady;
    result.videoReady = source.videoReady;
    result.audioReady = source.audioReady;
    result.inputReady = input.inputReady;
    result.controllerReady = input.controllerReady;
    result.physicalControllerReady = input.physicalControllerReady;
    result.firstFrameReady = source.firstFrameReady;
    result.terminal = source.terminal;
    result.lastSequence = source.lastSequence;
    if (source.terminal) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
            value.terminalLaunchKey = launchKey;
            value.terminalReceipt = result;
            value.activeLaunchKey = {};
            value.activeSessionKey = {};
            value.inputActivationAttempted = false;
            value.inputActivationFailed = false;
        }
    }
    return result;
}

std::size_t MoonlightProductStreamingRuntime::cancelOwner(
    std::uint64_t ownerToken) noexcept {
    if (ownerToken == 0U) {
        return 0U;
    }
    try {
        MoonlightBridgeRequestKey activeLaunchKey;
        std::size_t cancelled = 0U;
        {
            auto& value = state();
            std::lock_guard<std::mutex> lock(value.mutex);
            if (value.reservedLaunchKey.valid() &&
                value.reservedLaunchKey.ownerToken == ownerToken) {
                value.reservedLaunchKey = {};
                ++cancelled;
            }
            if (value.staged.has_value() &&
                value.staged->key.ownerToken == ownerToken) {
                std::fill(value.staged->remoteInputKey.begin(),
                          value.staged->remoteInputKey.end(), 0U);
                value.staged.reset();
                ++cancelled;
            }
            if (value.startingLaunchKey.valid() &&
                value.startingLaunchKey.ownerToken == ownerToken &&
                !value.startingCancelRequested) {
                value.startingCancelRequested = true;
                ++cancelled;
            }
            if (value.activeLaunchKey.valid() &&
                value.activeLaunchKey.ownerToken == ownerToken) {
                activeLaunchKey = value.activeLaunchKey;
                ++cancelled;
            }
        }
        // Never block the ArkTS event thread while the common-c worker exits.
        // The regular terminal callback still owns media/input release and the
        // final receipt, exactly as it does for moonlightStopStream().
        if (activeLaunchKey.valid()) {
            (void)requestStop(activeLaunchKey);
        }
        return cancelled;
    } catch (...) {
        return 0U;
    }
}

bool MoonlightProductStreamingRuntime::requestStop(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    const auto result = MoonlightCommonCAdapter::process().requestStop(key);
    return result == MoonlightStopStatus::StopRequested ||
        result == MoonlightStopStatus::AlreadyTerminal;
}

bool MoonlightProductStreamingRuntime::stop(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    const auto result = MoonlightCommonCAdapter::process().stop(
        key, std::chrono::seconds(5));
    const bool stopped = result == MoonlightStopStatus::Stopped ||
        result == MoonlightStopStatus::AlreadyTerminal;
    if (stopped) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
            value.terminalLaunchKey = launchKey;
            value.terminalReceipt = {};
            value.terminalReceipt.matched = true;
            value.terminalReceipt.key = key;
            value.terminalReceipt.code = "cancelled";
            value.terminalReceipt.terminal = true;
            value.activeLaunchKey = {};
            value.activeSessionKey = {};
            value.inputActivationAttempted = false;
            value.inputActivationFailed = false;
        }
    }
    return stopped;
}

void MoonlightProductStreamingRuntime::completeTerminal(
    const MoonlightBridgeRequestKey& launchKey,
    const MoonlightSessionKey& sessionKey) noexcept {
    const auto source = MoonlightCommonCAdapter::process().snapshot(sessionKey);
    MoonlightProductStreamSnapshot receipt;
    receipt.matched = source.matched;
    receipt.key = source.key;
    receipt.transportReady = source.transportReady;
    receipt.videoReady = source.videoReady;
    receipt.audioReady = source.audioReady;
    receipt.firstFrameReady = source.firstFrameReady;
    receipt.terminal = source.terminal;
    receipt.lastSequence = source.lastSequence;
    auto& value = state();
    std::lock_guard<std::mutex> lock(value.mutex);
    if (value.activeLaunchKey == launchKey &&
        value.activeSessionKey == sessionKey) {
        receipt.code = snapshotCode(source, value.inputActivationFailed);
        value.terminalLaunchKey = launchKey;
        if (receipt.matched && receipt.terminal) {
            value.terminalReceipt = std::move(receipt);
        } else {
            value.terminalReceipt = {};
            value.terminalReceipt.matched = true;
            value.terminalReceipt.key = sessionKey;
            value.terminalReceipt.code = value.inputActivationFailed ?
                "input_failed" : "terminal";
            value.terminalReceipt.terminal = true;
        }
        value.activeLaunchKey = {};
        value.activeSessionKey = {};
        value.inputActivationAttempted = false;
        value.inputActivationFailed = false;
    } else if (value.startingLaunchKey == launchKey) {
        value.terminalDuringStart = sessionKey;
    }
}

bool MoonlightProductStreamingRuntime::sendKey(
    const MoonlightBridgeRequestKey& launchKey, std::uint32_t harmonyKeyCode,
    bool pressed, bool normalizedToUsLayout) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    return MoonlightProductInputRuntime::process().sendKey(
        key, harmonyKeyCode, pressed, normalizedToUsLayout);
}

bool MoonlightProductStreamingRuntime::sendText(
    const MoonlightBridgeRequestKey& launchKey, const std::uint8_t* text,
    std::size_t size) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    return MoonlightProductInputRuntime::process().sendText(key, text, size);
}

bool MoonlightProductStreamingRuntime::sendPointer(
    const MoonlightBridgeRequestKey& launchKey,
    const MoonlightProductPointerRequest& request) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    return MoonlightProductInputRuntime::process().sendPointer(key, request);
}

bool MoonlightProductStreamingRuntime::sendTouch(
    const MoonlightBridgeRequestKey& launchKey,
    const MoonlightProductTouchRequest& request) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    return MoonlightProductInputRuntime::process().sendTouch(key, request);
}

bool MoonlightProductStreamingRuntime::setInputSuspended(
    const MoonlightBridgeRequestKey& launchKey,
    MoonlightInputFlushTrigger trigger, bool suspended) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    return MoonlightProductInputRuntime::process().setSuspended(
        key, trigger, suspended);
}

bool MoonlightProductStreamingRuntime::setTouchMode(
    const MoonlightBridgeRequestKey& launchKey, bool direct) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    return MoonlightProductInputRuntime::process().setTouchMode(key, direct);
}

bool MoonlightProductStreamingRuntime::setVirtualControllerMode(
    const MoonlightBridgeRequestKey& launchKey, bool enabled,
    bool editing) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    return MoonlightProductInputRuntime::process().setVirtualControllerMode(
        key, enabled, editing);
}

bool MoonlightProductStreamingRuntime::sendVirtualController(
    const MoonlightBridgeRequestKey& launchKey,
    const MoonlightProductVirtualControllerRequest& request) noexcept {
    MoonlightSessionKey key;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
    }
    return MoonlightProductInputRuntime::process().sendVirtualController(
        key, request);
}

void MoonlightProductStreamingRuntime::shutdown() noexcept {
    MoonlightBridgeRequestKey launchKey;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        value.reservedLaunchKey = {};
        if (value.staged.has_value()) {
            std::fill(value.staged->remoteInputKey.begin(),
                      value.staged->remoteInputKey.end(), 0U);
            value.staged.reset();
        }
        if (value.startingLaunchKey.valid()) {
            value.startingCancelRequested = true;
        }
        launchKey = value.activeLaunchKey;
    }
    if (launchKey.valid()) { (void)stop(launchKey); }
}

} // namespace remotedesk::moonlight
