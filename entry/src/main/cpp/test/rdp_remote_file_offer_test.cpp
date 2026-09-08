#include "rdp/rdp_remote_file_offer.h"
#include "rdp/rdp_clipboard_codec.h"
#include "test_runner.h"
namespace {
void set32(std::vector<uint8_t>& b, size_t p, uint32_t v) { for (int i=0;i<4;++i) b[p+i]=uint8_t(v>>(8*i)); }
std::vector<uint8_t> descriptors(const std::vector<std::string>& names, uint64_t size=0) {
    std::vector<uint8_t> b(4+names.size()*592); set32(b,0,uint32_t(names.size()));
    for(size_t i=0;i<names.size();++i) {
        const size_t p=4+i*592; set32(b,p,0x44); set32(b,p+64,uint32_t(size>>32)); set32(b,p+68,uint32_t(size));
        std::vector<uint8_t> name; RdpClipboardCodec::encode(names[i],name);
        std::copy(name.begin(),name.end(),b.begin()+p+72);
    }
    return b;
}
}
RDP_TEST_CASE(rdp_remote_offer_parses_zero_byte_file_and_empty_directory) {
    auto b=descriptors({"empty.txt","folder"}); set32(b,4+592+36,0x10);
    auto result=RdpRemoteFileOffer::parse(b.data(),b.size(),9,4|16|32);
    RDP_ASSERT(result.state=="ready"); RDP_ASSERT_EQ(result.entries.size(),2U);
    RDP_ASSERT(result.entries[0].sizeKnown); RDP_ASSERT_EQ(result.entries[0].size,0U);
    RDP_ASSERT(result.entries[1].directory); RDP_ASSERT(result.lockSupported);
}
RDP_TEST_CASE(rdp_remote_offer_preserves_uint64_sizes_and_rejects_without_huge_support) {
    auto b=descriptors({"large.bin"},5ULL*1024*1024*1024);
    auto result=RdpRemoteFileOffer::parse(b.data(),b.size(),1,4|32);
    RDP_ASSERT(result.state=="ready"); RDP_ASSERT_EQ(result.totalBytes,5ULL*1024*1024*1024);
    RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(),b.size(),1,4).state=="failed");
}
RDP_TEST_CASE(rdp_remote_offer_rejects_truncation_trailing_data_and_bad_utf16) {
    auto b=descriptors({"a"});
    RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(),b.size()-1,1,4).state=="failed");
    b.push_back(0); RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(),b.size(),1,4).state=="failed"); b.pop_back();
    b[76]=0x00;b[77]=0xD8; RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(),b.size(),1,4).state=="failed");
}
RDP_TEST_CASE(rdp_remote_offer_rejects_unsafe_paths_and_ambiguous_names) {
    for(const auto& name : {"../a","/absolute","C:\\a","a//b","a/../b","a:stream","NUL.txt","a.","a "}) {
        auto b=descriptors({name}); RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(),b.size(),1,4).state=="failed");
    }
    auto b=descriptors({"A.txt","a.txt"}); RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(),b.size(),1,4).state=="failed");
    b=descriptors({"folder","folder/file"}); RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(),b.size(),1,4).state=="failed");
}
RDP_TEST_CASE(rdp_remote_offer_literal_percent_is_not_uri_decoded) {
    auto b=descriptors({"dir\\literal%2F😀.txt"}); auto result=RdpRemoteFileOffer::parse(b.data(),b.size(),1,4);
    RDP_ASSERT(result.state=="ready"); RDP_ASSERT(result.entries[0].relativeName=="dir/literal%2F😀.txt");
}
RDP_TEST_CASE(rdp_remote_offer_rejects_parent_case_alias_in_both_descriptor_orders) {
    for (bool parentFirst : {false, true}) {
        auto b = descriptors(parentFirst ? std::vector<std::string>{"Root", "root/a.txt"} :
            std::vector<std::string>{"root/a.txt", "Root"});
        set32(b, 4 + (parentFirst ? 0 : 592) + 36, 0x10);
        const auto result = RdpRemoteFileOffer::parse(b.data(), b.size(), 1, 4);
        RDP_ASSERT(result.state == "failed");
        RDP_ASSERT(result.diagnosticCode == "ambiguous_file_path");
    }
}
RDP_TEST_CASE(rdp_remote_offer_rejects_inconsistent_implicit_parent_spellings) {
    for (const auto& names : std::vector<std::vector<std::string>>{
        {"Root/a.txt", "root/b.txt"}, {"root/b.txt", "Root/a.txt"},
        {"Root/Sub/a.txt", "Root/sub/b.txt"}, {"Root/sub/b.txt", "Root/Sub/a.txt"}}) {
        const auto b = descriptors(names);
        const auto result = RdpRemoteFileOffer::parse(b.data(), b.size(), 1, 4);
        RDP_ASSERT(result.state == "failed");
        RDP_ASSERT(result.diagnosticCode == "ambiguous_file_path");
    }
}
RDP_TEST_CASE(rdp_remote_offer_accepts_consistent_explicit_and_implicit_parent_spellings) {
    for (bool parentFirst : {false, true}) {
        auto b = descriptors(parentFirst ? std::vector<std::string>{"Root", "Root/Sub/a.txt", "Root/Sub/b.txt"} :
            std::vector<std::string>{"Root/Sub/a.txt", "Root/Sub/b.txt", "Root"});
        set32(b, 4 + (parentFirst ? 0 : 2 * 592) + 36, 0x10);
        const auto result = RdpRemoteFileOffer::parse(b.data(), b.size(), 1, 4);
        RDP_ASSERT(result.state == "ready");
        RDP_ASSERT_EQ(result.entries.size(), 3U);
        RDP_ASSERT(result.entries[parentFirst ? 1 : 0].relativeName == "Root/Sub/a.txt");
    }
    const auto b = descriptors({"Root/Sub/a.txt", "Root/Sub/b.txt"});
    RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(), b.size(), 1, 4).state == "ready");
}
RDP_TEST_CASE(rdp_remote_offer_prefix_validation_preserves_entry_and_depth_limits) {
    std::string deep = "Root";
    for (size_t i = 1; i < 32; ++i) deep += "/x";
    auto b = descriptors({deep});
    RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(), b.size(), 1, 4).state == "ready");
    b = descriptors({deep + "/x"});
    RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(), b.size(), 1, 4).state == "failed");
    std::vector<std::string> names;
    for (size_t i = 0; i < RdpRemoteFileOffer::kMaxEntries; ++i) names.push_back("Root/f" + std::to_string(i));
    b = descriptors(names);
    const auto result = RdpRemoteFileOffer::parse(b.data(), b.size(), 1, 4);
    RDP_ASSERT(result.state == "ready");
    RDP_ASSERT_EQ(result.entries.size(), RdpRemoteFileOffer::kMaxEntries);
    names.push_back("Root/overflow"); b = descriptors(names);
    RDP_ASSERT(RdpRemoteFileOffer::parse(b.data(), b.size(), 1, 4).state == "failed");
}
