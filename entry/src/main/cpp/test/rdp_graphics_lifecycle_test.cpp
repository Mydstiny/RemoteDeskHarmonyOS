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

RDP_TEST_CASE(rdp_graphics_lifecycle_reconciles_server_adjusted_initial_geometry) {
    RdpGraphicsLifecycle lifecycle;
    lifecycle.reset(1600, 1000, true);

    RDP_ASSERT(lifecycle.reconcileInitialDesktopSize(2880, 1800));
    const RdpGraphicsLifecycleSnapshot reconciled = lifecycle.snapshot();
    RDP_ASSERT_EQ(reconciled.epoch, 0ULL);
    RDP_ASSERT_EQ(reconciled.desktopWidth, 2880);
    RDP_ASSERT_EQ(reconciled.desktopHeight, 1800);
    RDP_ASSERT(reconciled.presentationAllowed);

    const RdpResizeTicket resize = lifecycle.beginResize(2560, 1600);
    RDP_ASSERT(resize.accepted);
    RDP_ASSERT(!lifecycle.reconcileInitialDesktopSize(1920, 1080));
    lifecycle.completeResize(resize.epoch, true);
    RDP_ASSERT(!lifecycle.reconcileInitialDesktopSize(1920, 1080));
}

RDP_TEST_CASE(rdp_renderer_geometry_replay_wins_after_late_decoder_bind) {
    RdpGraphicsLifecycle lifecycle;
    lifecycle.reset(1600, 1000, true);
    RDP_ASSERT(lifecycle.reconcileInitialDesktopSize(2880, 1800));

    // PostConnect may publish 2880x1800 first and a later decoder bind may
    // temporarily overwrite the renderer with its cold-start 1600x1000.
    int rendererWidth = 2880;
    int rendererHeight = 1800;
    rendererWidth = 1600;
    rendererHeight = 1000;
    const RdpRendererGeometryReplay initialReplay =
        ResolveRdpRendererGeometryReplay(lifecycle.snapshot());
    RDP_ASSERT(initialReplay.ready);
    rendererWidth = initialReplay.width;
    rendererHeight = initialReplay.height;
    RDP_ASSERT_EQ(rendererWidth, 2880);
    RDP_ASSERT_EQ(rendererHeight, 1800);

    const RdpResizeTicket resize = lifecycle.beginResize(2560, 1600);
    RDP_ASSERT(resize.accepted);
    RDP_ASSERT(!ResolveRdpRendererGeometryReplay(lifecycle.snapshot()).ready);
    lifecycle.completeResize(resize.epoch, true);

    // Foreground rebind repeats the decoder's original dimensions; replaying
    // the live adapter geometry restores the completed Display Control size.
    rendererWidth = 1600;
    rendererHeight = 1000;
    const RdpRendererGeometryReplay restoreReplay =
        ResolveRdpRendererGeometryReplay(lifecycle.snapshot());
    RDP_ASSERT(restoreReplay.ready);
    rendererWidth = restoreReplay.width;
    rendererHeight = restoreReplay.height;
    RDP_ASSERT_EQ(rendererWidth, 2560);
    RDP_ASSERT_EQ(rendererHeight, 1600);
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
