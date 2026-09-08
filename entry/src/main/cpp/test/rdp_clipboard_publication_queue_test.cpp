#include "rdp/rdp_clipboard_publication_queue.h"
#include "test_runner.h"

RDP_TEST_CASE(rdp_publication_only_matching_serial_ack_confirms_latest_value) {
    RdpClipboardPublicationQueue queue;
    const auto first = queue.enqueue({0, false, "first", {}});
    RDP_ASSERT_EQ(queue.takeNext()->id, first);
    const auto second = queue.enqueue({0, false, "second", {}});
    RDP_ASSERT_EQ(queue.state(first), 3);
    RDP_ASSERT(!queue.takeNext());
    queue.acknowledge(true);
    RDP_ASSERT_EQ(queue.state(second), 1);
    RDP_ASSERT_EQ(queue.takeNext()->id, second);
    queue.acknowledge(true);
    RDP_ASSERT_EQ(queue.state(second), 2);
}
RDP_TEST_CASE(rdp_publication_timeout_retains_unidentified_ack_barrier) {
    RdpClipboardPublicationQueue queue;
    const auto now = RdpClipboardPublicationQueue::Clock::now();
    const auto first = queue.enqueue({}, now);
    queue.takeNext(now);
    RDP_ASSERT_EQ(queue.state(first, now + std::chrono::seconds(16)), 3);
    const auto second = queue.enqueue({}, now + std::chrono::seconds(17));
    RDP_ASSERT(!queue.takeNext(now + std::chrono::seconds(18)));
    queue.acknowledge(true, now + std::chrono::seconds(18));
    RDP_ASSERT_EQ(queue.state(first), 3);
    RDP_ASSERT_EQ(queue.state(second), 1);
    RDP_ASSERT_EQ(queue.takeNext(now + std::chrono::seconds(18))->id, second);
}
RDP_TEST_CASE(rdp_publication_disable_and_remote_copy_drain_before_next_offer) {
    RdpClipboardPublicationQueue queue;
    const auto first = queue.enqueue({}); queue.takeNext();
    queue.invalidate();
    const auto second = queue.enqueue({});
    RDP_ASSERT(!queue.takeNext());
    queue.acknowledge(true);
    RDP_ASSERT_EQ(queue.state(first), 3);
    RDP_ASSERT_EQ(queue.state(second), 1);
    RDP_ASSERT_EQ(queue.takeNext()->id, second);
    queue.acknowledge(false);
    RDP_ASSERT_EQ(queue.state(second), 3);
}
RDP_TEST_CASE(rdp_publication_reconnect_releases_barrier_without_reusing_receipt) {
    RdpClipboardPublicationQueue queue;
    const auto first = queue.enqueue({}); queue.takeNext(); queue.invalidate(true);
    const auto second = queue.enqueue({});
    RDP_ASSERT(second > first);
    RDP_ASSERT_EQ(queue.takeNext()->id, second);
    RDP_ASSERT_EQ(queue.state(first), 3);
    RDP_ASSERT_EQ(queue.state(9999), 0);
}
RDP_TEST_CASE(rdp_publication_failed_write_does_not_allow_late_ack_to_confirm_successor) {
    RdpClipboardPublicationQueue queue;
    const auto first = queue.enqueue({}); queue.takeNext(); queue.sendFailed(first, true);
    const auto second = queue.enqueue({});
    RDP_ASSERT(!queue.takeNext());
    queue.acknowledge(true);
    RDP_ASSERT_EQ(queue.state(first), 3);
    RDP_ASSERT_EQ(queue.state(second), 1);
    RDP_ASSERT_EQ(queue.takeNext()->id, second);
}
RDP_TEST_CASE(rdp_publication_keeps_only_latest_queued_payload_without_replacing_inflight) {
    RdpClipboardPublicationQueue queue;
    const auto first = queue.enqueue({0, true, {}, {"/first"}});
    const auto inFlight = queue.takeNext();
    const auto second = queue.enqueue({0, false, "second", {}});
    const auto third = queue.enqueue({0, false, "third", {}});
    RDP_ASSERT(inFlight->files && inFlight->paths[0] == "/first");
    RDP_ASSERT_EQ(queue.state(first), 3);
    RDP_ASSERT_EQ(queue.state(second), 3);
    queue.acknowledge(true);
    const auto next = queue.takeNext();
    RDP_ASSERT_EQ(next->id, third);
    RDP_ASSERT(next->text == "third");
    queue.acknowledge(true);
    RDP_ASSERT_EQ(queue.state(third), 2);
    queue.enqueue({});
    RDP_ASSERT_EQ(queue.state(third), 3);
}
