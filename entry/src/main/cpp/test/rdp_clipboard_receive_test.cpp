#include "rdp/rdp_clipboard_receive.h"
#include "test_runner.h"
#include <atomic>
#include <filesystem>
#include <fstream>
#include <fcntl.h>
#include <unistd.h>
namespace {
struct Stage {
    std::string path;
    int fd = -1;
    Stage() {
#if defined(__OHOS__)
        std::string prefix = "/data/local/tmp/rdp-receive-test-XXXXXX";
#else
        std::string prefix = std::filesystem::temp_directory_path().string() + "/rdp-receive-test-XXXXXX";
#endif
        std::vector<char> name(prefix.begin(), prefix.end()); name.push_back(0);
        char* result = mkdtemp(name.data());
        if (result) { path = result; fd = open(path.c_str(), O_RDONLY | O_DIRECTORY); }
    }
    ~Stage() { if (fd >= 0) close(fd); if (!path.empty()) std::filesystem::remove_all(path); }
};
RemoteClipboardFileOffer offer(uint64_t size, bool known = true) {
    RemoteClipboardFileOffer result;
    result.sequence = 7; result.state = "ready"; result.streamSupported = true;
    result.entries.push_back({0,"file.txt",false,known,size}); return result;
}
RemoteClipboardReceiveStatus finished(RdpClipboardReceive& receiver) {
    for (int i = 0; i < 3000; ++i) {
        auto value = receiver.status();
        if (value.phase == "completed" || value.phase == "cancelled" || value.phase == "failed") return value;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    receiver.cancel("test_timeout");
    return receiver.status();
}
std::string read(const std::string& path) {
    std::ifstream stream(path, std::ios::binary); return std::string(std::istreambuf_iterator<char>(stream), {});
}
}
RDP_TEST_CASE(rdp_receive_short_reads_continue_at_actual_offset) {
    Stage stage; RDP_ASSERT(stage.fd >= 0);
    RdpClipboardReceive receiver;
    const std::string text = "abcdefg";
    std::vector<uint64_t> offsets;
    RDP_ASSERT(receiver.start(1,offer(text.size()),{0},stage.fd,0,
        [&](const RdpClipboardFileRequest& request) {
            offsets.push_back(request.offset);
            const auto bytes = text.substr(size_t(request.offset),request.offset==0 ? 2 : request.requested);
            return receiver.response(request.streamId,true,reinterpret_cast<const uint8_t*>(bytes.data()),bytes.size());
        },{}));
    const auto status = finished(receiver);
    RDP_ASSERT(status.phase=="completed"); RDP_ASSERT_EQ(status.transferredBytes,text.size());
    RDP_ASSERT_EQ(offsets.size(),2U); RDP_ASSERT_EQ(offsets[1],2U);
    RDP_ASSERT(read(stage.path+"/"+status.artifacts[0].relativeName)==text);
}
RDP_TEST_CASE(rdp_receive_zero_bytes_and_empty_directory_need_no_range_request) {
    Stage stage; RdpClipboardReceive receiver; auto source=offer(0);
    source.entries.push_back({1,"empty",true,true,0});
    std::atomic<int> requests {0};
    RDP_ASSERT(receiver.start(2,source,{0,1},stage.fd,0,[&](const RdpClipboardFileRequest&) { ++requests; return false; },{}));
    const auto status=finished(receiver); RDP_ASSERT(status.phase=="completed"); RDP_ASSERT_EQ(requests.load(),0);
    RDP_ASSERT_EQ(std::filesystem::file_size(stage.path+"/receive-2/files/file.txt"),0U);
    RDP_ASSERT(std::filesystem::is_directory(stage.path+"/receive-2/files/empty"));
}
RDP_TEST_CASE(rdp_receive_size_query_precedes_range_and_wrong_stream_is_ignored) {
    Stage stage; RdpClipboardReceive receiver; std::vector<bool> kinds;
    RDP_ASSERT(receiver.start(3,offer(0,false),{0},stage.fd,0,
        [&](const RdpClipboardFileRequest& request) {
            kinds.push_back(request.sizeQuery);
            const uint8_t size[] = {3,0,0,0,0,0,0,0};
            const uint8_t data[] = {'a','b','c'};
            const auto* bytes=request.sizeQuery ? size : data;
            const size_t count=request.sizeQuery ? sizeof(size) : sizeof(data);
            if (receiver.response(request.streamId+1,true,bytes,count)) return false;
            return receiver.response(request.streamId,true,bytes,count);
        },{}));
    const auto status=finished(receiver); RDP_ASSERT(status.phase=="completed");
    RDP_ASSERT_EQ(kinds.size(),2U); RDP_ASSERT(kinds[0]); RDP_ASSERT(!kinds[1]);
    RDP_ASSERT_EQ(status.totalBytes,3U);
}
RDP_TEST_CASE(rdp_receive_early_eof_fails_and_cleans_owned_partial) {
    Stage stage; RdpClipboardReceive receiver;
    RDP_ASSERT(receiver.start(4,offer(4),{0},stage.fd,0,[&](const RdpClipboardFileRequest& request) {
        return receiver.response(request.streamId,true,nullptr,0);
    },{}));
    const auto status=finished(receiver); RDP_ASSERT(status.phase=="failed");
    RDP_ASSERT(status.diagnosticCode=="premature_file_eof");
    RDP_ASSERT(!std::filesystem::exists(stage.path+"/receive-4"));
}
RDP_TEST_CASE(rdp_receive_cancel_revokes_response_and_unlocks_once) {
    Stage stage; RdpClipboardReceive receiver; std::atomic<uint32_t> pending {0}; std::atomic<int> unlocks {0};
    RDP_ASSERT(receiver.start(5,offer(4),{0},stage.fd,9,[&](const RdpClipboardFileRequest& request) {
        pending.store(request.streamId); return true;
    },[&](uint32_t id) { if(id==9) ++unlocks; }));
    for(int i=0;i<1000 && !pending.load();++i) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    RDP_ASSERT(pending.load()!=0); RDP_ASSERT(receiver.cancel());
    const uint8_t bytes[]={1,2,3,4};
    RDP_ASSERT(!receiver.response(pending.load(),true,bytes,sizeof(bytes)));
    const auto status=finished(receiver); RDP_ASSERT(status.phase=="cancelled");
    RDP_ASSERT_EQ(unlocks.load(),1); RDP_ASSERT(!std::filesystem::exists(stage.path+"/receive-5"));
}
RDP_TEST_CASE(rdp_receive_unlocked_offer_change_stops_pending_file) {
    Stage stage; RdpClipboardReceive receiver; std::atomic<uint32_t> pending {0};
    RDP_ASSERT(receiver.start(6,offer(4),{0},stage.fd,0,[&](const RdpClipboardFileRequest& request) {
        pending.store(request.streamId); return true;
    },{}));
    for(int i=0;i<1000 && !pending.load();++i) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    receiver.offerChanged(8); const auto status=finished(receiver);
    RDP_ASSERT(status.phase=="cancelled"); RDP_ASSERT(status.diagnosticCode=="clipboard_changed_without_lock");
}
RDP_TEST_CASE(rdp_receive_locked_offer_change_keeps_original_clipdata_id) {
    Stage stage; RdpClipboardReceive receiver; std::atomic<uint32_t> pending {0}; std::atomic<uint32_t> lock {0};
    RDP_ASSERT(receiver.start(7,offer(4),{0},stage.fd,12,[&](const RdpClipboardFileRequest& request) {
        lock.store(request.clipDataId); pending.store(request.streamId); return true;
    },{}));
    for(int i=0;i<1000 && !pending.load();++i) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    receiver.offerChanged(8); const uint8_t bytes[]={1,2,3,4};
    RDP_ASSERT(receiver.response(pending.load(),true,bytes,sizeof(bytes)));
    RDP_ASSERT(finished(receiver).phase=="completed"); RDP_ASSERT_EQ(lock.load(),12U);
}
RDP_TEST_CASE(rdp_receive_timeout_is_terminal_and_releases_private_partial) {
    Stage stage; RdpClipboardReceive receiver({20,1000});
    RDP_ASSERT(receiver.start(8,offer(4),{0},stage.fd,0,[](const RdpClipboardFileRequest&) { return true; },{}));
    const auto status=finished(receiver); RDP_ASSERT(status.phase=="failed");
    RDP_ASSERT(status.diagnosticCode=="file_request_timeout"); RDP_ASSERT(!std::filesystem::exists(stage.path+"/receive-8"));
}
RDP_TEST_CASE(rdp_receive_never_overwrites_symlink_target_at_commit) {
    Stage stage; RdpClipboardReceive receiver;
    const auto victim=stage.path+"/victim.txt"; {std::ofstream stream(victim); stream<<"retained";}
    RDP_ASSERT(receiver.start(9,offer(4),{0},stage.fd,0,[&](const RdpClipboardFileRequest& request) {
        const auto link=stage.path+"/receive-9/files/file.txt";
        if(symlink(victim.c_str(),link.c_str())!=0) return false;
        const uint8_t bytes[]={1,2,3,4}; return receiver.response(request.streamId,true,bytes,sizeof(bytes));
    },{}));
    RDP_ASSERT(finished(receiver).phase=="failed"); RDP_ASSERT(read(victim)=="retained");
}
RDP_TEST_CASE(rdp_receive_unknown_size_cannot_exceed_reserved_batch_budget) {
    Stage stage; RdpClipboardReceive receiver({15000,1800000,4});
    std::atomic<int> rangeRequests {0};
    RDP_ASSERT(receiver.start(10,offer(0,false),{0},stage.fd,0,[&](const RdpClipboardFileRequest& request) {
        if (!request.sizeQuery) ++rangeRequests;
        const uint8_t size[] = {5,0,0,0,0,0,0,0};
        return receiver.response(request.streamId,true,size,sizeof(size));
    },{}));
    const auto status=finished(receiver);
    RDP_ASSERT(status.phase=="failed"); RDP_ASSERT(status.diagnosticCode=="file_size_budget_exceeded");
    RDP_ASSERT_EQ(rangeRequests.load(),0); RDP_ASSERT(!std::filesystem::exists(stage.path+"/receive-10"));
}
RDP_TEST_CASE(rdp_receive_total_budget_covers_all_selected_files_before_any_write) {
    Stage stage; RdpClipboardReceive receiver({15000,1800000,4});
    auto source=offer(3); source.entries.push_back({1,"second.txt",false,true,2});
    std::atomic<int> requests {0};
    RDP_ASSERT(receiver.start(11,source,{0,1},stage.fd,0,[&](const RdpClipboardFileRequest&) { ++requests; return false; },{}));
    const auto status=finished(receiver);
    RDP_ASSERT(status.phase=="failed"); RDP_ASSERT(status.diagnosticCode=="file_size_budget_exceeded");
    RDP_ASSERT_EQ(requests.load(),0); RDP_ASSERT_EQ(status.transferredBytes,0U);
}
RDP_TEST_CASE(rdp_receive_exact_reserved_budget_is_allowed) {
    Stage stage; RdpClipboardReceive receiver({15000,1800000,4});
    RDP_ASSERT(receiver.start(12,offer(4),{0},stage.fd,0,[&](const RdpClipboardFileRequest& request) {
        const uint8_t bytes[]={1,2,3,4}; return receiver.response(request.streamId,true,bytes,sizeof(bytes));
    },{}));
    RDP_ASSERT(finished(receiver).phase=="completed");
}
RDP_TEST_CASE(rdp_receive_default_budget_is_two_gibibytes_even_with_huge_support) {
    Stage stage; RdpClipboardReceive receiver; auto source=offer(2ULL*1024*1024*1024+1); source.hugeFileSupported=true;
    RDP_ASSERT(receiver.start(13,source,{0},stage.fd,0,[](const RdpClipboardFileRequest&) { return false; },{}));
    const auto status=finished(receiver);
    RDP_ASSERT(status.phase=="failed"); RDP_ASSERT(status.diagnosticCode=="file_size_budget_exceeded");
}
