// Standalone host integration test: compile with RDP_CLIPBOARD_BRIDGE_HOST_TEST
// and the production bridge/offer sources, using real FreeRDP headers. Stubs only
// replace external WinPR/helper I/O; admission/drain/publication code is real.
#ifdef RDP_CLIPBOARD_BRIDGE_HOST_TEST
#include "rdp/rdp_file_clipboard_bridge.h"
#include "rdp/rdp_clipboard_features.h"
#include "rdp/rdp_clipboard_state.h"
#include <freerdp/utils/cliprdr_utils.h>
#include "test_runner.h"
#include <future>

struct cliprdr_file_context {
    void* owner = nullptr;
    bool locked = false;
    UINT32 flags = 0;
};
namespace {
CliprdrFileContext* active = nullptr;
std::string uriBytes;
std::string helperBytes;
std::mutex ioMutex;
std::condition_variable ioCv;
bool blockRead = false;
bool enteredRead = false;
bool releaseRead = false;
int reads = 0;
int failures = 0;
UINT helperRead(CliprdrClientContext*, const CLIPRDR_FILE_CONTENTS_REQUEST*) {
    std::unique_lock<std::mutex> lock(ioMutex);
    ++reads;
    enteredRead = true;
    ioCv.notify_all();
    if (blockRead) ioCv.wait(lock, [] { return releaseRead; });
    return CHANNEL_RC_OK;
}
UINT helperLock(CliprdrClientContext*, const CLIPRDR_LOCK_CLIPBOARD_DATA*) {
    active->locked = true; return CHANNEL_RC_OK;
}
UINT helperUnlock(CliprdrClientContext*, const CLIPRDR_UNLOCK_CLIPBOARD_DATA*) {
    active->locked = false; return CHANNEL_RC_OK;
}
UINT wrapperSentinel(CliprdrClientContext*, const CLIPRDR_FILE_CONTENTS_REQUEST*) {
    return ERROR_INTERNAL_ERROR;
}
UINT sendFormats(CliprdrClientContext*, const CLIPRDR_FORMAT_LIST*) { return CHANNEL_RC_OK; }
UINT sendContent(CliprdrClientContext*, const CLIPRDR_FILE_CONTENTS_RESPONSE* response) {
    if (response->common.msgFlags == CB_RESPONSE_FAIL) ++failures;
    return CHANNEL_RC_OK;
}
}
extern "C" {
wClipboard* ClipboardCreate() { return reinterpret_cast<wClipboard*>(new int(1)); }
void ClipboardDestroy(wClipboard* p) { delete reinterpret_cast<int*>(p); }
BOOL ClipboardEmpty(wClipboard*) { return TRUE; }
UINT32 ClipboardRegisterFormat(wClipboard*, const char* name) {
    return std::string(name) == "text/uri-list" ? 100 : 101;
}
BOOL ClipboardSetData(wClipboard*, UINT32, const void* data, UINT32 size) {
    uriBytes.assign(static_cast<const char*>(data), size); return TRUE;
}
void* ClipboardGetData(wClipboard*, UINT32, UINT32* size) { *size = 0; return nullptr; }
CliprdrFileContext* cliprdr_file_context_new(void* owner) {
    active = new cliprdr_file_context; active->owner = owner; return active;
}
void cliprdr_file_context_free(CliprdrFileContext* file) { delete file; active = nullptr; }
BOOL cliprdr_file_context_set_locally_available(CliprdrFileContext*, BOOL) { return TRUE; }
BOOL cliprdr_file_context_init(CliprdrFileContext* file, CliprdrClientContext* channel) {
    channel->custom = file;
    channel->ServerFileContentsRequest = helperRead;
    channel->ServerLockClipboardData = helperLock;
    channel->ServerUnlockClipboardData = helperUnlock;
    return TRUE;
}
BOOL cliprdr_file_context_uninit(CliprdrFileContext* file, CliprdrClientContext*) {
    file->locked = false; return TRUE;
}
BOOL cliprdr_file_context_clear(CliprdrFileContext*) { return TRUE; } // locked state deliberately retained
BOOL cliprdr_file_context_update_client_data(CliprdrFileContext*, const char* data, size_t size) {
    helperBytes.assign(data, size); return TRUE;
}
BOOL cliprdr_file_context_remote_set_flags(CliprdrFileContext* file, UINT32 flags) {
    file->flags = flags; return TRUE;
}
UINT32 cliprdr_file_context_remote_get_flags(CliprdrFileContext* file) { return file->flags; }
UINT32 cliprdr_file_context_current_flags(CliprdrFileContext*) { return CB_STREAM_FILECLIP_ENABLED; }
UINT cliprdr_file_context_notify_new_server_format_list(CliprdrFileContext*) { return CHANNEL_RC_OK; }
UINT cliprdr_file_context_notify_new_client_format_list(CliprdrFileContext*) { return CHANNEL_RC_OK; }
void* cliprdr_file_context_get_context(CliprdrFileContext* file) { return file->owner; }
UINT cliprdr_serialize_file_list_ex(UINT32, const FILEDESCRIPTORW*, UINT32, BYTE**, UINT32*) {
    return ERROR_INVALID_DATA;
}
}
RDP_TEST_CASE(rdp_bridge_disable_destroys_locked_stream_and_preserves_wrapper) {
    CliprdrClientContext channel {};
    channel.ClientFileContentsResponse = sendContent;
    RdpFileClipboardBridge bridge(nullptr);
    RDP_ASSERT(bridge.attach(&channel));
    channel.ServerFileContentsRequest = wrapperSentinel;
    CLIPRDR_LOCK_CLIPBOARD_DATA lock {};
    RDP_ASSERT_EQ(bridge.handleLock(&channel, &lock), CHANNEL_RC_OK);
    RDP_ASSERT(active->locked);
    bridge.setEnabled(false);
    RDP_ASSERT(!active->locked);
    RDP_ASSERT(channel.ServerFileContentsRequest == wrapperSentinel);
    const int previous = reads;
    CLIPRDR_FILE_CONTENTS_REQUEST request {};
    RDP_ASSERT_EQ(bridge.handleFileContentsRequest(&channel, &request), CHANNEL_RC_OK);
    RDP_ASSERT_EQ(reads, previous);
    RDP_ASSERT(failures > 0);
    bridge.handleLock(&channel, &lock);
    RDP_ASSERT(!active->locked);
}
RDP_TEST_CASE(rdp_bridge_disable_drains_admitted_read_before_returning) {
    CliprdrClientContext channel {};
    channel.ClientFileContentsResponse = sendContent;
    RdpFileClipboardBridge bridge(nullptr);
    RDP_ASSERT(bridge.attach(&channel));
    { std::lock_guard<std::mutex> guard(ioMutex); blockRead = true; releaseRead = false; enteredRead = false; }
    CLIPRDR_FILE_CONTENTS_REQUEST request {};
    auto reader = std::async(std::launch::async, [&] { return bridge.handleFileContentsRequest(&channel, &request); });
    { std::unique_lock<std::mutex> guard(ioMutex); ioCv.wait(guard, [] { return enteredRead; }); }
    auto disable = std::async(std::launch::async, [&] { bridge.setEnabled(false); });
    const bool waited = disable.wait_for(std::chrono::milliseconds(30)) == std::future_status::timeout;
    { std::lock_guard<std::mutex> guard(ioMutex); releaseRead = true; blockRead = false; }
    ioCv.notify_all();
    const UINT readResult = reader.get(); disable.get();
    RDP_ASSERT_EQ(readResult, CHANNEL_RC_OK);
    RDP_ASSERT(waited);
    const int previous = reads;
    bridge.handleFileContentsRequest(&channel, &request);
    RDP_ASSERT_EQ(reads, previous);
}
RDP_TEST_CASE(rdp_bridge_separates_encoded_uri_from_literal_helper_path) {
    CliprdrClientContext channel {};
    channel.ClientFormatList = sendFormats;
    RdpFileClipboardBridge bridge(nullptr);
    RDP_ASSERT(bridge.attach(&channel));
    RDP_ASSERT(bridge.publishLocalFiles({"/tmp/literal%20#.txt"}) == RdpFileClipboardOfferResult::Ready);
    RDP_ASSERT(uriBytes == "file:///tmp/literal%2520%23.txt\r\n");
    RDP_ASSERT(helperBytes == "/tmp/literal%20#.txt\n");
}
RDP_TEST_CASE(rdp_file_offer_mask_preserves_source_without_requesting_contents) {
    const UINT32 mask = rdpClipboardFeatureMask(true);
    RDP_ASSERT((mask & CLIPRDR_FLAG_REMOTE_TO_LOCAL_FILES) != 0);
    RDP_ASSERT_EQ(rdpClipboardFeatureMask(false), 0U);
    RdpClipboardState state;
    RDP_ASSERT_EQ(state.formatList(true, true, false), 0U);
    RDP_ASSERT(state.snapshot().kind == "files");
}
int main() { return runAllTests(); }
#endif
