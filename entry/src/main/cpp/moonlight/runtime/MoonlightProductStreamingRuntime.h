#ifndef REMOTEDESK_MOONLIGHT_PRODUCT_STREAMING_RUNTIME_H
#define REMOTEDESK_MOONLIGHT_PRODUCT_STREAMING_RUNTIME_H

#include "moonlight/bridge/MoonlightNativeBridge.h"
#include "moonlight/core/MoonlightHostApi.h"
#include "moonlight/media/MoonlightCommonCAdapter.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace remotedesk::moonlight {

struct MoonlightProductLaunchStage final {
    MoonlightBridgeRequestKey key {};
    std::string hostId;
    std::string serverUuid;
    std::string address;
    std::uint32_t appId = 0U;
    MoonlightBridgeLaunchConfiguration configuration {};
    MoonlightServerInfo serverInfo {};
    std::array<std::uint8_t, 16U> remoteInputKey {};
    std::int32_t remoteInputKeyId = 0;
    std::string rtspSessionUrl;
    std::uint64_t expiresAtMonotonicMs = 0U;
};

struct MoonlightProductStreamStartRequest final {
    MoonlightBridgeRequestKey launchKey {};
    std::string hostId;
    std::string serverUuid;
    std::uint32_t appId = 0U;
    std::int64_t rendererHandle = 0;
    std::int32_t surfaceWidth = 0;
    std::int32_t surfaceHeight = 0;
};

struct MoonlightProductStreamStartResult final {
    bool accepted = false;
    std::string code = "invalid_request";
    MoonlightSessionKey key {};
};

struct MoonlightProductStreamSnapshot final {
    bool matched = false;
    MoonlightSessionKey key {};
    std::string code = "not_active";
    bool transportReady = false;
    bool firstFrameReady = false;
    bool terminal = false;
    std::uint64_t lastSequence = 0U;
};

class MoonlightProductStreamingRuntime final {
public:
    static MoonlightProductStreamingRuntime& process() noexcept;

    bool stageLaunch(MoonlightProductLaunchStage stage) noexcept;
    MoonlightProductStreamStartResult start(
        MoonlightProductStreamStartRequest request) noexcept;
    MoonlightProductStreamSnapshot snapshot(
        const MoonlightBridgeRequestKey& launchKey) noexcept;
    bool requestStop(const MoonlightBridgeRequestKey& launchKey) noexcept;
    bool stop(const MoonlightBridgeRequestKey& launchKey) noexcept;
    void shutdown() noexcept;

private:
    MoonlightProductStreamingRuntime() = default;
    struct State;
    State& state() noexcept;
};

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_PRODUCT_STREAMING_RUNTIME_H
