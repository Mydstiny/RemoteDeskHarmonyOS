/** Native tests for the shared RFB and UltraVNC wire contracts. */
#include "test_runner.h"
#include "vnc/vnc_rfb_protocol.h"
#include "vnc/vnc_transport_policy.h"

#include <array>
#include <cstdint>
#include <string>

RDP_TEST_CASE(vnc_rfb_client_init_is_shared_one_byte) {
    RDP_ASSERT_EQ(VncRfbProtocol::clientInitSharedFlag(), static_cast<uint8_t>(1));
}

RDP_TEST_CASE(vnc_rfb_minor_normalization_is_fail_closed) {
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(3), 3);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(7), 7);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(8), 8);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(4), 3);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(6), 3);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeRfbMinor(9), 3);
}

RDP_TEST_CASE(vnc_rfb_security_result_contract_matches_version) {
    RDP_ASSERT(!VncRfbProtocol::securityResultExpected(3, 1));
    RDP_ASSERT(!VncRfbProtocol::securityResultExpected(7, 1));
    RDP_ASSERT(VncRfbProtocol::securityResultExpected(8, 1));
    RDP_ASSERT(VncRfbProtocol::securityResultExpected(3, 2));
    RDP_ASSERT(VncRfbProtocol::securityResultExpected(7, 2));
    RDP_ASSERT(VncRfbProtocol::securityResultExpected(8, 2));
}

RDP_TEST_CASE(vnc_framebuffer_update_request_has_exact_rfb_wire_layout) {
    const std::vector<uint8_t> initial =
        VncRfbProtocol::buildFramebufferUpdateRequest(false, 1920, 1080);
    RDP_ASSERT_EQ(initial.size(), static_cast<size_t>(10));
    const std::vector<uint8_t> expectedInitial = {
        3, 0, 0, 0, 0, 0, 7, 128, 4, 56,
    };
    RDP_ASSERT(initial == expectedInitial);

    const std::vector<uint8_t> incremental =
        VncRfbProtocol::buildFramebufferUpdateRequest(true, 2560, 1600);
    RDP_ASSERT_EQ(incremental.size(), static_cast<size_t>(10));
    const std::vector<uint8_t> expectedIncremental = {
        3, 1, 0, 0, 0, 0, 10, 0, 6, 64,
    };
    RDP_ASSERT(incremental == expectedIncremental);
}

RDP_TEST_CASE(vnc_pixel_format_policy_is_bounded_and_wire_exact) {
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("32", "speed", 9000000), 32);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("16", "quality", 100), 16);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("8", "balanced", 100), 8);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "speed", 100), 16);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "balanced",
        5ULL * 1024ULL * 1024ULL), 16);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "quality", 100), 32);
    RDP_ASSERT_EQ(VncRfbProtocol::effectiveTrueColorDepth("auto", "quality",
        5ULL * 1024ULL * 1024ULL), 32);

    const std::vector<uint8_t> format16 = VncRfbProtocol::buildSetPixelFormat(16);
    RDP_ASSERT_EQ(format16.size(), static_cast<size_t>(20));
    RDP_ASSERT_EQ(format16[0], static_cast<uint8_t>(0));
    RDP_ASSERT_EQ(format16[4], static_cast<uint8_t>(16));
    RDP_ASSERT_EQ(format16[5], static_cast<uint8_t>(16));
    RDP_ASSERT_EQ(format16[9], static_cast<uint8_t>(31));
    RDP_ASSERT_EQ(format16[11], static_cast<uint8_t>(63));
    RDP_ASSERT_EQ(format16[14], static_cast<uint8_t>(11));
}

RDP_TEST_CASE(vnc_frame_request_rate_policy_is_deterministic) {
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeFrameRateLimit(0), 0);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeFrameRateLimit(15), 15);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeFrameRateLimit(60), 60);
    RDP_ASSERT_EQ(VncRfbProtocol::normalizeFrameRateLimit(37), 30);
    RDP_ASSERT_EQ(VncRfbProtocol::framebufferRequestIntervalMs(0), static_cast<uint64_t>(0));
    RDP_ASSERT_EQ(VncRfbProtocol::framebufferRequestIntervalMs(15), static_cast<uint64_t>(67));
    RDP_ASSERT_EQ(VncRfbProtocol::framebufferRequestIntervalMs(30), static_cast<uint64_t>(34));
    RDP_ASSERT_EQ(VncRfbProtocol::framebufferRequestIntervalMs(60), static_cast<uint64_t>(17));
}

RDP_TEST_CASE(vnc_ultravnc_mode12_field_is_exactly_250_bytes) {
    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> field = {0};
    std::string error;
    RDP_ASSERT(VncRfbProtocol::buildRepeaterTargetField("1234", field, error));
    RDP_ASSERT_EQ(field[0], static_cast<uint8_t>('I'));
    RDP_ASSERT_EQ(field[1], static_cast<uint8_t>('D'));
    RDP_ASSERT_EQ(field[2], static_cast<uint8_t>(':'));
    RDP_ASSERT_EQ(field[3], static_cast<uint8_t>('1'));
    RDP_ASSERT_EQ(field[6], static_cast<uint8_t>('4'));
    RDP_ASSERT_EQ(field[7], static_cast<uint8_t>(0));
    RDP_ASSERT_EQ(field.size(), VncRfbProtocol::kUltraVncRepeaterFieldBytes);

    std::string target;
    RDP_ASSERT(VncRfbProtocol::parseRepeaterTargetField(field.data(), field.size(), target, error));
    RDP_ASSERT(target == "1234");
}

RDP_TEST_CASE(vnc_ultravnc_mode2_fixture_uses_same_server_field_contract) {
    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> field = {0};
    std::string error;
    // Mode2 is the repeater's server-side listener. Its fixed field is still
    // covered here as a byte fixture, while the viewer transport rejects it.
    RDP_ASSERT(VncRfbProtocol::buildRepeaterTargetField("ID-42", field, error));
    RDP_ASSERT(vncNativeRepeaterViewerModeIsAvailable("mode12"));
    RDP_ASSERT(!vncNativeRepeaterViewerModeIsAvailable("mode2"));
}

RDP_TEST_CASE(vnc_ultravnc_banner_and_short_or_invalid_fields_fail_closed) {
    static constexpr char banner[] = "RFB 000.000\n";
    RDP_ASSERT(VncRfbProtocol::isUltraVncRepeaterBanner(
        reinterpret_cast<const uint8_t*>(banner), VncRfbProtocol::kProtocolVersionBytes));
    static constexpr char wrongBanner[] = "RFB 003.008\n";
    RDP_ASSERT(!VncRfbProtocol::isUltraVncRepeaterBanner(
        reinterpret_cast<const uint8_t*>(wrongBanner), VncRfbProtocol::kProtocolVersionBytes));

    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> field = {0};
    std::string error;
    std::string target;
    RDP_ASSERT(!VncRfbProtocol::parseRepeaterTargetField(field.data(), field.size() - 1,
                                                         target, error));
    field[0] = 'I';
    field[1] = 'D';
    field[2] = ':';
    field[3] = '1';
    field[8] = 'x';
    RDP_ASSERT(!VncRfbProtocol::parseRepeaterTargetField(field.data(), field.size(), target, error));
}

RDP_TEST_CASE(vnc_ultravnc_target_validation_rejects_empty_control_and_overflow) {
    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> field = {0};
    std::string error;
    RDP_ASSERT(!VncRfbProtocol::buildRepeaterTargetField("", field, error));
    RDP_ASSERT(!VncRfbProtocol::buildRepeaterTargetField("bad\nID", field, error));
    RDP_ASSERT(!VncRfbProtocol::buildRepeaterTargetField(
        std::string(VncRfbProtocol::kUltraVncRepeaterFieldBytes - 2, 'x'), field, error));
}
