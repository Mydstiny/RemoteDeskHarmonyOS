#include "rdp/rdp_clipboard_state.h"
#include "test_runner.h"

RDP_TEST_CASE(rdp_clipboard_same_text_new_copy_has_new_sequence) {
    RdpClipboardState state;
    auto first = state.formatList(true, false, false);
    RDP_ASSERT(first > 0);
    RDP_ASSERT(!state.snapshot().ready);
    RDP_ASSERT_EQ(state.response(true, "A"), 0U);
    RDP_ASSERT(state.snapshot().ready);
    auto second = state.formatList(true, false, false);
    RDP_ASSERT(second > first);
    state.response(true, "A");
    RDP_ASSERT(state.snapshot().text == std::string("A"));
}
RDP_TEST_CASE(rdp_clipboard_new_file_offer_supersedes_pending_text) {
    RdpClipboardState state;
    state.formatList(true, false, false);
    RDP_ASSERT_EQ(state.formatList(true, true, false), 0U);
    RDP_ASSERT(state.snapshot().kind == std::string("files"));
    state.response(true, "stale");
    RDP_ASSERT(state.snapshot().text.empty());
    RDP_ASSERT(state.snapshot().kind == std::string("files"));
}
RDP_TEST_CASE(rdp_clipboard_drains_unidentified_response_before_latest_request) {
    RdpClipboardState state;
    state.formatList(true, false, false);
    RDP_ASSERT_EQ(state.formatList(true, false, false), 0U);
    const auto newest = state.snapshot().sequence;
    RDP_ASSERT_EQ(state.response(true, "old"), newest);
    RDP_ASSERT(!state.snapshot().ready);
    state.response(true, "new");
    RDP_ASSERT(state.snapshot().text == std::string("new"));
}
RDP_TEST_CASE(rdp_clipboard_disable_and_clear_are_distinct_events) {
    RdpClipboardState state;
    state.formatList(true, false, false);
    state.invalidate();
    RDP_ASSERT(!state.snapshot().ready);
    state.response(true, "stale");
    RDP_ASSERT(!state.snapshot().ready);
    state.formatList(false, false, true);
    RDP_ASSERT(state.snapshot().ready);
    RDP_ASSERT(state.snapshot().kind == std::string("none"));
}
RDP_TEST_CASE(rdp_clipboard_response_failure_does_not_fabricate_clear) {
    RdpClipboardState state;
    auto sequence = state.formatList(true, false, false);
    state.response(false, "");
    RDP_ASSERT(state.snapshot().kind == std::string("text"));
    RDP_ASSERT(!state.snapshot().ready);
    RDP_ASSERT(state.formatList(true, false, false) > sequence);
    state.invalidate(true);
    RDP_ASSERT(state.formatList(true, false, false) > sequence);
}

RDP_TEST_CASE(rdp_clipboard_descriptor_request_waits_for_previous_text_response) {
    RdpClipboardState state;
    state.formatList(true,false,false);
    state.formatList(false,true,false);
    const auto sequence=state.snapshot().sequence;
    RDP_ASSERT(state.requestFiles(sequence,101));
    RDP_ASSERT(!state.pendingRequest().files);
    RDP_ASSERT_EQ(state.response(true,"stale"),sequence);
    RDP_ASSERT(state.pendingRequest().files); RDP_ASSERT_EQ(state.pendingRequest().formatId,101U);
    RDP_ASSERT_EQ(state.response(false,""),0U);
    RDP_ASSERT(state.snapshot().kind=="files");
}
RDP_TEST_CASE(rdp_clipboard_expired_queued_descriptor_does_not_send_after_drain) {
    RdpClipboardState state; state.formatList(true,false,false); state.formatList(false,true,false);
    const auto sequence=state.snapshot().sequence;
    state.requestFiles(sequence,101); state.cancelQueuedFileRequest(sequence);
    RDP_ASSERT_EQ(state.response(true,"stale"),0U); RDP_ASSERT_EQ(state.pendingRequest().sequence,0U);
}
