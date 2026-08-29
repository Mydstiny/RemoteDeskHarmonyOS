#include "test_runner.h"
#include "rdp/rdp_display_layout_policy.h"

namespace {
RdpDisplayLayoutRequest ValidLayout() {
    RdpDisplayLayoutRequest request;
    request.width = 2560;
    request.height = 1600;
    request.physicalWidthMm = 286;
    request.physicalHeightMm = 179;
    request.orientation = 0;
    request.desktopScaleFactor = 180;
    request.deviceScaleFactor = 180;
    return request;
}
}

RDP_TEST_CASE(rdp_display_layout_policy_accepts_hidpi_single_monitor_layout) {
    const RdpDisplayLayoutResult result = RdpDisplayLayoutPolicy::Validate(ValidLayout());
    RDP_ASSERT(result.accepted);
    RDP_ASSERT(result.code == "accepted");
}

RDP_TEST_CASE(rdp_display_layout_policy_rejects_odd_width) {
    RdpDisplayLayoutRequest request = ValidLayout();
    request.width = 2559;
    RDP_ASSERT(!RdpDisplayLayoutPolicy::Validate(request).accepted);
}

RDP_TEST_CASE(rdp_display_layout_policy_rejects_unknown_scale) {
    RdpDisplayLayoutRequest request = ValidLayout();
    request.desktopScaleFactor = 125;
    RDP_ASSERT(RdpDisplayLayoutPolicy::Validate(request).code == "invalid_scale");
}

RDP_TEST_CASE(rdp_display_layout_policy_accepts_portrait_orientation) {
    RdpDisplayLayoutRequest request = ValidLayout();
    request.width = 1600;
    request.height = 2560;
    request.orientation = 90;
    RDP_ASSERT(RdpDisplayLayoutPolicy::Validate(request).accepted);
}

RDP_TEST_CASE(rdp_display_layout_policy_accepts_unknown_physical_size) {
    RdpDisplayLayoutRequest request = ValidLayout();
    request.physicalWidthMm = 0;
    request.physicalHeightMm = 0;
    RDP_ASSERT(RdpDisplayLayoutPolicy::Validate(request).accepted);
}

RDP_TEST_CASE(rdp_display_layout_policy_rejects_partial_physical_size) {
    RdpDisplayLayoutRequest request = ValidLayout();
    request.physicalHeightMm = 0;
    RDP_ASSERT(RdpDisplayLayoutPolicy::Validate(request).code == "invalid_physical_size");
}

RDP_TEST_CASE(rdp_display_layout_policy_enforces_negotiated_area_caps) {
    const RdpDisplayLayoutRequest request = ValidLayout();
    RDP_ASSERT(RdpDisplayLayoutPolicy::IsWithinServerAreaCaps(request, 3840, 2160));
    RDP_ASSERT(!RdpDisplayLayoutPolicy::IsWithinServerAreaCaps(request, 1920, 1080));
    RDP_ASSERT(!RdpDisplayLayoutPolicy::IsWithinServerAreaCaps(request, 0, 8192));
}

RDP_TEST_CASE(rdp_display_layout_policy_serializes_and_rate_limits_requests) {
    constexpr int64_t firstSendUs = 1000000;
    RDP_ASSERT(RdpDisplayLayoutPolicy::IsSendDue(true, false, 0, firstSendUs));
    RDP_ASSERT(!RdpDisplayLayoutPolicy::IsSendDue(
        true, true, firstSendUs, firstSendUs + 600000));
    RDP_ASSERT(!RdpDisplayLayoutPolicy::IsSendDue(
        true, false, firstSendUs, firstSendUs + 499999));
    RDP_ASSERT(RdpDisplayLayoutPolicy::IsSendDue(
        true, false, firstSendUs, firstSendUs + 500000));
}

RDP_TEST_CASE(rdp_display_layout_policy_bounds_an_unacknowledged_request) {
    constexpr int64_t sentUs = 1000000;
    RDP_ASSERT(!RdpDisplayLayoutPolicy::HasInFlightTimedOut(
        true, sentUs, sentUs + 4999999));
    RDP_ASSERT(RdpDisplayLayoutPolicy::HasInFlightTimedOut(
        true, sentUs, sentUs + 5000000));
    RDP_ASSERT(!RdpDisplayLayoutPolicy::HasInFlightTimedOut(
        false, sentUs, sentUs + 5000000));
}

RDP_TEST_CASE(rdp_display_layout_policy_ignores_stale_channel_disconnect) {
    int oldChannel = 0;
    int currentChannel = 0;
    RDP_ASSERT(!RdpDisplayLayoutPolicy::ShouldDetachDisplayChannel(
        &currentChannel, &oldChannel));
    RDP_ASSERT(RdpDisplayLayoutPolicy::ShouldDetachDisplayChannel(
        &currentChannel, &currentChannel));
    RDP_ASSERT(!RdpDisplayLayoutPolicy::ShouldDetachDisplayChannel(
        nullptr, &oldChannel));
}
