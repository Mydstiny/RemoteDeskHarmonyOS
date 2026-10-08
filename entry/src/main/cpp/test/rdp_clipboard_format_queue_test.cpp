#include "rdp/rdp_clipboard_format_queue.h"
#include "rdp/rdp_clipboard_state.h"
#include "rdp/rdp_clipboard_publication_queue.h"
#include "test_runner.h"
#include <thread>
RDP_TEST_CASE(rdp_rich_offer_change_rejects_stale_responses) {
    RdpClipboardFormatQueue queue;queue.offer({1,{{RdpClipboardFormat::Html,901}}});
    const auto id=queue.request(1,RdpClipboardFormat::Html);RDP_ASSERT(id);
    queue.offer({2,{{RdpClipboardFormat::Html,902}}});std::vector<uint8_t> bytes;RdpClipboardContentCodec::encodeHtml("old",bytes);
    queue.response(id,true,bytes.data(),bytes.size());RDP_ASSERT(queue.result(id).state=="stale");RDP_ASSERT(!queue.result(id).content.htmlUtf8);
    RDP_ASSERT_EQ(queue.request(1,RdpClipboardFormat::Html),0U);RDP_ASSERT_EQ(queue.request(2,RdpClipboardFormat::Png),0U);
}
RDP_TEST_CASE(rdp_rich_release_inflight_preserves_lane_tombstone_and_progress) {
    RdpClipboardState lane;lane.formatList(false,false,false,true);const auto seq=lane.snapshot().sequence;
    RdpClipboardFormatQueue queue;queue.offer({seq,{{RdpClipboardFormat::Html,901},{RdpClipboardFormat::Rtf,902}}});
    const auto first=queue.request(seq,RdpClipboardFormat::Html);RDP_ASSERT(lane.requestRich(seq,901,first));
    RDP_ASSERT(queue.release(first));lane.cancelQueuedRichRequest(first);
    const auto second=queue.request(seq,RdpClipboardFormat::Rtf);RDP_ASSERT(lane.requestRich(seq,902,second));
    RDP_ASSERT_EQ(lane.pendingRequest().richRequestId,first);queue.response(first,true,nullptr,0);
    RDP_ASSERT_EQ(lane.response(false,""),seq);RDP_ASSERT_EQ(lane.pendingRequest().richRequestId,second);
    RDP_ASSERT(queue.result(first).state=="unavailable");
}
RDP_TEST_CASE(rdp_rich_timeout_does_not_allow_untagged_response_reassignment) {
    using Clock=RdpClipboardFormatQueue::Clock;const auto now=Clock::now();
    RdpClipboardState lane;lane.formatList(false,false,false,true);const auto seq=lane.snapshot().sequence;
    RdpClipboardFormatQueue queue;queue.offer({seq,{{RdpClipboardFormat::Html,901}}});
    const auto old=queue.request(seq,RdpClipboardFormat::Html,now);lane.requestRich(seq,901,old);
    RDP_ASSERT(queue.result(old,now+std::chrono::seconds(16)).state=="timeout");
    const auto latest=queue.request(seq,RdpClipboardFormat::Html,now+std::chrono::seconds(16));lane.requestRich(seq,901,latest);
    RDP_ASSERT_EQ(lane.pendingRequest().richRequestId,old);lane.response(false,"");RDP_ASSERT_EQ(lane.pendingRequest().richRequestId,latest);
    queue.response(old,true,nullptr,0);RDP_ASSERT(queue.result(latest).state=="loading");
}
RDP_TEST_CASE(rdp_rich_text_files_and_rich_share_exactly_one_lane) {
    RdpClipboardState lane;lane.formatList(true,false,false);const auto old=lane.pendingRequest().sequence;
    lane.formatList(true,true,false,true);const auto seq=lane.snapshot().sequence;
    RDP_ASSERT(lane.requestFiles(seq,800));RDP_ASSERT(lane.requestRich(seq,900,44));RDP_ASSERT_EQ(lane.pendingRequest().sequence,old);
    lane.response(true,"old text");RDP_ASSERT(lane.pendingRequest().files);
    lane.response(false,"");RDP_ASSERT_EQ(lane.pendingRequest().richRequestId,44U);
    lane.invalidate();lane.response(false,"");RDP_ASSERT_EQ(lane.pendingRequest().sequence,0U);
}
RDP_TEST_CASE(rdp_rich_failed_send_and_disable_drain_until_new_carrier) {
    RdpClipboardState lane;lane.formatList(false,false,false,true);auto seq=lane.snapshot().sequence;
    lane.requestRich(seq,800,1);lane.requestFailed(seq);RDP_ASSERT_EQ(lane.pendingRequest().richRequestId,1U);
    lane.invalidate();RDP_ASSERT_EQ(lane.pendingRequest().richRequestId,1U);
    lane.invalidate(true);RDP_ASSERT_EQ(lane.pendingRequest().richRequestId,0U);
}
RDP_TEST_CASE(rdp_rich_concurrent_publications_still_use_single_ack) {
    RdpClipboardPublicationQueue queue;
    auto publish=[&](){RdpClipboardPublicationQueue::Job job;RdpClipboardContent value;value.textUtf8="fallback";value.htmlUtf8="<b>rich</b>";
        RDP_ASSERT(RdpClipboardContentCodec::encode(value,job.content));queue.enqueue(std::move(job));};
    publish();auto first=queue.takeNext();RDP_ASSERT(first);RDP_ASSERT_EQ(first->content.items.size(),2U);
    std::thread a(publish),b(publish);a.join();b.join();RDP_ASSERT(!queue.takeNext());
    queue.acknowledge(true);RDP_ASSERT_EQ(queue.state(first->id),3);
    auto latest=queue.takeNext();RDP_ASSERT(latest);RDP_ASSERT_EQ(latest->content.items.size(),2U);
    queue.acknowledge(true);RDP_ASSERT_EQ(queue.state(latest->id),2);
}
