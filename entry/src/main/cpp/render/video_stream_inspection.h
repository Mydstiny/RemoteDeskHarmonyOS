#pragma once

#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

namespace Render {

/**
 * What an encoded access unit carries, for diagnosing presentation problems
 * that depend on the sender's encoder: the NAL unit types, the SEI payload
 * types, and a display-orientation SEI (H.264 and H.265 payload type 47) when
 * one is present. Annex B only; a buffer without start codes is reported as
 * not inspected.
 */
struct VideoStreamInspection {
    bool annexB = false;
    uint64_t nalMaskLow = 0;   // NAL types 0..31
    uint64_t nalMaskHigh = 0;  // NAL types 32..63 (H.265)
    uint64_t seiMaskLow = 0;   // SEI payload types 0..31
    uint64_t seiMaskHigh = 0;  // SEI payload types 32..63
    bool displayOrientation = false;
    bool orientationCancel = false;
    bool horFlip = false;
    bool verFlip = false;
    uint32_t rotation = 0;     // anticlockwise, units of 360 / 65536 degrees
};

namespace StreamInspectionDetail {

/** RBSP of a NAL payload: emulation-prevention bytes removed. */
inline std::vector<uint8_t> Rbsp(const uint8_t* data, size_t size) {
    std::vector<uint8_t> out;
    out.reserve(size);
    size_t zeros = 0;
    for (size_t index = 0; index < size; ++index) {
        const uint8_t byte = data[index];
        if (zeros >= 2 && byte == 0x03) { zeros = 0; continue; }
        out.push_back(byte);
        zeros = byte == 0 ? zeros + 1 : 0;
    }
    return out;
}

class BitReader {
public:
    BitReader(const uint8_t* data, size_t size) : data_(data), size_(size) {}
    bool bit(uint32_t& value) {
        if (position_ >= size_ * 8) { return false; }
        value = (data_[position_ / 8] >> (7 - position_ % 8)) & 1U;
        ++position_;
        return true;
    }
    bool bits(int count, uint32_t& value) {
        value = 0;
        for (int index = 0; index < count; ++index) {
            uint32_t one = 0;
            if (!bit(one)) { return false; }
            value = (value << 1) | one;
        }
        return true;
    }
private:
    const uint8_t* data_;
    size_t size_;
    size_t position_ = 0;
};

inline void ParseDisplayOrientation(const uint8_t* payload, size_t size, VideoStreamInspection& out) {
    BitReader reader(payload, size);
    uint32_t cancel = 0;
    if (!reader.bit(cancel)) { return; }
    out.displayOrientation = true;
    out.orientationCancel = cancel != 0;
    if (cancel != 0) { return; }
    uint32_t hor = 0;
    uint32_t ver = 0;
    uint32_t rotation = 0;
    if (!reader.bit(hor) || !reader.bit(ver) || !reader.bits(16, rotation)) { return; }
    out.horFlip = hor != 0;
    out.verFlip = ver != 0;
    out.rotation = rotation;
}

/** SEI messages of one SEI NAL (RBSP after the NAL header). */
inline void ParseSei(const std::vector<uint8_t>& rbsp, size_t start, VideoStreamInspection& out) {
    size_t cursor = start;
    while (cursor < rbsp.size()) {
        // rbsp_trailing_bits: a lone 0x80 ends the message list.
        if (rbsp[cursor] == 0x80 && cursor + 1 == rbsp.size()) { return; }
        uint32_t type = 0;
        while (cursor < rbsp.size() && rbsp[cursor] == 0xff) { type += 255; ++cursor; }
        if (cursor >= rbsp.size()) { return; }
        type += rbsp[cursor++];
        uint32_t size = 0;
        while (cursor < rbsp.size() && rbsp[cursor] == 0xff) { size += 255; ++cursor; }
        if (cursor >= rbsp.size()) { return; }
        size += rbsp[cursor++];
        if (type < 32) { out.seiMaskLow |= 1ULL << type; }
        else if (type < 64) { out.seiMaskHigh |= 1ULL << (type - 32); }
        if (cursor + size > rbsp.size()) { return; }
        if (type == 47) { ParseDisplayOrientation(rbsp.data() + cursor, size, out); }
        cursor += size;
    }
}

} // namespace StreamInspectionDetail

/** Inspect one Annex B access unit; `hevc` selects H.265 NAL headers. Results accumulate into `out`. */
inline void InspectAnnexBAccessUnit(const uint8_t* data, size_t size, bool hevc, VideoStreamInspection& out) {
    if (data == nullptr || size < 4) { return; }
    std::vector<std::pair<size_t, size_t>> units;
    size_t index = 0;
    size_t unitStart = 0;
    bool inUnit = false;
    while (index + 2 < size) {
        if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
            if (inUnit) {
                size_t end = index;
                while (end > unitStart && data[end - 1] == 0) { --end; }
                units.emplace_back(unitStart, end);
            }
            index += 3;
            unitStart = index;
            inUnit = true;
            continue;
        }
        ++index;
    }
    if (inUnit && unitStart < size) { units.emplace_back(unitStart, size); }
    if (units.empty()) { return; }
    out.annexB = true;
    for (const auto& unit : units) {
        const size_t length = unit.second - unit.first;
        const uint8_t* nal = data + unit.first;
        if (length < (hevc ? 2U : 1U)) { continue; }
        const uint32_t type = hevc ? ((nal[0] >> 1) & 0x3fU) : (nal[0] & 0x1fU);
        if (type < 32) { out.nalMaskLow |= 1ULL << type; } else { out.nalMaskHigh |= 1ULL << (type - 32); }
        const bool sei = hevc ? (type == 39 || type == 40) : type == 6;
        if (sei) {
            const size_t header = hevc ? 2U : 1U;
            const std::vector<uint8_t> rbsp = StreamInspectionDetail::Rbsp(nal + header, length - header);
            StreamInspectionDetail::ParseSei(rbsp, 0, out);
        }
    }
}

/** The display-orientation SEI packed for diagnostics, or -1 when none was seen. */
inline int64_t PackedDisplayOrientation(const VideoStreamInspection& inspection) {
    if (!inspection.displayOrientation) { return -1; }
    return (inspection.orientationCancel ? 1 : 0) | ((inspection.horFlip ? 1 : 0) << 1) |
        ((inspection.verFlip ? 1 : 0) << 2) | (static_cast<int64_t>(inspection.rotation) << 3);
}

} // namespace Render
