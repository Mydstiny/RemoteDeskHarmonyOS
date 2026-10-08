#ifndef RDP_CLIPBOARD_CONTENT_H
#define RDP_CLIPBOARD_CONTENT_H
#include <cstdint>
#include <cstddef>
#include <optional>
#include <string>
#include <vector>

enum class RdpClipboardFormat : uint32_t { Text = 1, Png = 2, DibV5 = 3, Html = 4, Rtf = 5 };
// One clipboard value can carry several independent representations. Absence
// of text is distinct from an explicit empty text fallback. PNG carries its
// dimensions in IHDR; width/height describe rgbaStraight on publication.
struct RdpClipboardContent {
    std::optional<std::string> textUtf8;
    std::vector<uint8_t> png;
    std::optional<std::string> htmlUtf8;
    std::vector<uint8_t> rtfBytes;
    std::vector<uint8_t> rgbaStraight;
    uint32_t width = 0;
    uint32_t height = 0;
};
struct RdpClipboardFormatEntry { RdpClipboardFormat format; uint32_t formatId; };
struct RdpClipboardFormatOffer {
    uint64_t sequence = 0;
    std::vector<RdpClipboardFormatEntry> formats;
};
struct RdpClipboardFormatResult {
    uint64_t requestId = 0;
    uint64_t sequence = 0;
    RdpClipboardFormat format = RdpClipboardFormat::Text;
    // unavailable, loading, ready, failed, cancelled, stale, timeout
    std::string state = "unavailable";
    std::string diagnosticCode;
    RdpClipboardContent content;
};
struct RdpClipboardWireContent {
    struct Item { RdpClipboardFormat format; uint32_t formatId; std::string name; std::vector<uint8_t> bytes; };
    std::vector<Item> items;
};
namespace RdpClipboardContentCodec {
constexpr size_t kMaxPngBytes = 8 * 1024 * 1024;
constexpr size_t kMaxRichBytes = 1024 * 1024;
constexpr uint32_t kMaxDimension = 8192;
constexpr uint64_t kMaxPixels = 4194304;
// Checks the encoded budget, chunk boundaries/CRC and IHDR dimensions. The
// application must also decode through ImageKit within the same pixel budget
// before accepting/publishing PNG: this routine does not inflate IDAT.
bool validatePng(const uint8_t* data, size_t size, uint32_t& width, uint32_t& height);
bool encodeDibV5(const std::vector<uint8_t>& rgba, uint32_t width, uint32_t height, std::vector<uint8_t>& result);
bool decodeDibV5(const uint8_t* data, size_t size, RdpClipboardContent& result);
bool encodeHtml(const std::string& fragment, std::vector<uint8_t>& result);
bool decodeHtml(const uint8_t* data, size_t size, std::string& result);
bool validateRtf(const uint8_t* data, size_t size);
bool encode(const RdpClipboardContent& content, RdpClipboardWireContent& result);
bool decode(RdpClipboardFormat format, const uint8_t* data, size_t size, RdpClipboardContent& result);
std::optional<RdpClipboardFormat> identify(uint32_t formatId, const char* name);
}
#endif
