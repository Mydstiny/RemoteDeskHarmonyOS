#include "rdp/rdp_channel_observer.h"
#include "rdp/rdp_channel_forwarder.h"
#include "rdp/rdp_clipboard_codec.h"
#include "test_runner.h"
namespace {
void word(std::vector<uint8_t>& b, uint32_t v) { for (int i = 0; i < 4; ++i) b.push_back(uint8_t(v >> (i * 8))); }
std::vector<uint8_t> packet(uint16_t type) { return {0x72, 0x44, uint8_t(type), uint8_t(type >> 8)}; }
std::vector<uint8_t> announce(uint32_t id) {
    auto p = packet(0x4441); word(p, 1); word(p, 8); word(p, id);
    p.resize(p.size() + 8); word(p, 0); return p;
}
void reply(RdpChannelObserver& o, uint32_t id, uint32_t status) {
    auto p = packet(0x6472); word(p, id); word(p, status); o.receive(p.data(), p.size(), 3, p.size());
}
void ready(RdpChannelObserver& o) {
    o.reset(1); o.registered(7); auto p = announce(7); o.sent(p.data(), p.size()); reply(o, 7, 0);
}
std::vector<uint8_t> request(uint32_t file, uint32_t completion, uint32_t major) {
    auto p = packet(0x4952); word(p, 7); word(p, file); word(p, completion); word(p, major); word(p, 0); return p;
}
void complete(RdpChannelObserver& o, uint32_t completion, uint32_t payload, uint32_t status = 0) {
    auto p = packet(0x4943); word(p, 7); word(p, completion); word(p, status); word(p, payload); o.sent(p.data(), p.size());
}
void opened(RdpChannelObserver& o) {
    std::vector<uint8_t> name; RdpClipboardCodec::encode("\\file.txt", name);
    auto p = request(0, 1, 0); p.resize(52); word(p, uint32_t(name.size())); p.insert(p.end(), name.begin(), name.end());
    o.receive(p.data(), p.size(), 3, p.size()); complete(o, 1, 10);
}
}
RDP_TEST_CASE(rdp_drive_register_and_announce_are_not_server_acceptance) {
    RdpChannelObserver o; o.reset(4); o.registered(7);
    RDP_ASSERT(o.status().phase == "localRegistered");
    auto p = announce(7); o.sent(p.data(), p.size());
    RDP_ASSERT(o.status().phase == "announceSent");
    reply(o, 8, 0); RDP_ASSERT(o.status().phase == "announceSent");
    reply(o, 7, 0); RDP_ASSERT(o.status().phase == "serverAccepted");
}
RDP_TEST_CASE(rdp_drive_rejection_and_late_acceptance_do_not_revive_removed_drive) {
    RdpChannelObserver o; ready(o); reply(o, 7, 0xC0000022);
    RDP_ASSERT(o.status().phase == "rejected");
    o.unavailable("disabled"); reply(o, 7, 0);
    auto p = announce(7); o.sent(p.data(), p.size());
    RDP_ASSERT(o.status().phase == "unavailable");
}
RDP_TEST_CASE(rdp_drive_fragmented_reply_is_observed_only_after_last) {
    RdpChannelObserver o; o.reset(1); o.registered(7); auto a = announce(7); o.sent(a.data(), a.size());
    auto p = packet(0x6472); word(p, 7); word(p, 0);
    o.receive(p.data(), 5, 1, p.size()); RDP_ASSERT(o.status().phase == "announceSent");
    o.receive(p.data()+5, p.size()-5, 2, p.size()); RDP_ASSERT(o.status().phase == "serverAccepted");
}
RDP_TEST_CASE(rdp_drive_tracks_successful_write_and_close_completion) {
    RdpChannelObserver o; ready(o); opened(o);
    auto facts = o.files(); RDP_ASSERT_EQ(facts.size(), 1U); RDP_ASSERT(!facts[0].remoteClosed);
    auto write = request(10, 2, 4); word(write, 3); write.resize(56); write.insert(write.end(), {1,2,3});
    o.receive(write.data(), write.size(), 3, write.size()); complete(o, 2, 3);
    auto close = request(10, 3, 2); o.receive(close.data(), close.size(), 3, close.size());
    RDP_ASSERT(!o.files()[0].remoteClosed); complete(o, 3, 0);
    facts = o.files(); RDP_ASSERT_EQ(facts[0].writtenBytes, 3U); RDP_ASSERT(facts[0].remoteClosed);
}
RDP_TEST_CASE(rdp_drive_incomplete_observation_never_claims_closed_file) {
    RdpChannelObserver o; ready(o); opened(o);
    const uint8_t bad[] = {1,2,3}; o.receive(bad, sizeof(bad), 2, 10);
    auto close = request(10, 3, 2); o.receive(close.data(), close.size(), 3, close.size()); complete(o, 3, 0);
    RDP_ASSERT(!o.status().evidenceComplete); RDP_ASSERT(!o.files()[0].remoteClosed);
}
RDP_TEST_CASE(rdp_drive_registration_merges_early_announce_and_reply) {
    RdpChannelObserver o; o.reset(1); auto p = announce(7); o.sent(p.data(), p.size()); reply(o, 7, 0);
    o.registered(7); RDP_ASSERT(o.status().phase == "serverAccepted");
}

RDP_TEST_CASE(rdp_channel_forwarder_preserves_invalid_packet_and_return_value) {
    RdpChannelObserver o; ready(o);
    const std::vector<uint8_t> packet {1,2,3};
    size_t calls = 0;
    const auto result = RdpChannelForwarder::receive(&o,packet.data(),packet.size(),2,99,[&] {
        ++calls; return false;
    });
    RDP_ASSERT(!result); RDP_ASSERT_EQ(calls,1U);
    RDP_ASSERT(packet == std::vector<uint8_t>({1,2,3}));
    RDP_ASSERT(!o.status().evidenceComplete);
}
RDP_TEST_CASE(rdp_channel_forwarder_only_records_successful_send) {
    RdpChannelObserver o; o.reset(1); o.registered(7); auto p=announce(7);
    RDP_ASSERT(!RdpChannelForwarder::send(&o,p.data(),p.size(),[]{return false;}));
    RDP_ASSERT(o.status().phase=="localRegistered");
    RDP_ASSERT(RdpChannelForwarder::send(&o,p.data(),p.size(),[]{return true;}));
    RDP_ASSERT(o.status().phase=="announceSent");
}
RDP_TEST_CASE(rdp_drive_explicit_disable_before_registration_cannot_revive) {
    RdpChannelObserver o; o.reset(1); o.unavailable("disabled");
    o.registered(7); auto p=announce(7); o.sent(p.data(),p.size()); reply(o,7,0);
    RDP_ASSERT(o.status().phase=="unavailable");
}
