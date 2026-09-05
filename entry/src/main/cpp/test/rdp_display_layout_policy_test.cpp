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

RDP_TEST_CASE(rdp_display_layout_policy_fail_closes_timeout_before_follow_up_send) {
    constexpr int64_t sentUs = 1000000;
    const auto resolution = RdpDisplayLayoutPolicy::ResolveInFlightTimeout(
        true, true, false, sentUs,
        sentUs + RdpDisplayLayoutPolicy::kInFlightTimeoutUs);

    RDP_ASSERT(resolution.timedOut);
    RDP_ASSERT(!resolution.layoutPending);
    RDP_ASSERT(!resolution.layoutInFlight);
    RDP_ASSERT(resolution.displayControlDisabled);
    RDP_ASSERT(!RdpDisplayLayoutPolicy::IsSendDue(
        resolution.layoutPending, resolution.layoutInFlight,
        sentUs, sentUs + RdpDisplayLayoutPolicy::kInFlightTimeoutUs));
    // A late DesktopResize cannot be accepted as completion of the discarded
    // follow-up B once the uncorrelatable channel generation is disabled.
    RDP_ASSERT(!RdpDisplayLayoutPolicy::ShouldResolveResizeAsRequest(
        resolution.layoutInFlight, resolution.displayControlDisabled));
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

RDP_TEST_CASE(rdp_display_layout_policy_keeps_follow_up_resize_queued) {
    // A completed 2560x1600 while a newer 2880x1800 request occupies the
    // coalesced pending slot must not publish "server_adjusted" for B.
    RDP_ASSERT(RdpDisplayLayoutPolicy::ResolveCompletedRequestStatus(
        true, 2880, 1800, 2560, 1600) == "queued");
    RDP_ASSERT(RdpDisplayLayoutPolicy::ResolveCompletedRequestStatus(
        false, 2880, 1800, 2880, 1800) == "applied");
    RDP_ASSERT(RdpDisplayLayoutPolicy::ResolveCompletedRequestStatus(
        false, 2880, 1800, 2560, 1600) == "server_adjusted");
}

RDP_TEST_CASE(rdp_display_layout_policy_preserves_an_in_flight_request_when_follow_up_is_cancelled) {
    RDP_ASSERT(RdpDisplayLayoutPolicy::ResolveCancelledRequestStatus(true) == "sent");
    RDP_ASSERT(RdpDisplayLayoutPolicy::ResolveCancelledRequestStatus(false) == "cancelled");

    const auto active =
        RdpDisplayLayoutPolicy::ResolveRequestedGeometryAfterPendingCancellation(
            true, 2880, 1800, 2560, 1600);
    RDP_ASSERT(active.width == 2560);
    RDP_ASSERT(active.height == 1600);

    const auto idle =
        RdpDisplayLayoutPolicy::ResolveRequestedGeometryAfterPendingCancellation(
            false, 2880, 1800, 0, 0);
    RDP_ASSERT(idle.width == 2880);
    RDP_ASSERT(idle.height == 1800);
}
