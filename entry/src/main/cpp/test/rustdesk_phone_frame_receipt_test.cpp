#include "test_runner.h"
#include "render/phone_frame_receipt.h"
#include "render/frame_callback_gate.h"
#include "rustdesk/rustdesk_phone_geometry_gate.h"

namespace {
struct PhonePresentationHarness {
    RustDeskPhoneGeometryGate geometry;
    uint64_t stream = 10;
    int receipts = 0;

    PhonePresentationHarness() { geometry.reset(true); }
    Render::PhoneFrameReceiptPtr input(uint32_t epoch, int width, int height, uint64_t pts = 0) {
        auto receipt = std::make_shared<Render::PhoneFrameReceipt>();
        receipt->identity = {1, 2, 3, stream, epoch, 0, width, height};
        receipt->originalTimestamp = pts;
        receipt->didPresent = [this](const Render::PhoneFrameIdentity& frame, int w, int h) {
            if (frame.streamEpoch != stream) return;
            ++receipts;
            geometry.observePresented(frame.geometryEpoch, frame.display, frame.width, frame.height, w, h);
        };
        return receipt;
    }
    void change(uint32_t epoch, int width, int height) {
        geometry.observeDisplay(0, epoch, width, height);
        geometry.observeFrame(0, width, height);
    }
};
}

RDP_TEST_CASE(phone_pts_are_unique_even_when_remote_pts_are_zero_or_duplicate) {
    PhonePresentationHarness h;
    Render::PhoneFrameTracker tracker;
    const auto zero = h.input(1, 1080, 2400, 0);
    const int64_t a = tracker.submit(zero), b = tracker.submit(zero);
    const int64_t c = tracker.submit(h.input(1, 1080, 2400, 1));
    RDP_ASSERT(a > 0 && b > a && c > b);
    RDP_ASSERT_EQ(zero->originalTimestamp, 0U);
    RDP_ASSERT_EQ(tracker.submit({}), 0);
    RDP_ASSERT_EQ(tracker.pendingCount(), 3U);
}

RDP_TEST_CASE(phone_output_receipt_requires_exact_decoded_pts_and_actual_texture) {
    PhonePresentationHarness h;
    Render::PhoneFrameTracker tracker;
    const int64_t a = tracker.submit(h.input(1, 1080, 2400));
    const int64_t b = tracker.submit(h.input(2, 540, 1200));
    RDP_ASSERT(!tracker.takeDecoded(b)); // Encoded ingress is insufficient.
    tracker.decoded(b); // Decoder output reordered / NativeImage picked newer frame.
    RDP_ASSERT(!tracker.takeDecoded(a));
    RDP_ASSERT(!tracker.takeDecoded(b * 1000)); // Never guess timestamp units.
    const auto frame = tracker.takeDecoded(b);
    RDP_ASSERT(frame && frame->token() == b);
    RDP_ASSERT(!tracker.takeDecoded(b)); // Repeated notification is not another output.
    tracker.decoded(a);
    RDP_ASSERT(tracker.takeDecoded(a)); // Old output retains its own identity.
}

RDP_TEST_CASE(phone_same_aspect_resize_rejects_old_texture_until_matching_output_is_presented) {
    PhonePresentationHarness h;
    Render::PhoneFrameTracker tracker;
    h.change(1, 1080, 2400);
    const int64_t oldToken = tracker.submit(h.input(1, 1080, 2400));
    tracker.decoded(oldToken);
    const auto oldFrame = tracker.takeDecoded(oldToken);
    RDP_ASSERT(oldFrame->presented(1080, 2400));
    RDP_ASSERT(h.geometry.commit(1));

    h.change(2, 540, 1200);
    const int64_t nextToken = tracker.submit(h.input(2, 540, 1200));
    oldFrame->presented(1080, 2400); // Retained draw after new encoded ingress.
    RDP_ASSERT(!h.geometry.commit(2));
    tracker.decoded(nextToken);
    RDP_ASSERT(!tracker.takeDecoded(oldToken)); // Update selected the old buffer.
    RDP_ASSERT(!h.geometry.commit(2));
    const auto nextFrame = tracker.takeDecoded(nextToken);
    nextFrame->presented(540, 1200);
    RDP_ASSERT(h.geometry.commit(2));
}

RDP_TEST_CASE(phone_rotation_back_to_old_size_cannot_reuse_old_epoch_receipt) {
    PhonePresentationHarness h;
    Render::PhoneFrameTracker tracker;
    h.change(1, 1080, 2400);
    const int64_t first = tracker.submit(h.input(1, 1080, 2400));
    tracker.decoded(first);
    const auto old = tracker.takeDecoded(first);
    old->presented(1080, 2400);
    RDP_ASSERT(h.geometry.commit(1));
    h.change(2, 2400, 1080);
    h.change(3, 1080, 2400);
    old->presented(1080, 2400);
    RDP_ASSERT(!h.geometry.commit(3));
    const int64_t latest = tracker.submit(h.input(3, 1080, 2400));
    tracker.decoded(latest);
    tracker.takeDecoded(latest)->presented(540, 1200); // Same identity, software downsample.
    RDP_ASSERT(h.geometry.commit(3));
}

RDP_TEST_CASE(phone_frame_before_geometry_has_no_epoch_until_a_matching_ingress) {
    PhonePresentationHarness h;
    Render::PhoneFrameTracker tracker;
    h.geometry.observeFrame(0, 1080, 2400);
    RDP_ASSERT_EQ(h.geometry.epochForFrame(0, 1080, 2400), 0U);
    const int64_t early = tracker.submit(h.input(0, 1080, 2400));
    tracker.decoded(early);
    const auto earlyFrame = tracker.takeDecoded(early);
    h.geometry.observeDisplay(0, 1, 1080, 2400);
    RDP_ASSERT(!earlyFrame->presented(1080, 2400));
    RDP_ASSERT(!h.geometry.commit(1));
    RDP_ASSERT_EQ(h.geometry.epochForFrame(0, 1080, 2400), 1U);
}

RDP_TEST_CASE(phone_rebind_invalidates_pending_and_retained_receipts_without_reusing_tokens) {
    PhonePresentationHarness h;
    Render::PhoneFrameTracker tracker;
    const int64_t a = tracker.submit(h.input(1, 1080, 2400));
    const int64_t b = tracker.submit(h.input(1, 1080, 2400));
    tracker.decoded(a);
    const auto retained = tracker.takeDecoded(a);
    tracker.clear();
    RDP_ASSERT(!retained->presented(1080, 2400));
    tracker.decoded(b);
    RDP_ASSERT(!tracker.takeDecoded(b));
    const int64_t next = tracker.submit(h.input(1, 1080, 2400));
    RDP_ASSERT(next > b);
    RDP_ASSERT_EQ(h.receipts, 0);
}

RDP_TEST_CASE(phone_tracker_destruction_invalidates_a_retained_ticket) {
    PhonePresentationHarness h;
    Render::PhoneDecodedFramePtr retained;
    {
        Render::PhoneFrameTracker tracker;
        const int64_t token = tracker.submit(h.input(1, 1080, 2400));
        tracker.decoded(token);
        retained = tracker.takeDecoded(token);
    }
    RDP_ASSERT(!retained->presented(1080, 2400));
    RDP_ASSERT_EQ(h.receipts, 0);
}

RDP_TEST_CASE(phone_capacity_evicts_evidence_only_and_never_relabels_an_old_output) {
    PhonePresentationHarness h;
    Render::PhoneFrameTracker tracker;
    const int64_t first = tracker.submit(h.input(1, 1080, 2400));
    int64_t last = first;
    for (size_t i = 0; i < Render::PhoneFrameTracker::kCapacity + 20; ++i)
        last = tracker.submit(h.input(2, 540, 1200));
    RDP_ASSERT_EQ(tracker.pendingCount(), Render::PhoneFrameTracker::kCapacity);
    tracker.decoded(first);
    RDP_ASSERT(!tracker.takeDecoded(first));
    tracker.decoded(last);
    RDP_ASSERT(tracker.takeDecoded(last));
}

RDP_TEST_CASE(phone_callback_absence_and_failed_swap_do_not_acknowledge_a_frame) {
    PhonePresentationHarness h;
    h.change(1, 1080, 2400);
    Render::PhoneFrameTracker tracker;
    const int64_t token = tracker.submit(h.input(1, 1080, 2400));
    tracker.decoded(token);
    const auto frame = tracker.takeDecoded(token);
    SoftwareDecoderFrameCallbackGate callback;
    callback.Invoke(nullptr, 0, 1080, 2400, 0, frame);
    RDP_ASSERT_EQ(h.receipts, 0);
    bool swapSucceeded = false;
    callback.Set([&](const uint8_t*, size_t, int w, int height, int,
                     const Render::PhoneDecodedFramePtr& actual) {
        if (swapSucceeded && actual) actual->presented(w, height);
        return swapSucceeded ? 0 : -1;
    });
    RDP_ASSERT_EQ(callback.Invoke(nullptr, 0, 1080, 2400, 0, frame), -1);
    RDP_ASSERT(!h.geometry.commit(1));
    swapSucceeded = true;
    RDP_ASSERT_EQ(callback.Invoke(nullptr, 0, 1080, 2400, 0, frame), 0);
    RDP_ASSERT(h.geometry.commit(1));
}

RDP_TEST_CASE(phone_stream_replacement_rejects_old_frame_even_when_geometry_epoch_repeats) {
    PhonePresentationHarness h;
    Render::PhoneFrameTracker tracker;
    h.change(1, 1080, 2400);
    const int64_t token = tracker.submit(h.input(1, 1080, 2400));
    tracker.decoded(token);
    const auto oldFrame = tracker.takeDecoded(token);
    ++h.stream;
    h.geometry.reset(true);
    h.change(1, 1080, 2400);
    oldFrame->presented(1080, 2400);
    RDP_ASSERT(!h.geometry.commit(1));
    RDP_ASSERT_EQ(h.receipts, 0);
}
