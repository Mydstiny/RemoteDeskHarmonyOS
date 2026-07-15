#include "test_runner.h"
#include "rdp/rdp_graphics_lifecycle.h"

RDP_TEST_CASE(rdp_graphics_lifecycle_resize_is_transactional) {
    RdpGraphicsLifecycle lifecycle;
    lifecycle.reset(1920, 1080, true);

    const RdpResizeTicket ticket = lifecycle.beginResize(2560, 1440);
    RDP_ASSERT(ticket.accepted);
    RDP_ASSERT_EQ(ticket.epoch, 1ULL);
    RDP_ASSERT(!lifecycle.snapshot().presentationAllowed);

    lifecycle.completeResize(ticket.epoch, true);
    const RdpGraphicsLifecycleSnapshot snapshot = lifecycle.snapshot();
    RDP_ASSERT(snapshot.presentationAllowed);
    RDP_ASSERT_EQ(snapshot.desktopWidth, 2560);
    RDP_ASSERT_EQ(snapshot.desktopHeight, 1440);
    RDP_ASSERT_EQ(snapshot.resizeCount, 1ULL);
    RDP_ASSERT_EQ(snapshot.resizeFailures, 0ULL);
}

RDP_TEST_CASE(rdp_graphics_lifecycle_rejects_invalid_or_overlapping_resize) {
    RdpGraphicsLifecycle lifecycle;
    lifecycle.reset(1920, 1080, false);

    RDP_ASSERT(!lifecycle.beginResize(0, 1080).accepted);
    const RdpResizeTicket first = lifecycle.beginResize(1280, 720);
    RDP_ASSERT(first.accepted);
    RDP_ASSERT(!lifecycle.beginResize(1024, 768).accepted);

    lifecycle.completeResize(first.epoch, false);
    const RdpGraphicsLifecycleSnapshot snapshot = lifecycle.snapshot();
    RDP_ASSERT(!snapshot.presentationAllowed);
    RDP_ASSERT_EQ(snapshot.desktopWidth, 1920);
    RDP_ASSERT_EQ(snapshot.desktopHeight, 1080);
    RDP_ASSERT_EQ(snapshot.resizeFailures, 1ULL);
}

RDP_TEST_CASE(rdp_graphics_lifecycle_reset_invalidates_stale_resize_ticket) {
    RdpGraphicsLifecycle lifecycle;
    lifecycle.reset(1920, 1080, true);

    const RdpResizeTicket stale = lifecycle.beginResize(2560, 1440);
    RDP_ASSERT(stale.accepted);

    lifecycle.reset(1280, 720, false);
    const RdpResizeTicket current = lifecycle.beginResize(1600, 900);
    RDP_ASSERT(current.accepted);
    RDP_ASSERT(stale.epoch != current.epoch);
    RDP_ASSERT(!lifecycle.completeResize(stale.epoch, true));

    const RdpGraphicsLifecycleSnapshot pending = lifecycle.snapshot();
    RDP_ASSERT(pending.resizeInProgress);
    RDP_ASSERT(!pending.presentationAllowed);
    RDP_ASSERT_EQ(pending.desktopWidth, 1280);
    RDP_ASSERT_EQ(pending.desktopHeight, 720);

    RDP_ASSERT(lifecycle.completeResize(current.epoch, true));
    const RdpGraphicsLifecycleSnapshot completed = lifecycle.snapshot();
    RDP_ASSERT(completed.presentationAllowed);
    RDP_ASSERT_EQ(completed.desktopWidth, 1600);
    RDP_ASSERT_EQ(completed.desktopHeight, 900);
    RDP_ASSERT_EQ(completed.resizeCount, 1ULL);
}

RDP_TEST_CASE(rdp_graphics_lifecycle_ignores_duplicate_and_stale_channel_events) {
    RdpGraphicsLifecycle lifecycle;
    lifecycle.reset(1920, 1080, true);

    RDP_ASSERT_EQ(lifecycle.onChannelConnected(0x1234),
                  RdpGfxChannelAction::Initialize);
    lifecycle.completeChannelInitialization(0x1234, true);
    RDP_ASSERT_EQ(lifecycle.onChannelConnected(0x1234),
                  RdpGfxChannelAction::Ignore);
    RDP_ASSERT_EQ(lifecycle.onChannelConnected(0x5678),
                  RdpGfxChannelAction::Reject);
    RDP_ASSERT_EQ(lifecycle.onChannelDisconnected(0x5678),
                  RdpGfxChannelAction::Ignore);
    RDP_ASSERT_EQ(lifecycle.onChannelDisconnected(0x1234),
                  RdpGfxChannelAction::Release);
    RDP_ASSERT_EQ(lifecycle.onChannelDisconnected(0x1234),
                  RdpGfxChannelAction::Ignore);
}

RDP_TEST_CASE(rdp_graphics_fallback_latch_applies_to_one_next_connection) {
    RdpNextConnectionGfxFallback fallback;
    RDP_ASSERT(!fallback.pending());
    RDP_ASSERT(!fallback.consume());

    fallback.mark();
    RDP_ASSERT(fallback.pending());
    RDP_ASSERT(fallback.consume());
    RDP_ASSERT(!fallback.pending());
    RDP_ASSERT(!fallback.consume());
}
