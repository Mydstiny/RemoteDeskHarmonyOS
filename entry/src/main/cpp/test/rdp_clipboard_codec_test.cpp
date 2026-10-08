#include "rdp/rdp_clipboard_codec.h"
#include "test_runner.h"

RDP_TEST_CASE(rdp_clipboard_utf16le_roundtrips_supplementary_characters) {
    const std::string text = "中文😀𠮷";
    std::vector<uint8_t> bytes;
    RDP_ASSERT(RdpClipboardCodec::encode(text, bytes));
    std::string decoded;
    RDP_ASSERT(RdpClipboardCodec::decode(bytes.data(), bytes.size(), decoded));
    RDP_ASSERT(decoded == text);
    RDP_ASSERT_EQ(bytes[4], 0x3D);
    RDP_ASSERT_EQ(bytes[5], 0xD8);
}
RDP_TEST_CASE(rdp_clipboard_rejects_unpaired_surrogates_and_odd_wire_length) {
    std::string decoded = "retained";
    const uint8_t high[] = {0x00, 0xD8, 0, 0};
    const uint8_t low[] = {0x00, 0xDC, 0, 0};
    const uint8_t missingNull[] = {0x41, 0};
    RDP_ASSERT(!RdpClipboardCodec::decode(high, sizeof(high), decoded));
    RDP_ASSERT(!RdpClipboardCodec::decode(low, sizeof(low), decoded));
    RDP_ASSERT(!RdpClipboardCodec::decode(high, 3, decoded));
    RDP_ASSERT(!RdpClipboardCodec::decode(missingNull, sizeof(missingNull), decoded));
    RDP_ASSERT(decoded == std::string("retained"));
}
RDP_TEST_CASE(rdp_clipboard_rejects_invalid_utf8_without_partial_publication) {
    std::vector<uint8_t> bytes = {42};
    RDP_ASSERT(!RdpClipboardCodec::encode(std::string("\xC0\xAF", 2), bytes));
    RDP_ASSERT(!RdpClipboardCodec::encode(std::string("\xED\xA0\x80", 3), bytes));
    RDP_ASSERT(!RdpClipboardCodec::encode(std::string("\xF4\x90\x80\x80", 4), bytes));
    RDP_ASSERT(!RdpClipboardCodec::encode(std::string("a\0b", 3), bytes));
    RDP_ASSERT_EQ(bytes.size(), 1U);
    RDP_ASSERT_EQ(bytes[0], 42);
}
RDP_TEST_CASE(rdp_clipboard_budget_is_utf8_bytes_in_both_directions) {
    std::vector<uint8_t> bytes;
    const std::string atLimit(RdpClipboardCodec::kMaxUtf8Bytes, 'a');
    RDP_ASSERT(RdpClipboardCodec::encode(atLimit, bytes));
    std::string decoded;
    RDP_ASSERT(RdpClipboardCodec::decode(bytes.data(), bytes.size(), decoded));
    RDP_ASSERT(decoded == atLimit);
    RDP_ASSERT(!RdpClipboardCodec::encode(atLimit + "a", bytes));
    std::vector<uint8_t> multibyte;
    for (size_t i = 0; i < 21846; ++i) { multibyte.push_back(0x2D); multibyte.push_back(0x4E); }
    multibyte.push_back(0); multibyte.push_back(0);
    RDP_ASSERT(!RdpClipboardCodec::decode(multibyte.data(), multibyte.size(), decoded));
}
RDP_TEST_CASE(rdp_clipboard_empty_text_and_unaligned_data_are_valid) {
    std::vector<uint8_t> bytes;
    RDP_ASSERT(RdpClipboardCodec::encode("", bytes));
    std::string decoded = "old";
    RDP_ASSERT(RdpClipboardCodec::decode(bytes.data(), bytes.size(), decoded));
    RDP_ASSERT(decoded.empty());
    const uint8_t unaligned[] = {99, 0x3D, 0xD8, 0x00, 0xDE, 0, 0};
    RDP_ASSERT(RdpClipboardCodec::decode(unaligned + 1, sizeof(unaligned) - 1, decoded));
    RDP_ASSERT(decoded == std::string("😀"));
}
