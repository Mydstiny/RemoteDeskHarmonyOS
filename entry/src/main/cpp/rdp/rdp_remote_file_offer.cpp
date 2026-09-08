#include "rdp_remote_file_offer.h"
#include "rdp_clipboard_codec.h"
#include <algorithm>
#include <map>

namespace {
uint16_t u16(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
uint32_t u32(const uint8_t* p) { return uint32_t(u16(p)) | uint32_t(u16(p + 2)) << 16; }
std::string folded(std::string value) {
    for (auto& c : value) if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
    return value;
}
bool reserved(const std::string& name) {
    const auto base = folded(name.substr(0, name.find('.')));
    return base == "con" || base == "prn" || base == "aux" || base == "nul" ||
        (base.size() == 4 && (base.compare(0, 3, "com") == 0 || base.compare(0, 3, "lpt") == 0) &&
         base[3] >= '1' && base[3] <= '9');
}
}
bool RdpRemoteFileOffer::safeRelativeName(const std::string& input, std::string& normalized) {
    if (input.empty() || input.size() > 1024) return false;
    std::vector<uint8_t> validUtf8;
    if (!RdpClipboardCodec::encode(input, validUtf8)) return false;
    std::string path = input;
    std::replace(path.begin(), path.end(), '\\', '/');
    if (path.front() == '/' || path.back() == '/') return false;
    size_t start = 0, depth = 0;
    while (start < path.size()) {
        const size_t slash = path.find('/', start);
        const auto part = path.substr(start, slash == std::string::npos ? slash : slash - start);
        if (++depth > 32 || part.empty() || part.size() > 255 || part == "." || part == ".." ||
            part.back() == '.' || part.back() == ' ' || reserved(part)) return false;
        for (const unsigned char c : part) {
            if (c < 0x20 || c == 0x7F || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|') return false;
        }
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    normalized = std::move(path); return true;
}
RemoteClipboardFileOffer RdpRemoteFileOffer::parse(
    const uint8_t* data, size_t size, uint64_t sequence, uint32_t flags) {
    RemoteClipboardFileOffer offer;
    offer.sequence = sequence; offer.streamSupported = (flags & 4) != 0;
    offer.lockSupported = (flags & 16) != 0; offer.hugeFileSupported = (flags & 32) != 0;
    offer.state = "failed"; offer.diagnosticCode = "invalid_file_descriptor";
    if (!sequence || !offer.streamSupported || !data || size < 4 || size > kMaxDescriptorBytes) return offer;
    const uint32_t count = u32(data);
    if (count == 0 || count > kMaxEntries || size != 4 + size_t(count) * kDescriptorBytes) return offer;
    std::map<std::string, bool> paths;
    offer.totalKnown = true;
    for (uint32_t index = 0; index < count; ++index) {
        const uint8_t* p = data + 4 + size_t(index) * kDescriptorBytes;
        const uint32_t descriptorFlags = u32(p), attributes = u32(p + 36);
        if ((attributes & 0x400) != 0 || ((attributes & 0x10) && !(descriptorFlags & 4))) return offer;
        size_t units = 0;
        while (units < 260 && u16(p + 72 + units * 2) != 0) ++units;
        if (units == 0 || units == 260) return offer;
        std::string name, normalized;
        if (!RdpClipboardCodec::decode(p + 72, (units + 1) * 2, name) || !safeRelativeName(name, normalized)) return offer;
        const auto key = folded(normalized);
        if (paths.count(key)) { offer.diagnosticCode = "duplicate_file_name"; return offer; }
        RemoteClipboardFileEntry entry;
        entry.index = index; entry.relativeName = normalized;
        entry.directory = (descriptorFlags & 4) && (attributes & 0x10);
        entry.sizeKnown = entry.directory || (descriptorFlags & 0x40);
        entry.size = entry.directory ? 0 : (uint64_t(u32(p + 64)) << 32) | u32(p + 68);
        if (!entry.sizeKnown) { entry.size = 0; offer.totalKnown = false; }
        if (entry.size > kMaxTotalBytes || entry.size > kMaxTotalBytes - offer.totalBytes ||
            (!offer.hugeFileSupported && entry.size >= 0x80000000ULL)) {
            offer.diagnosticCode = "file_size_budget_exceeded"; return offer;
        }
        offer.totalBytes += entry.size;
        paths.emplace(key, entry.directory); offer.entries.push_back(std::move(entry));
    }
    // Validate ancestors after the full list, allowing children before their
    // directory descriptor while rejecting a regular-file ancestor.
    for (const auto& path : paths) {
        size_t slash = path.first.find('/');
        while (slash != std::string::npos) {
            const auto ancestor = paths.find(path.first.substr(0, slash));
            if (ancestor != paths.end() && !ancestor->second) {
                offer.diagnosticCode = "file_directory_conflict"; return offer;
            }
            slash = path.first.find('/', slash + 1);
        }
    }
    offer.state = "ready"; offer.diagnosticCode.clear(); return offer;
}
