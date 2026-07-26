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
