#include "moonlight/runtime/MoonlightProductStreamingRuntime.h"

#include "moonlight/media/MoonlightProductSessionMediaPort.h"
#include "moonlight/media/MoonlightStreamConfig.h"
#include "moonlight/media/MoonlightVideoCodecSupport.h"
#include "moonlight/input/MoonlightProductInputRuntime.h"

#include <algorithm>
#include <chrono>
#include <hilog/log.h>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0041
#define LOG_TAG "MOON_RUNTIME"

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
    const auto serverCodecBit = moonlightServerCodecBit(request.codec);
    const auto maximumLuma = request.codec == MoonlightStreamCodec::H264 ?
        stage.serverInfo.maxLumaPixelsH264 : stage.serverInfo.maxLumaPixelsHevc;
    if (width < kMinimumWidth || width > kMaximumWidth ||
        height < kMinimumHeight || height > kMaximumHeight ||
        (width % 2U) != 0U || (height % 2U) != 0U ||
        fps < kMinimumFps || fps > kMaximumFps ||
        request.configuredBitrateKbps < kMinimumBitrateKbps ||
        request.configuredBitrateKbps > kMaximumBitrateKbps ||
        !moonlightProductStreamingPolicyAllows(
            request.latencyMode, request.encryptionPolicy) ||
        !moonlightHardwareVideoProfileSupported(
            moonlightHardwareVideoProfile(request.codec)) ||
        request.hdr || request.yuv444 ||
        !moonlightProductAudioContractAllows(
            request.audioEnabled, request.audioLayout,
            stage.configuration.surroundAudioInfo) ||
        stage.configuration.hdr != request.hdr ||
        stage.configuration.playAudioOnHost != request.playAudioOnHost ||
        !stage.serverInfo.paired ||
        stage.serverInfo.currentGame != stage.appId ||
        stage.serverInfo.uniqueId != stage.serverUuid ||
        !stage.serverInfo.codecModeSupport.has_value() ||
        serverCodecBit == 0U ||
        ((*stage.serverInfo.codecModeSupport & serverCodecBit) == 0U) ||
        (maximumLuma.has_value() && pixels > *maximumLuma)) {
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
        offer.offeredCodecs = {{request.codec,
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
    std::shared_ptr<MoonlightProductSessionMediaPort> activeMedia;
    std::int32_t activeStreamWidth = 0;
    std::int32_t activeStreamHeight = 0;
    std::int32_t activeTargetFps = 0;
    std::int32_t activeConfiguredBitrateKbps = 0;
    MoonlightStreamCodec activeCodec = MoonlightStreamCodec::H264;
    bool resetRemoteInputBeforeAdmission = false;
    bool inputActivationAttempted = false;
    bool inputActivationFailed = false;
    std::uint64_t nextFirstFrameDiagnosticAtMs = 0U;
    bool firstFrameReadyLogged = false;
    bool sessionFirstFrameReady = false;
    MoonlightSessionKey terminalInputTeardownKey {};
    bool terminalInputTeardownObserved = false;
    bool terminalInputLocalCleanupComplete = false;
    bool terminalInputRemoteNeutral = false;
    MoonlightBridgeRequestKey stopDrainLaunchKey {};
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
        value.terminalInputTeardownKey = {};
        value.terminalInputTeardownObserved = false;
        value.terminalInputLocalCleanupComplete = false;
        value.terminalInputRemoteNeutral = false;
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
        value.terminalInputTeardownKey = {};
        value.terminalInputTeardownObserved = false;
        value.terminalInputLocalCleanupComplete = false;
        value.terminalInputRemoteNeutral = false;
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
    OH_LOG_INFO(LOG_APP,
                "stream start request mode=%{public}ux%{public}u@%{public}u surface=%{public}dx%{public}d bitrate=%{public}d codec=%{public}d desktopSurface=%{public}s",
                stage.configuration.width,
                stage.configuration.height,
                stage.configuration.refreshRate,
                request.surfaceWidth,
                request.surfaceHeight,
                request.configuredBitrateKbps,
                static_cast<int>(request.codec),
                request.desktopSurfaceCompatibility ? "yes" : "no");
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
        request.codec,
        request.audioEnabled,
        request.desktopSurfaceCompatibility);
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
    if (!moonlightProductPopulateCommonCServer(
            common.server, stage,
            moonlightHardwareVideoProfile(request.codec))) {
        std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
        return finishBeforeCommonC("server_evidence_unavailable");
    }
    common.launchLease = MoonlightRtspLaunchLease(
        stage.remoteInputKey, stage.remoteInputKeyId,
        std::move(stage.rtspSessionUrl), stage.key.ownerToken,
        stage.key.generation, stage.hostId, stage.serverUuid,
        stage.key.generation, stage.key.generation);
    std::fill(stage.remoteInputKey.begin(), stage.remoteInputKey.end(), 0U);
    common.deadlines.overallMonotonicMs = now + 30000U;
    common.deadlines.stageMonotonicMs.fill(now + 15000U);
    const auto launchKey = request.launchKey;
    common.terminalInputTeardown = [launchKey](
        const MoonlightSessionKey& key) noexcept {
        const auto stopped = MoonlightProductInputRuntime::process().stop(key);
        MoonlightProductStreamingRuntime::process().recordTerminalInputTeardown(
            launchKey, key, stopped.localCleanupComplete,
            stopped.remoteNeutral);
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
    // Keep only a shared control reference to the same media composition that
    // common-c owns. Surface/audio lifecycle calls therefore cannot create or
    // select another decoder, player, queue, or connection.
    const auto mediaControl = media;
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
        value.activeMedia = mediaControl;
        value.activeStreamWidth = static_cast<std::int32_t>(stage.configuration.width);
        value.activeStreamHeight = static_cast<std::int32_t>(stage.configuration.height);
        value.activeTargetFps = static_cast<std::int32_t>(stage.configuration.refreshRate);
        value.activeConfiguredBitrateKbps = request.configuredBitrateKbps;
        value.activeCodec = request.codec;
        value.resetRemoteInputBeforeAdmission =
            request.resetRemoteInputBeforeAdmission;
        value.inputActivationAttempted = false;
        value.inputActivationFailed = false;
        value.nextFirstFrameDiagnosticAtMs = 0U;
        value.firstFrameReadyLogged = false;
        value.sessionFirstFrameReady = false;
    }
    OH_LOG_INFO(LOG_APP,
                "stream start accepted mode=%{public}ux%{public}u@%{public}u bitrate=%{public}d codec=%{public}d",
                stage.configuration.width,
                stage.configuration.height,
                stage.configuration.refreshRate,
                request.configuredBitrateKbps,
                static_cast<int>(request.codec));
    if (cancelDuringStart) {
        (void)requestStop(launchKey);
        return {false, "cancelled", started.key};
    }
    return {true, "accepted", started.key};
}

MoonlightProductStreamSnapshot MoonlightProductStreamingRuntime::snapshot(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    MoonlightSessionKey key;
    std::shared_ptr<MoonlightProductSessionMediaPort> media;
    std::int32_t streamWidth = 0;
    std::int32_t streamHeight = 0;
    std::int32_t targetFps = 0;
    std::int32_t configuredBitrateKbps = 0;
    MoonlightStreamCodec codec = MoonlightStreamCodec::H264;
    bool resetRemoteInputBeforeAdmission = false;
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
        media = value.activeMedia;
        streamWidth = value.activeStreamWidth;
        streamHeight = value.activeStreamHeight;
        targetFps = value.activeTargetFps;
        configuredBitrateKbps = value.activeConfiguredBitrateKbps;
        codec = value.activeCodec;
        resetRemoteInputBeforeAdmission =
            value.resetRemoteInputBeforeAdmission;
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
    if (activateInput && !MoonlightProductInputRuntime::process().activate(
            key, resetRemoteInputBeforeAdmission)) {
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
    if (input.recoveryResetFailed) {
        bool shouldStop = false;
        {
            auto& value = state();
            std::lock_guard<std::mutex> lock(value.mutex);
            if (value.activeLaunchKey == launchKey &&
                value.activeSessionKey == key) {
                value.inputActivationFailed = true;
                shouldStop = true;
            }
        }
        if (shouldStop) {
            (void)requestStop(launchKey);
        }
    }
    bool inputActivationFailed = false;
    bool terminalInputMayBeStuck = false;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
            inputActivationFailed = value.inputActivationFailed;
            terminalInputMayBeStuck = source.terminal &&
                moonlightProductTerminalInputMayBeStuck(
                    value.inputActivationAttempted,
                    value.terminalInputTeardownObserved &&
                        value.terminalInputTeardownKey == key,
                    value.terminalInputLocalCleanupComplete,
                    value.terminalInputRemoteNeutral);
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
    result.transportReady = source.transportReady;
    result.videoReady = source.videoReady;
    result.audioReady = source.audioReady;
    result.inputReady = input.inputReady;
    result.controllerReady = input.controllerReady;
    result.physicalControllerReady = input.physicalControllerReady;
    result.inputMayBeStuck = input.inputMayBeStuck ||
        terminalInputMayBeStuck;
    result.presentationFrameReady = source.firstFrameReady;
    result.terminal = source.terminal;
    result.lastSequence = source.lastSequence;
    result.sampledAtMonotonicMs = monotonicMs();
    result.streamWidth = streamWidth;
    result.streamHeight = streamHeight;
    result.targetFps = targetFps;
    result.configuredBitrateKbps = configuredBitrateKbps;
    result.codec = codec;
    if (media != nullptr) {
        const auto diagnostics = media->diagnostics();
        if (diagnostics.matched) {
            result.acceptedVideoFrames = diagnostics.acceptedVideoFrames;
            result.droppedVideoFrames = diagnostics.droppedVideoFrames;
            result.acceptedVideoBytes = diagnostics.acceptedVideoBytes;
            result.rendererPresentedFrames =
                moonlightProductPresentedFrameProgress(
                    diagnostics.matched, diagnostics.acceptedVideoFrames,
                    diagnostics.renderedOutputBuffers,
                    diagnostics.nativeImageFrames,
                    diagnostics.rendererPresentedFrames);
            result.acceptedAudioPackets = diagnostics.acceptedAudioPackets;
            result.rejectedAudioPackets = diagnostics.rejectedAudioPackets;
            result.acceptedAudioBytes = diagnostics.acceptedAudioBytes;
            result.decoderQueueDepth = diagnostics.decoderQueueDepth;
            result.decoderInputDroppedFrames =
                diagnostics.decoderInputDroppedFrames;
            result.decoderWaitKeyframeDrops =
                diagnostics.decoderWaitKeyframeDrops;
            result.decoderInputTruncated = diagnostics.decoderInputTruncated;
            result.decoderRenderOutputFailures =
                diagnostics.decoderRenderOutputFailures;
            result.decoderSurfaceUpdateFailures =
                diagnostics.decoderSurfaceUpdateFailures;
            result.decoderSurfaceCoalescedNotifications =
                diagnostics.decoderSurfaceCoalescedNotifications;
            result.decoderCodecLatencyMs = diagnostics.decoderCodecLatencyMs;
            result.decoderCodecLatencyMaxMs =
                diagnostics.decoderCodecLatencyMaxMs;
            result.decoderLowLatencyEnabled =
                diagnostics.decoderLowLatencyEnabled;
        }
        result.presentationFrameReady = moonlightProductFirstFrameProven(
            source.firstFrameReady, diagnostics.matched,
            diagnostics.acceptedVideoFrames,
            diagnostics.renderedOutputBuffers,
            diagnostics.nativeImageFrames,
            diagnostics.rendererPresentedFrames);
        {
            auto& value = state();
            std::lock_guard<std::mutex> lock(value.mutex);
            if (value.activeLaunchKey == launchKey &&
                value.activeSessionKey == key) {
                value.sessionFirstFrameReady =
                    moonlightProductSessionFirstFrameReady(
                        value.sessionFirstFrameReady,
                        result.presentationFrameReady);
                result.firstFrameReady = value.sessionFirstFrameReady;
            }
        }
        result.videoReady = moonlightProductVideoReady(
            source.videoReady, result.firstFrameReady);
        if (!result.firstFrameReady) {
            bool shouldLog = false;
            {
                auto& value = state();
                std::lock_guard<std::mutex> lock(value.mutex);
                if (value.activeLaunchKey == launchKey &&
                    value.activeSessionKey == key &&
                    result.sampledAtMonotonicMs >=
                        value.nextFirstFrameDiagnosticAtMs) {
                    value.nextFirstFrameDiagnosticAtMs =
                        result.sampledAtMonotonicMs + 5000U;
                    shouldLog = true;
                }
            }
            if (shouldLog) {
                OH_LOG_WARN(LOG_APP,
                    "first-frame pending sourceMatched=%{public}d videoReady=%{public}d sourceFirst=%{public}d diagnosticsMatched=%{public}d accepted=%{public}llu rendered=%{public}llu nativeImage=%{public}llu rendererPresented=%{public}llu",
                    source.matched ? 1 : 0,
                    source.videoReady ? 1 : 0,
                    source.firstFrameReady ? 1 : 0,
                    diagnostics.matched ? 1 : 0,
                    static_cast<unsigned long long>(
                        diagnostics.acceptedVideoFrames),
                    static_cast<unsigned long long>(
                        diagnostics.renderedOutputBuffers),
                    static_cast<unsigned long long>(
                        diagnostics.nativeImageFrames),
                    static_cast<unsigned long long>(
                        diagnostics.rendererPresentedFrames));
            }
        } else {
            bool shouldLog = false;
            {
                auto& value = state();
                std::lock_guard<std::mutex> lock(value.mutex);
                if (value.activeLaunchKey == launchKey &&
                    value.activeSessionKey == key &&
                    !value.firstFrameReadyLogged) {
                    value.firstFrameReadyLogged = true;
                    shouldLog = true;
                }
            }
            if (shouldLog) {
                OH_LOG_INFO(LOG_APP,
                    "first-frame proven sourceVideoReady=%{public}d effectiveVideoReady=%{public}d sourceFirst=%{public}d diagnosticsMatched=%{public}d accepted=%{public}llu rendered=%{public}llu nativeImage=%{public}llu rendererPresented=%{public}llu",
                    source.videoReady ? 1 : 0,
                    result.videoReady ? 1 : 0,
                    source.firstFrameReady ? 1 : 0,
                    diagnostics.matched ? 1 : 0,
                    static_cast<unsigned long long>(
                        diagnostics.acceptedVideoFrames),
                    static_cast<unsigned long long>(
                        diagnostics.renderedOutputBuffers),
                    static_cast<unsigned long long>(
                        diagnostics.nativeImageFrames),
                    static_cast<unsigned long long>(
                        diagnostics.rendererPresentedFrames));
            }
        }
    }
    if (media == nullptr) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey &&
            value.activeSessionKey == key) {
            value.sessionFirstFrameReady =
                moonlightProductSessionFirstFrameReady(
                    value.sessionFirstFrameReady,
                    result.presentationFrameReady);
            result.firstFrameReady = value.sessionFirstFrameReady;
        }
        result.videoReady = moonlightProductVideoReady(
            source.videoReady, result.firstFrameReady);
    }
    result.code = inputActivationFailed || terminalInputMayBeStuck ?
        "input_failed" :
        (!source.terminal && result.firstFrameReady ? "first_frame" :
         snapshotCode(source, false));
    result.acceptedInputEvents = input.acceptedEvents;
    result.rejectedInputEvents = input.rejectedEvents;
    if (source.terminal) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
            value.terminalLaunchKey = launchKey;
            value.terminalReceipt = result;
            value.activeLaunchKey = {};
            value.activeSessionKey = {};
            value.activeMedia.reset();
            value.activeStreamWidth = 0;
            value.activeStreamHeight = 0;
            value.activeTargetFps = 0;
            value.activeConfiguredBitrateKbps = 0;
            value.activeCodec = MoonlightStreamCodec::H264;
            value.resetRemoteInputBeforeAdmission = false;
            value.inputActivationAttempted = false;
            value.inputActivationFailed = false;
            value.terminalInputTeardownKey = {};
            value.terminalInputTeardownObserved = false;
            value.terminalInputLocalCleanupComplete = false;
            value.terminalInputRemoteNeutral = false;
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
    bool startDrain = false;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey) { return false; }
        key = value.activeSessionKey;
        if (!value.stopDrainLaunchKey.valid()) {
            value.stopDrainLaunchKey = launchKey;
            startDrain = true;
        }
    }
    const auto result = MoonlightCommonCAdapter::process().requestStop(key);
    const bool accepted = result == MoonlightStopStatus::StopRequested ||
        result == MoonlightStopStatus::AlreadyTerminal;
    if (!accepted) {
        if (startDrain) {
            auto& value = state();
            std::lock_guard<std::mutex> lock(value.mutex);
            if (value.stopDrainLaunchKey == launchKey) {
                value.stopDrainLaunchKey = {};
            }
        }
        return false;
    }
    if (startDrain) {
        try {
            std::thread([launchKey]() noexcept {
                // requestStop() is deliberately non-blocking for ArkTS. Keep
                // an exact process-owned drain alive across bounded 5-second
                // waits until common-c really terminates or its terminal
                // callback has already cleared this launch key.
                for (;;) {
                    if (MoonlightProductStreamingRuntime::process().stop(
                            launchKey)) {
                        break;
                    }
                    bool stillActive = false;
                    {
                        auto& value =
                            MoonlightProductStreamingRuntime::process().state();
                        std::lock_guard<std::mutex> lock(value.mutex);
                        stillActive = value.activeLaunchKey == launchKey;
                    }
                    if (!stillActive) { break; }
                    std::this_thread::sleep_for(
                        std::chrono::milliseconds(25));
                }
                auto& value =
                    MoonlightProductStreamingRuntime::process().state();
                std::lock_guard<std::mutex> lock(value.mutex);
                if (value.stopDrainLaunchKey == launchKey) {
                    value.stopDrainLaunchKey = {};
                }
            }).detach();
        } catch (...) {
            auto& value = state();
            std::lock_guard<std::mutex> lock(value.mutex);
            if (value.stopDrainLaunchKey == launchKey) {
                value.stopDrainLaunchKey = {};
            }
        }
    }
    return true;
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
    const bool stopped = moonlightProductStopReachedTerminal(result);
    if (stopped) {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey == launchKey && value.activeSessionKey == key) {
            const bool inputMayBeStuck =
                moonlightProductTerminalInputMayBeStuck(
                    value.inputActivationAttempted,
                    value.terminalInputTeardownObserved &&
                        value.terminalInputTeardownKey == key,
                    value.terminalInputLocalCleanupComplete,
                    value.terminalInputRemoteNeutral);
            value.terminalLaunchKey = launchKey;
            value.terminalReceipt = {};
            value.terminalReceipt.matched = true;
            value.terminalReceipt.key = key;
            value.terminalReceipt.code = inputMayBeStuck ?
                "input_failed" :
                (result == MoonlightStopStatus::DriverFailure ?
                    "connection_failed" : "cancelled");
            value.terminalReceipt.inputMayBeStuck = inputMayBeStuck;
            value.terminalReceipt.firstFrameReady =
                value.sessionFirstFrameReady;
            value.terminalReceipt.terminal = true;
            value.terminalReceipt.streamWidth = value.activeStreamWidth;
            value.terminalReceipt.streamHeight = value.activeStreamHeight;
            value.terminalReceipt.targetFps = value.activeTargetFps;
            value.terminalReceipt.configuredBitrateKbps =
                value.activeConfiguredBitrateKbps;
            value.terminalReceipt.codec = value.activeCodec;
            value.activeLaunchKey = {};
            value.activeSessionKey = {};
            value.activeMedia.reset();
            value.activeStreamWidth = 0;
            value.activeStreamHeight = 0;
            value.activeTargetFps = 0;
            value.activeConfiguredBitrateKbps = 0;
            value.activeCodec = MoonlightStreamCodec::H264;
            value.resetRemoteInputBeforeAdmission = false;
            value.inputActivationAttempted = false;
            value.inputActivationFailed = false;
            value.terminalInputTeardownKey = {};
            value.terminalInputTeardownObserved = false;
            value.terminalInputLocalCleanupComplete = false;
            value.terminalInputRemoteNeutral = false;
        }
    }
    return stopped;
}

bool MoonlightProductStreamingRuntime::suspendSurface(
    const MoonlightBridgeRequestKey& launchKey) noexcept {
    std::shared_ptr<MoonlightProductSessionMediaPort> media;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey ||
            !value.activeSessionKey.valid() || value.activeMedia == nullptr) {
            return false;
        }
        media = value.activeMedia;
    }
    return media->suspendSurface();
}

bool MoonlightProductStreamingRuntime::rebindSurface(
    const MoonlightBridgeRequestKey& launchKey,
    std::int64_t rendererHandle) noexcept {
    std::shared_ptr<MoonlightProductSessionMediaPort> media;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey ||
            !value.activeSessionKey.valid() || value.activeMedia == nullptr) {
            return false;
        }
        media = value.activeMedia;
    }
    return media->rebindSurface(rendererHandle);
}

bool MoonlightProductStreamingRuntime::setAudioPaused(
    const MoonlightBridgeRequestKey& launchKey, bool paused) noexcept {
    std::shared_ptr<MoonlightProductSessionMediaPort> media;
    {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.activeLaunchKey != launchKey ||
            !value.activeSessionKey.valid() || value.activeMedia == nullptr) {
            return false;
        }
        media = value.activeMedia;
    }
    return paused ? media->pauseAudio() : media->resumeAudio();
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
    receipt.presentationFrameReady = source.firstFrameReady;
    receipt.terminal = source.terminal;
    receipt.lastSequence = source.lastSequence;
    auto& value = state();
    std::lock_guard<std::mutex> lock(value.mutex);
    if (value.activeLaunchKey == launchKey &&
        value.activeSessionKey == sessionKey) {
        receipt.firstFrameReady = moonlightProductSessionFirstFrameReady(
            value.sessionFirstFrameReady, receipt.presentationFrameReady);
        const bool inputMayBeStuck =
            moonlightProductTerminalInputMayBeStuck(
                value.inputActivationAttempted,
                value.terminalInputTeardownObserved &&
                    value.terminalInputTeardownKey == sessionKey,
                value.terminalInputLocalCleanupComplete,
                value.terminalInputRemoteNeutral);
        receipt.inputMayBeStuck = inputMayBeStuck;
        receipt.code = snapshotCode(
            source, value.inputActivationFailed || inputMayBeStuck);
        value.terminalLaunchKey = launchKey;
        if (receipt.matched && receipt.terminal) {
            value.terminalReceipt = std::move(receipt);
        } else {
            value.terminalReceipt = {};
            value.terminalReceipt.matched = true;
            value.terminalReceipt.key = sessionKey;
            value.terminalReceipt.code =
                (value.inputActivationFailed || inputMayBeStuck) ?
                "input_failed" : "terminal";
            value.terminalReceipt.inputMayBeStuck = inputMayBeStuck;
            value.terminalReceipt.firstFrameReady =
                value.sessionFirstFrameReady;
            value.terminalReceipt.terminal = true;
        }
        value.terminalReceipt.streamWidth = value.activeStreamWidth;
        value.terminalReceipt.streamHeight = value.activeStreamHeight;
        value.terminalReceipt.targetFps = value.activeTargetFps;
        value.terminalReceipt.configuredBitrateKbps =
            value.activeConfiguredBitrateKbps;
        value.terminalReceipt.codec = value.activeCodec;
        value.activeLaunchKey = {};
        value.activeSessionKey = {};
        value.activeMedia.reset();
        value.activeStreamWidth = 0;
        value.activeStreamHeight = 0;
        value.activeTargetFps = 0;
        value.activeConfiguredBitrateKbps = 0;
        value.activeCodec = MoonlightStreamCodec::H264;
        value.resetRemoteInputBeforeAdmission = false;
        value.inputActivationAttempted = false;
        value.inputActivationFailed = false;
        value.terminalInputTeardownKey = {};
        value.terminalInputTeardownObserved = false;
        value.terminalInputLocalCleanupComplete = false;
        value.terminalInputRemoteNeutral = false;
    } else if (value.startingLaunchKey == launchKey) {
        value.terminalDuringStart = sessionKey;
    }
}

void MoonlightProductStreamingRuntime::recordTerminalInputTeardown(
    const MoonlightBridgeRequestKey& launchKey,
    const MoonlightSessionKey& sessionKey,
    bool localCleanupComplete, bool remoteNeutral) noexcept {
    try {
        auto& value = state();
        std::lock_guard<std::mutex> lock(value.mutex);
        const bool matchesActive = value.activeLaunchKey == launchKey &&
            value.activeSessionKey == sessionKey;
        const bool matchesStarting = value.startingLaunchKey == launchKey;
        if (!matchesActive && !matchesStarting) {
            return;
        }
        value.terminalInputTeardownKey = sessionKey;
        value.terminalInputTeardownObserved = true;
        value.terminalInputLocalCleanupComplete = localCleanupComplete;
        value.terminalInputRemoteNeutral = remoteNeutral;
    } catch (...) {
        // Missing proof is handled conservatively by completeTerminal().
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
