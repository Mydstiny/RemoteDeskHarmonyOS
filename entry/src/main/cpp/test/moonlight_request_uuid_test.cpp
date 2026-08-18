#include "moonlight/core/MoonlightHostApi.h"
#include "moonlight/runtime/MoonlightRequestUuid.h"
#include "test_runner.h"

#include <array>
#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_set>

namespace {

using namespace remotedesk::moonlight;

bool validUuidV4(const std::string& value) {
    if (value.size() != 36U || value[8] != '-' || value[13] != '-' ||
        value[18] != '-' || value[23] != '-' || value[14] != '4' ||
        std::string("89ab").find(value[19]) == std::string::npos) {
        return false;
    }
    for (std::size_t index = 0U; index < value.size(); ++index) {
        if (index == 8U || index == 13U || index == 18U || index == 23U) {
            continue;
        }
        const char character = value[index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) {
            return false;
        }
    }
    return true;
}

class CapturingTransport final : public MoonlightHostTransport {
public:
    MoonlightTransportOutcome execute(
        const MoonlightTransportRequest& request,
        std::chrono::steady_clock::time_point /*deadline*/,
        const CancellationProbe& /*cancellationProbe*/) override {
        ++calls;
        url = request.url();
        MoonlightTransportOutcome outcome;
        outcome.error = MoonlightTransportError::ProtocolFailure;
        outcome.stage = MoonlightTransportStage::Http;
        return outcome;
    }

    std::size_t calls = 0U;
    std::string url;
};

} // namespace

RDP_TEST_CASE(moonlight_request_uuid_formats_rfc4122_version_and_variant) {
    std::array<std::uint8_t, 16U> entropy {};
    for (std::size_t index = 0U; index < entropy.size(); ++index) {
        entropy[index] = static_cast<std::uint8_t>(index);
    }
    std::string uuid;
    RDP_ASSERT(formatMoonlightRequestUuidV4(entropy, uuid));
    RDP_ASSERT(uuid == "00010203-0405-4607-8809-0a0b0c0d0e0f");
    RDP_ASSERT(validUuidV4(uuid));
}

RDP_TEST_CASE(moonlight_request_uuid_product_generator_returns_unique_valid_values) {
    std::unordered_set<std::string> generated;
    for (std::size_t index = 0U; index < 64U; ++index) {
        const std::string uuid = generateMoonlightRequestUuid();
        RDP_ASSERT(validUuidV4(uuid));
        RDP_ASSERT(generated.insert(uuid).second);
    }
}

RDP_TEST_CASE(moonlight_request_uuid_product_generator_reaches_host_transport) {
    auto transport = std::make_shared<CapturingTransport>();
    MoonlightHostApi api(transport, generateMoonlightRequestUuid);
    MoonlightHostCall call;
    call.key = {1U, 1U, 1U};
    call.operation = MoonlightHostOperation::ServerInfo;
    call.endpoint.serverName = "sunshine.local";
    call.endpoint.addresses = {
        {"192.0.2.20", MoonlightHostAddressFamily::Ipv4},
    };
    (void)api.execute(call);

    RDP_ASSERT_EQ(transport->calls, static_cast<std::size_t>(1U));
    const std::string marker = "&uuid=";
    const std::size_t uuidOffset = transport->url.find(marker);
    RDP_ASSERT(transport->url.find("?uniqueid=0123456789ABCDEF") !=
               std::string::npos);
    RDP_ASSERT(uuidOffset != std::string::npos);
    RDP_ASSERT(validUuidV4(transport->url.substr(uuidOffset + marker.size())));
}
