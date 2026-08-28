/**
 * vnc_rfb_protocol.cpp - pure RFB/UltraVNC wire-contract helpers.
 */
#include "vnc_rfb_protocol.h"
#include "vnc_cursor_protocol.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <thread>
#include <utility>
#include <zlib.h>

namespace {

bool isPrintableTargetByte(uint8_t value) {
    return value >= 0x21 && value <= 0x7e;
}

bool decodeNextUtf8Codepoint(const std::string& text, size_t& offset,
                             uint32_t& codepoint) {
    if (offset >= text.size()) {
        return false;
    }
    const uint8_t first = static_cast<uint8_t>(text[offset]);
    if (first <= 0x7F) {
        codepoint = first;
        ++offset;
        return true;
    }

    size_t continuationCount = 0;
    uint32_t value = 0;
    uint32_t minimum = 0;
    if (first >= 0xC2 && first <= 0xDF) {
        continuationCount = 1;
        value = first & 0x1FU;
        minimum = 0x80;
    } else if (first >= 0xE0 && first <= 0xEF) {
        continuationCount = 2;
        value = first & 0x0FU;
        minimum = 0x800;
    } else if (first >= 0xF0 && first <= 0xF4) {
        continuationCount = 3;
        value = first & 0x07U;
        minimum = 0x10000;
    } else {
        return false;
    }
    if (continuationCount > text.size() - offset - 1U) {
        return false;
    }
    for (size_t index = 1; index <= continuationCount; ++index) {
        const uint8_t continuation = static_cast<uint8_t>(text[offset + index]);
        if ((continuation & 0xC0U) != 0x80U) {
            return false;
        }
        value = (value << 6U) | (continuation & 0x3FU);
    }
    if (value < minimum || value > 0x10FFFFU ||
        (value >= 0xD800U && value <= 0xDFFFU)) {
        return false;
    }
    offset += continuationCount + 1U;
    codepoint = value;
    return true;
}

bool codepointToKeysym(uint32_t codepoint, uint32_t& keysym) {
    switch (codepoint) {
        case 0x08: keysym = 0xFF08; return true; // BackSpace
        case 0x09: keysym = 0xFF09; return true; // Tab
        case 0x0A:
        case 0x0D: keysym = 0xFF0D; return true; // Return
        case 0x1B: keysym = 0xFF1B; return true; // Escape
        case 0x7F: keysym = 0xFFFF; return true; // Delete
        default: break;
    }
    if (codepoint < 0x20U) {
        return false;
    }
    if (codepoint <= 0xFFU) {
        keysym = codepoint;
        return true;
    }
    if (codepoint <= 0x10FFFFU) {
        keysym = 0x01000000U | codepoint;
        return true;
    }
    return false;
}

void appendKeyEvent(std::vector<uint8_t>& packet, uint32_t keysym, bool pressed) {
    packet.push_back(4);
    packet.push_back(static_cast<uint8_t>(pressed ? 1 : 0));
    packet.push_back(0);
    packet.push_back(0);
    packet.push_back(static_cast<uint8_t>(keysym >> 24));
    packet.push_back(static_cast<uint8_t>(keysym >> 16));
    packet.push_back(static_cast<uint8_t>(keysym >> 8));
    packet.push_back(static_cast<uint8_t>(keysym));
}

bool checkedMultiply(size_t left, size_t right, size_t& result) {
    if (left != 0 && right > std::numeric_limits<size_t>::max() / left) {
        return false;
    }
    result = left * right;
    return true;
}

bool checkedAdd(size_t left, size_t right, size_t& result) {
    if (right > std::numeric_limits<size_t>::max() - left) {
        return false;
    }
    result = left + right;
    return true;
}

unsigned valueBits(uint16_t value) {
    unsigned bits = 0;
    while (value != 0) {
        ++bits;
        value = static_cast<uint16_t>(value >> 1);
    }
    return bits;
}

bool validPixelFormat(const VncRfbProtocol::PixelFormat& format) {
    if (!format.trueColor ||
        (format.bitsPerPixel != 8 && format.bitsPerPixel != 16 &&
         format.bitsPerPixel != 32) ||
        format.redMax == 0 || format.greenMax == 0 || format.blueMax == 0) {
        return false;
    }
    const unsigned redEnd = static_cast<unsigned>(format.redShift) + valueBits(format.redMax);
    const unsigned greenEnd =
        static_cast<unsigned>(format.greenShift) + valueBits(format.greenMax);
    const unsigned blueEnd = static_cast<unsigned>(format.blueShift) + valueBits(format.blueMax);
    return redEnd <= format.bitsPerPixel && greenEnd <= format.bitsPerPixel &&
        blueEnd <= format.bitsPerPixel;
}

bool compactUsesHighBytes(const VncRfbProtocol::PixelFormat& format) {
    return format.bitsPerPixel == 32 && format.depth <= 24 &&
        format.redShift >= 8 && format.greenShift >= 8 && format.blueShift >= 8;
}

[[maybe_unused]] bool decodePixel(const VncRfbProtocol::PixelFormat& format, const uint8_t* data,
                 size_t available, bool compact, std::array<uint8_t, 4>& rgba) {
    if (!validPixelFormat(format) || data == nullptr) {
        return false;
    }
    const size_t pixelBytes = compact ? VncRfbProtocol::compactPixelBytes(format) :
        static_cast<size_t>(format.bitsPerPixel / 8);
    if (pixelBytes == 0 || available < pixelBytes) {
        return false;
    }
    uint32_t value = 0;
    if (format.bigEndian) {
        for (size_t index = 0; index < pixelBytes; ++index) {
            value = (value << 8) | data[index];
        }
    } else {
        for (size_t index = 0; index < pixelBytes; ++index) {
            value |= static_cast<uint32_t>(data[index]) << (index * 8);
        }
    }
    if (compact && pixelBytes == 3 && compactUsesHighBytes(format)) {
        value <<= 8;
    }
    const uint32_t red = (value >> format.redShift) & format.redMax;
    const uint32_t green = (value >> format.greenShift) & format.greenMax;
    const uint32_t blue = (value >> format.blueShift) & format.blueMax;
    rgba[0] = static_cast<uint8_t>(red * 255U / format.redMax);
    rgba[1] = static_cast<uint8_t>(green * 255U / format.greenMax);
    rgba[2] = static_cast<uint8_t>(blue * 255U / format.blueMax);
    rgba[3] = 255;
    return true;
}

class ByteReader {
public:
    ByteReader(const uint8_t* data, size_t size) : data_(data), size_(size) {}

    bool readU8(uint8_t& value) {
        if (offset_ >= size_ || data_ == nullptr) {
            return false;
        }
        value = data_[offset_++];
        return true;
    }

    bool readBytes(size_t count, const uint8_t*& value) {
        if (data_ == nullptr || count > size_ - offset_) {
            return false;
        }
        value = data_ + offset_;
        offset_ += count;
        return true;
    }

    size_t remaining() const {
        return size_ - offset_;
    }

    size_t position() const {
        return offset_;
    }

    bool skip(size_t count) {
        const uint8_t* ignored = nullptr;
        return readBytes(count, ignored);
    }

private:
    const uint8_t* data_ = nullptr;
    size_t size_ = 0;
    size_t offset_ = 0;
};

inline void writePixel(uint8_t*& destination, uint32_t pixel) {
    destination[0] = static_cast<uint8_t>(pixel & 0xFFU);
    destination[1] = static_cast<uint8_t>((pixel >> 8U) & 0xFFU);
    destination[2] = static_cast<uint8_t>((pixel >> 16U) & 0xFFU);
    destination[3] = static_cast<uint8_t>((pixel >> 24U) & 0xFFU);
    destination += 4U;
}

/**
 * Decode compact pixels without repeating a component division for every
 * pixel.  Large VNC desktops negotiate 16-bit 565 pixels; the old path did
 * three integer divisions and several iterator operations for each pixel,
 * which made a full-screen ZRLE rectangle spend seconds in decodeZrleTiles on
 * API 23 hardware.  A compact-pixel lookup table turns the common 16-bit path
 * into one table load plus four stores while keeping the wire parser unchanged.
 */
class CompactPixelDecoder {
public:
    explicit CompactPixelDecoder(const VncRfbProtocol::PixelFormat& format,
                                 bool blueFirst = false)
        : format_(format), bytes_(VncRfbProtocol::compactPixelBytes(format)),
          blueFirst_(blueFirst) {
        if (bytes_ <= 2) {
            const size_t tableSize = static_cast<size_t>(1U) << (bytes_ * 8U);
            try {
                packedPixels_.resize(tableSize);
            } catch (const std::bad_alloc&) {
                allocationFailed_ = true;
                return;
            }
            for (size_t value = 0; value < tableSize; ++value) {
                const uint32_t numericValue = static_cast<uint32_t>(value);
                const uint32_t red = (numericValue >> format_.redShift) & format_.redMax;
                const uint32_t green = (numericValue >> format_.greenShift) & format_.greenMax;
                const uint32_t blue = (numericValue >> format_.blueShift) & format_.blueMax;
                packedPixels_[value] = pack(red, green, blue);
            }
        }
    }

    bool ready() const {
        return !allocationFailed_;
    }

    bool readPacked(ByteReader& reader, uint32_t& pixel) const {
        const uint8_t* source = nullptr;
        if (bytes_ == 0 || !reader.readBytes(bytes_, source)) {
            return false;
        }
        if (bytes_ == 2) {
            const uint32_t value = format_.bigEndian ?
                (static_cast<uint32_t>(source[0]) << 8U) | source[1] :
                static_cast<uint32_t>(source[0]) |
                    (static_cast<uint32_t>(source[1]) << 8U);
            pixel = packedPixels_[value];
            return true;
        }
        uint32_t value = 0;
        if (format_.bigEndian) {
            for (size_t index = 0; index < bytes_; ++index) {
                value = (value << 8U) | source[index];
            }
        } else {
            for (size_t index = 0; index < bytes_; ++index) {
                value |= static_cast<uint32_t>(source[index]) << (index * 8U);
            }
        }
        if (bytes_ == 3 && compactUsesHighBytes(format_)) {
            value <<= 8U;
        }
        if (bytes_ <= 2) {
            pixel = packedPixels_[value];
            return true;
        }
        const uint32_t red = (value >> format_.redShift) & format_.redMax;
        const uint32_t green = (value >> format_.greenShift) & format_.greenMax;
        const uint32_t blue = (value >> format_.blueShift) & format_.blueMax;
        pixel = pack(red, green, blue);
        return true;
    }

private:
    static uint32_t scale(uint32_t value, uint16_t maximum) {
        return static_cast<uint32_t>(value * 255U / maximum);
    }

    uint32_t pack(uint32_t red, uint32_t green, uint32_t blue) const {
        const uint32_t r = scale(red, format_.redMax);
        const uint32_t g = scale(green, format_.greenMax);
        const uint32_t b = scale(blue, format_.blueMax);
        return blueFirst_ ? b | (g << 8U) | (r << 16U) | 0xFF000000U :
            r | (g << 8U) | (b << 16U) | 0xFF000000U;
    }

    const VncRfbProtocol::PixelFormat& format_;
    size_t bytes_ = 0;
    std::vector<uint32_t> packedPixels_;
    bool allocationFailed_ = false;
    bool blueFirst_ = false;
};

bool readRunLength(ByteReader& reader, size_t remainingPixels, size_t& runLength) {
    runLength = 1;
    while (true) {
        uint8_t value = 0;
        if (!reader.readU8(value) ||
            static_cast<size_t>(value) > remainingPixels - runLength) {
            return false;
        }
        runLength += value;
        if (value != 255) {
            return true;
        }
    }
}

bool decodeZrleTile(ByteReader& reader, const CompactPixelDecoder& decoder,
                    int tileWidth, int tileHeight, std::vector<uint8_t>& tile,
                    std::string& error) {
    const size_t pixelCount = static_cast<size_t>(tileWidth) * static_cast<size_t>(tileHeight);
    // Every supported subencoding writes every output pixel. Reuse the tile
    // allocation across the 64x64 tiles instead of clearing/reallocating it
    // for each tile in a large full-screen update.
    tile.resize(pixelCount * 4U);
    uint8_t subencoding = 0;
    if (!reader.readU8(subencoding)) {
        error = "VNC ZRLE tile is missing its subencoding";
        return false;
    }
    if ((subencoding >= 17 && subencoding <= 127) || subencoding == 129) {
        error = "VNC ZRLE tile uses an invalid or palette-reuse subencoding";
        return false;
    }

    if (subencoding == 0) {
        uint8_t* output = tile.data();
        for (size_t index = 0; index < pixelCount; ++index) {
            uint32_t pixel = 0;
            if (!decoder.readPacked(reader, pixel)) {
                error = "VNC ZRLE raw tile is truncated";
                return false;
            }
            writePixel(output, pixel);
        }
        return true;
    }

    if (subencoding == 1) {
        uint32_t pixel = 0;
        if (!decoder.readPacked(reader, pixel)) {
            error = "VNC ZRLE solid tile is truncated";
            return false;
        }
        uint8_t* output = tile.data();
        for (size_t index = 0; index < pixelCount; ++index) {
            writePixel(output, pixel);
        }
        return true;
    }

    if (subencoding >= 2 && subencoding <= 16) {
        const size_t paletteSize = subencoding;
        std::vector<uint32_t> palette(paletteSize);
        for (size_t index = 0; index < paletteSize; ++index) {
            if (!decoder.readPacked(reader, palette[index])) {
                error = "VNC ZRLE packed palette is truncated";
                return false;
            }
        }
        const unsigned bitsPerIndex = paletteSize == 2 ? 1U :
            (paletteSize <= 4 ? 2U : 4U);
        const size_t rowBytes =
            (static_cast<size_t>(tileWidth) * bitsPerIndex + 7U) / 8U;
        size_t outputIndex = 0;
        for (int row = 0; row < tileHeight; ++row) {
            const uint8_t* packed = nullptr;
            if (!reader.readBytes(rowBytes, packed)) {
                error = "VNC ZRLE packed palette indexes are truncated";
                return false;
            }
            uint8_t* output = tile.data() + outputIndex * 4U;
            for (int column = 0; column < tileWidth; ++column) {
                const size_t bitOffset = static_cast<size_t>(column) * bitsPerIndex;
                const unsigned shift = 8U - bitsPerIndex -
                    static_cast<unsigned>(bitOffset % 8U);
                const uint8_t mask = static_cast<uint8_t>((1U << bitsPerIndex) - 1U);
                const size_t paletteIndex =
                    static_cast<size_t>((packed[bitOffset / 8U] >> shift) & mask);
                if (paletteIndex >= palette.size()) {
                    error = "VNC ZRLE packed palette index is out of range";
                    return false;
                }
                writePixel(output, palette[paletteIndex]);
                ++outputIndex;
            }
        }
        return true;
    }

    if (subencoding == 128) {
        size_t outputIndex = 0;
        uint8_t* output = tile.data();
        while (outputIndex < pixelCount) {
            uint32_t pixel = 0;
            if (!decoder.readPacked(reader, pixel)) {
                error = "VNC ZRLE plain RLE pixel is truncated";
                return false;
            }
            size_t runLength = 0;
            if (!readRunLength(reader, pixelCount - outputIndex, runLength)) {
                error = "VNC ZRLE plain RLE length is invalid";
                return false;
            }
            for (size_t index = 0; index < runLength; ++index) {
                writePixel(output, pixel);
                ++outputIndex;
            }
        }
        return true;
    }

    const size_t paletteSize = static_cast<size_t>(subencoding - 128);
    if (paletteSize < 2 || paletteSize > 127) {
        error = "VNC ZRLE palette RLE size is invalid";
        return false;
    }
    std::vector<uint32_t> palette(paletteSize);
    for (size_t index = 0; index < paletteSize; ++index) {
        if (!decoder.readPacked(reader, palette[index])) {
            error = "VNC ZRLE palette RLE palette is truncated";
            return false;
        }
    }
    size_t outputIndex = 0;
    uint8_t* output = tile.data();
    while (outputIndex < pixelCount) {
        uint8_t encodedIndex = 0;
        if (!reader.readU8(encodedIndex)) {
            error = "VNC ZRLE palette RLE index is truncated";
            return false;
        }
        const size_t paletteIndex = encodedIndex & 0x7FU;
        if (paletteIndex >= palette.size()) {
            error = "VNC ZRLE palette RLE index is out of range";
            return false;
        }
        size_t runLength = 1;
        if ((encodedIndex & 0x80U) != 0 &&
            !readRunLength(reader, pixelCount - outputIndex, runLength)) {
            error = "VNC ZRLE palette RLE length is invalid";
            return false;
        }
        for (size_t index = 0; index < runLength; ++index) {
            writePixel(output, palette[paletteIndex]);
            ++outputIndex;
        }
    }
    return true;
}

struct ZrleTileJob {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    size_t offset = 0;
    size_t size = 0;
};

bool scanZrleTile(ByteReader& reader, size_t compactBytes,
                  int tileWidth, int tileHeight, std::string& error) {
    const size_t pixelCount = static_cast<size_t>(tileWidth) *
        static_cast<size_t>(tileHeight);
    uint8_t subencoding = 0;
    if (!reader.readU8(subencoding)) {
        error = "VNC ZRLE tile is missing its subencoding";
        return false;
    }
    if ((subencoding >= 17 && subencoding <= 127) || subencoding == 129) {
        error = "VNC ZRLE tile uses an invalid or palette-reuse subencoding";
        return false;
    }
    if (subencoding == 0) {
        size_t bytes = 0;
        if (!checkedMultiply(pixelCount, compactBytes, bytes) || !reader.skip(bytes)) {
            error = "VNC ZRLE raw tile is truncated";
            return false;
        }
        return true;
    }
    if (subencoding == 1) {
        if (!reader.skip(compactBytes)) {
            error = "VNC ZRLE solid tile is truncated";
            return false;
        }
        return true;
    }
    if (subencoding >= 2 && subencoding <= 16) {
        const size_t paletteSize = subencoding;
        size_t paletteBytes = 0;
        if (!checkedMultiply(paletteSize, compactBytes, paletteBytes) ||
            !reader.skip(paletteBytes)) {
            error = "VNC ZRLE packed palette is truncated";
            return false;
        }
        const unsigned bitsPerIndex = paletteSize == 2 ? 1U :
            (paletteSize <= 4 ? 2U : 4U);
        const size_t rowBytes =
            (static_cast<size_t>(tileWidth) * bitsPerIndex + 7U) / 8U;
        size_t packedBytes = 0;
        if (!checkedMultiply(rowBytes, static_cast<size_t>(tileHeight), packedBytes) ||
            !reader.skip(packedBytes)) {
            error = "VNC ZRLE packed palette indexes are truncated";
            return false;
        }
        return true;
    }
    if (subencoding == 128) {
        size_t outputIndex = 0;
        while (outputIndex < pixelCount) {
            if (!reader.skip(compactBytes)) {
                error = "VNC ZRLE plain RLE pixel is truncated";
                return false;
            }
            size_t runLength = 0;
            if (!readRunLength(reader, pixelCount - outputIndex, runLength)) {
                error = "VNC ZRLE plain RLE length is invalid";
                return false;
            }
            outputIndex += runLength;
        }
        return true;
    }

    const size_t paletteSize = static_cast<size_t>(subencoding - 128);
    if (paletteSize < 2 || paletteSize > 127) {
        error = "VNC ZRLE palette RLE size is invalid";
        return false;
    }
    size_t paletteBytes = 0;
    if (!checkedMultiply(paletteSize, compactBytes, paletteBytes) ||
        !reader.skip(paletteBytes)) {
        error = "VNC ZRLE palette RLE palette is truncated";
        return false;
    }
    size_t outputIndex = 0;
    while (outputIndex < pixelCount) {
        uint8_t encodedIndex = 0;
        if (!reader.readU8(encodedIndex)) {
            error = "VNC ZRLE palette RLE index is truncated";
            return false;
        }
        if (static_cast<size_t>(encodedIndex & 0x7FU) >= paletteSize) {
            error = "VNC ZRLE palette RLE index is out of range";
            return false;
        }
        size_t runLength = 1;
        if ((encodedIndex & 0x80U) != 0 &&
            !readRunLength(reader, pixelCount - outputIndex, runLength)) {
            error = "VNC ZRLE palette RLE length is invalid";
            return false;
        }
        outputIndex += runLength;
    }
    return true;
}

bool buildZrleTileJobs(int width, int height, size_t compactBytes,
                       const uint8_t* data, size_t size,
                       std::vector<ZrleTileJob>& jobs, std::string& error) {
    ByteReader reader(data, size);
    try {
        const size_t columns = (static_cast<size_t>(width) + 63U) / 64U;
        const size_t rows = (static_cast<size_t>(height) + 63U) / 64U;
        size_t tileCount = 0;
        if (!checkedMultiply(columns, rows, tileCount)) {
            error = "VNC ZRLE tile count overflows";
            return false;
        }
        jobs.reserve(tileCount);
        for (int tileY = 0; tileY < height; tileY += 64) {
            const int tileHeight = std::min(64, height - tileY);
            for (int tileX = 0; tileX < width; tileX += 64) {
                const int tileWidth = std::min(64, width - tileX);
                const size_t start = reader.position();
                if (!scanZrleTile(reader, compactBytes, tileWidth, tileHeight, error)) {
                    return false;
                }
                jobs.push_back({tileX, tileY, tileWidth, tileHeight,
                                start, reader.position() - start});
            }
        }
    } catch (const std::bad_alloc&) {
        error = "VNC ZRLE tile index allocation failed";
        return false;
    }
    if (reader.remaining() != 0) {
        error = "VNC ZRLE rectangle has trailing decompressed data";
        return false;
    }
    return true;
}

bool decodeZrleTilesInto(const VncRfbProtocol::PixelFormat& format,
                         int width, int height, const uint8_t* data, size_t size,
                         uint8_t* destination, size_t destinationSize,
                         size_t destinationStride, bool blueFirst,
                         std::string& error) {
    if (width <= 0 || height <= 0 || data == nullptr || size == 0 ||
        destination == nullptr || !validPixelFormat(format)) {
        error = "VNC ZRLE rectangle input is invalid";
        return false;
    }
    const size_t compactBytes = VncRfbProtocol::compactPixelBytes(format);
    size_t rowBytes = 0;
    size_t lastRowOffset = 0;
    size_t requiredBytes = 0;
    if (compactBytes == 0 ||
        !checkedMultiply(static_cast<size_t>(width), 4U, rowBytes) ||
        destinationStride < rowBytes ||
        !checkedMultiply(static_cast<size_t>(height - 1), destinationStride,
                         lastRowOffset) ||
        !checkedAdd(lastRowOffset, rowBytes, requiredBytes) ||
        destinationSize < requiredBytes) {
        error = "VNC ZRLE destination is too small";
        return false;
    }

    std::vector<ZrleTileJob> jobs;
    if (!buildZrleTileJobs(width, height, compactBytes, data, size, jobs, error)) {
        return false;
    }
    CompactPixelDecoder decoder(format, blueFirst);
    if (!decoder.ready()) {
        error = "VNC ZRLE pixel lookup allocation failed";
        return false;
    }

    size_t pixelCount = 0;
    if (!checkedMultiply(static_cast<size_t>(width), static_cast<size_t>(height),
                         pixelCount)) {
        error = "VNC ZRLE rectangle size overflows";
        return false;
    }
    size_t workerCount = 1;
    if (pixelCount >= 256U * 1024U && jobs.size() >= 8U) {
        const unsigned hardwareWorkers = std::thread::hardware_concurrency();
        const size_t availableWorkers = hardwareWorkers == 0 ? 2U :
            static_cast<size_t>(hardwareWorkers);
        workerCount = std::min({static_cast<size_t>(4), availableWorkers, jobs.size()});
    }

    std::atomic<size_t> nextJob {0};
    std::atomic<bool> failed {false};
    std::mutex errorMutex;
    const auto fail = [&](const std::string& workerError) -> void {
        if (!failed.exchange(true, std::memory_order_acq_rel)) {
            std::lock_guard<std::mutex> lock(errorMutex);
            error = workerError;
        }
    };
    const auto worker = [&]() -> void {
        std::vector<uint8_t> tile;
        try {
            while (!failed.load(std::memory_order_acquire)) {
                const size_t index = nextJob.fetch_add(1, std::memory_order_relaxed);
                if (index >= jobs.size()) {
                    return;
                }
                const ZrleTileJob& job = jobs[index];
                ByteReader tileReader(data + job.offset, job.size);
                std::string tileError;
                if (!decodeZrleTile(tileReader, decoder, job.width, job.height,
                                    tile, tileError) || tileReader.remaining() != 0) {
                    fail(tileError.empty() ?
                        "VNC ZRLE tile decoder did not consume its bounded input" : tileError);
                    return;
                }
                const size_t copyBytes = static_cast<size_t>(job.width) * 4U;
                for (int row = 0; row < job.height; ++row) {
                    const size_t sourceOffset = static_cast<size_t>(row) * copyBytes;
                    const size_t destinationOffset =
                        static_cast<size_t>(job.y + row) * destinationStride +
                        static_cast<size_t>(job.x) * 4U;
                    std::memcpy(destination + destinationOffset,
                                tile.data() + sourceOffset, copyBytes);
                }
            }
        } catch (const std::bad_alloc&) {
            fail("VNC ZRLE tile decode allocation failed");
        } catch (const std::exception&) {
            fail("VNC ZRLE tile worker failed");
        }
    };

    std::vector<std::thread> workers;
    if (workerCount > 1) {
        try {
            workers.reserve(workerCount - 1U);
            for (size_t index = 1; index < workerCount; ++index) {
                workers.emplace_back(worker);
            }
        } catch (const std::exception&) {
            // Already-started workers and the caller thread can safely finish
            // the shared atomic work queue; a thread-creation failure only
            // reduces parallelism.
        }
    }
    worker();
    for (std::thread& decodeThread : workers) {
        if (decodeThread.joinable()) {
            decodeThread.join();
        }
    }
    return !failed.load(std::memory_order_acquire);
}

} // namespace

namespace VncRfbProtocol {

bool protocolBannerIsSupported(const uint8_t* data, size_t size) {
    if (data == nullptr || size != kProtocolVersionBytes ||
        std::memcmp(data, "RFB ", 4) != 0 || data[11] != '\n' ||
        data[4] != '0' || data[5] != '0' || data[6] != '3' || data[7] != '.') {
        return false;
    }
    for (size_t i = 8; i < 11; ++i) {
        if (data[i] < '0' || data[i] > '9') { return false; }
    }
    const int minor = (data[8] - '0') * 100 + (data[9] - '0') * 10 + (data[10] - '0');
    return minor >= 3;
}

} // namespace VncRfbProtocol

namespace VncRfbProtocol {

uint8_t clientInitSharedFlag() {
    return 1;
}

int normalizeRfbMinor(int advertisedMinor) {
    if (advertisedMinor == 7) return 7;
    if (advertisedMinor == 8) return 8;
    return 3;
}

bool keepsLocalCursorDuringBootstrap(int negotiatedMinor) {
    return negotiatedMinor <= 3;
}

bool securityResultExpected(int negotiatedMinor, uint8_t selectedSecurityType) {
    if (selectedSecurityType != 1) return true;
    return negotiatedMinor == 8;
}

std::vector<uint8_t> buildFramebufferUpdateRequest(bool incremental,
                                                   uint16_t width,
                                                   uint16_t height) {
    return {
        3,
        static_cast<uint8_t>(incremental ? 1 : 0),
        0,
        0,
        0,
        0,
        static_cast<uint8_t>(width >> 8),
        static_cast<uint8_t>(width),
        static_cast<uint8_t>(height >> 8),
        static_cast<uint8_t>(height),
    };
}

std::vector<uint8_t> buildPointerWheelBurst(int buttonMask, int x, int y,
                                            int delta, int framebufferWidth,
                                            int framebufferHeight) {
    if (delta == 0) {
        return {};
    }
    const int64_t magnitude = delta > 0 ? static_cast<int64_t>(delta) :
        -static_cast<int64_t>(delta);
    const int steps = static_cast<int>(std::min<int64_t>(kMaxWheelBurstSteps, magnitude));
    const int preservedButtons = buttonMask & 0x07;
    const int wheelBit = delta > 0 ? 8 : 16;
    const int maxX = std::max(0, framebufferWidth - 1);
    const int maxY = std::max(0, framebufferHeight - 1);
    const int clampedX = std::max(0, std::min(x, maxX));
    const int clampedY = std::max(0, std::min(y, maxY));
    std::vector<uint8_t> packets(static_cast<size_t>(steps) * 12U, 0);
    for (int index = 0; index < steps; ++index) {
        const size_t offset = static_cast<size_t>(index) * 12U;
        packets[offset] = 5;
        packets[offset + 1] = static_cast<uint8_t>(preservedButtons | wheelBit);
        packets[offset + 2] = static_cast<uint8_t>(clampedX >> 8);
        packets[offset + 3] = static_cast<uint8_t>(clampedX);
        packets[offset + 4] = static_cast<uint8_t>(clampedY >> 8);
        packets[offset + 5] = static_cast<uint8_t>(clampedY);
        packets[offset + 6] = 5;
        packets[offset + 7] = static_cast<uint8_t>(preservedButtons);
        packets[offset + 8] = static_cast<uint8_t>(clampedX >> 8);
        packets[offset + 9] = static_cast<uint8_t>(clampedX);
        packets[offset + 10] = static_cast<uint8_t>(clampedY >> 8);
        packets[offset + 11] = static_cast<uint8_t>(clampedY);
    }
    return packets;
}

int effectiveTrueColorDepth(const std::string& requestedDepth,
                            const std::string& qualityPreset,
                            uint64_t desktopPixels,
                            int negotiatedMinor) {
    int requested = 32;
    if (requestedDepth == "8") {
        requested = 8;
    } else if (requestedDepth == "16") {
        requested = 16;
    } else if (requestedDepth == "32" || qualityPreset == "quality") {
        requested = 32;
    // An explicit speed preset must materially reduce ZRLE work. Retina-sized
    // sessions also need the same reduction under balanced+auto: live traces
    // show RGB565 ZRLE inflate alone can exceed 300 ms under sustained load.
    // Explicit 16/32-bit choices and the quality preset still win above.
    } else if (qualityPreset == "speed" ||
               desktopPixels > 4ULL * 1024ULL * 1024ULL) {
        requested = 8;
    }
    // Apple Screen Sharing advertises RFB 3.3 but closes the socket immediately
    // after receiving RGB332 followed by the initial framebuffer request. RFB
    // offers no pixel-format capability probe, so keep legacy 3.3 peers on the
    // proven RGB565 path instead of making the session unusable.
    if (negotiatedMinor <= 3 && requested == 8) {
        return 16;
    }
    return requested;
}

std::vector<uint8_t> buildSetPixelFormat(int colorDepth) {
    if (colorDepth == 8) {
        return {
            0, 0, 0, 0,
            8, 8, 0, 1,
            0, 7, 0, 7, 0, 3,
            5, 2, 0,
            0, 0, 0,
        };
    }
    if (colorDepth == 16) {
        return {
            0, 0, 0, 0,
            16, 16, 0, 1,
            0, 31, 0, 63, 0, 31,
            11, 5, 0,
            0, 0, 0,
        };
    }
    return {
        0, 0, 0, 0,
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0,
    };
}

std::vector<uint8_t> buildSetEncodings(const std::string& preferredEncoding) {
    std::vector<int32_t> requested;
    if (preferredEncoding != "raw") {
        requested.push_back(kZrleEncoding);
    }
    requested.push_back(kCopyRectEncoding);
    requested.push_back(kRawEncoding);
    requested.push_back(VncCursorProtocol::kEncoding);
    requested.push_back(kDesktopSizeEncoding);
    requested.push_back(kLastRectEncoding);

    std::vector<uint8_t> packet;
    packet.reserve(4U + requested.size() * 4U);
    packet.push_back(2);
    packet.push_back(0);
    packet.push_back(static_cast<uint8_t>(requested.size() >> 8));
    packet.push_back(static_cast<uint8_t>(requested.size()));
    for (int32_t encoding : requested) {
        const uint32_t value = static_cast<uint32_t>(encoding);
        packet.push_back(static_cast<uint8_t>(value >> 24));
        packet.push_back(static_cast<uint8_t>(value >> 16));
        packet.push_back(static_cast<uint8_t>(value >> 8));
        packet.push_back(static_cast<uint8_t>(value));
    }
    return packet;
}

bool canSendTextInput(bool viewOnly, bool clipboardEnabled, bool connected) {
    (void)clipboardEnabled;
    return !viewOnly && connected;
}

bool buildTextKeyEvents(const std::string& text, std::vector<uint8_t>& packet,
                        std::string& error) {
    packet.clear();
    error.clear();
    if (text.empty()) {
        return true;
    }

    std::vector<uint8_t> candidate;
    try {
        candidate.reserve(std::min(
            text.size(), kMaxTextInputCodepoints) * static_cast<size_t>(16));
    } catch (const std::bad_alloc&) {
        error = "VNC text input allocation failed";
        return false;
    }

    size_t offset = 0;
    size_t codepointCount = 0;
    while (offset < text.size()) {
        if (++codepointCount > kMaxTextInputCodepoints) {
            error = "VNC text input exceeds the safe codepoint limit";
            return false;
        }
        uint32_t codepoint = 0;
        if (!decodeNextUtf8Codepoint(text, offset, codepoint)) {
            error = "VNC text input is not valid UTF-8";
            return false;
        }
        uint32_t keysym = 0;
        if (!codepointToKeysym(codepoint, keysym)) {
            error = "VNC text input contains an unsupported control character";
            return false;
        }
        try {
            appendKeyEvent(candidate, keysym, true);
            appendKeyEvent(candidate, keysym, false);
        } catch (const std::bad_alloc&) {
            error = "VNC text input allocation failed";
            return false;
        }
    }
    packet.swap(candidate);
    return true;
}

int normalizeFrameRateLimit(int frameRateLimit) {
    return frameRateLimit == 0 || frameRateLimit == 15 || frameRateLimit == 60 ?
        frameRateLimit : 30;
}

uint64_t framebufferRequestIntervalMs(int frameRateLimit) {
    const int normalized = normalizeFrameRateLimit(frameRateLimit);
    return normalized <= 0 ? 0 :
        static_cast<uint64_t>((1000 + normalized - 1) / normalized);
}

bool isUltraVncRepeaterBanner(const uint8_t* data, size_t size) {
    static constexpr char kBanner[] = "RFB 000.000\n";
    return data != nullptr && size == kProtocolVersionBytes &&
        std::memcmp(data, kBanner, kProtocolVersionBytes) == 0;
}

bool buildRepeaterTargetField(const std::string& target,
                              std::array<uint8_t, kUltraVncRepeaterFieldBytes>& field,
                              std::string& error) {
    field.fill(0);
    if (target.empty()) {
        error = "UltraVNC Repeater target ID is empty";
        return false;
    }
    const size_t prefixBytes = 3;
    if (target.size() > kUltraVncRepeaterFieldBytes - prefixBytes) {
        error = "UltraVNC Repeater target ID is too long";
        return false;
    }
    for (unsigned char value : target) {
        if (!isPrintableTargetByte(value)) {
            error = "UltraVNC Repeater target ID contains a non-printable character";
            return false;
        }
    }
    field[0] = 'I';
    field[1] = 'D';
    field[2] = ':';
    std::copy(target.begin(), target.end(), field.begin() + prefixBytes);
    return true;
}

bool parseRepeaterTargetField(const uint8_t* data, size_t size, std::string& target,
                              std::string& error) {
    target.clear();
    if (data == nullptr || size != kUltraVncRepeaterFieldBytes) {
        error = "UltraVNC Repeater display field must be exactly 250 bytes";
        return false;
    }
    size_t end = 0;
    while (end < size && data[end] != 0) {
        ++end;
    }
    for (size_t index = end; index < size; ++index) {
        if (data[index] != 0) {
            error = "UltraVNC Repeater display field has non-zero bytes after padding";
            return false;
        }
    }
    if (end < 3 || data[0] != 'I' || data[1] != 'D' || data[2] != ':') {
        error = "UltraVNC Repeater display field must start with ID:";
        return false;
    }
    if (end == 3) {
        error = "UltraVNC Repeater target ID is empty";
        return false;
    }
    for (size_t index = 3; index < end; ++index) {
        if (!isPrintableTargetByte(data[index])) {
            error = "UltraVNC Repeater target ID contains a non-printable character";
            return false;
        }
    }
    target.assign(reinterpret_cast<const char*>(data + 3), end - 3);
    return true;
}

size_t compactPixelBytes(const PixelFormat& format) {
    if (!validPixelFormat(format)) {
        return 0;
    }
    if (format.bitsPerPixel != 32 || format.depth > 24) {
        return static_cast<size_t>(format.bitsPerPixel / 8);
    }
    const unsigned redEnd = static_cast<unsigned>(format.redShift) + valueBits(format.redMax);
    const unsigned greenEnd =
        static_cast<unsigned>(format.greenShift) + valueBits(format.greenMax);
    const unsigned blueEnd = static_cast<unsigned>(format.blueShift) + valueBits(format.blueMax);
    const bool lowThree = redEnd <= 24 && greenEnd <= 24 && blueEnd <= 24;
    const bool highThree = format.redShift >= 8 && format.greenShift >= 8 &&
        format.blueShift >= 8 && redEnd <= 32 && greenEnd <= 32 && blueEnd <= 32;
    return lowThree || highThree ? 3U : 4U;
}

bool maxZrleDecodedBytes(int width, int height, const PixelFormat& format,
                         size_t& maxBytes) {
    maxBytes = 0;
    if (width <= 0 || height <= 0 || !validPixelFormat(format)) {
        return false;
    }
    size_t pixels = 0;
    if (!checkedMultiply(static_cast<size_t>(width), static_cast<size_t>(height), pixels)) {
        return false;
    }
    const size_t compactBytes = compactPixelBytes(format);
    size_t perPixelBytes = 0;
    size_t runBytes = 0;
    if (!checkedAdd(compactBytes, 1U, perPixelBytes) ||
        !checkedMultiply(pixels, perPixelBytes, runBytes)) {
        return false;
    }
    const size_t tileColumns = (static_cast<size_t>(width) + 63U) / 64U;
    const size_t tileRows = (static_cast<size_t>(height) + 63U) / 64U;
    size_t tileCount = 0;
    size_t paletteBytes = 0;
    size_t perTileBytes = 0;
    size_t overheadBytes = 0;
    if (!checkedMultiply(tileColumns, tileRows, tileCount) ||
        !checkedMultiply(127U, compactBytes, paletteBytes) ||
        !checkedAdd(1U, paletteBytes, perTileBytes) ||
        !checkedMultiply(tileCount, perTileBytes, overheadBytes) ||
        !checkedAdd(runBytes, overheadBytes, maxBytes)) {
        return false;
    }
    return true;
}

bool decodeZrleTiles(const PixelFormat& format, int width, int height,
                     const uint8_t* data, size_t size,
                     std::vector<uint8_t>& rgba, std::string& error) {
    rgba.clear();
    if (width <= 0 || height <= 0 || data == nullptr || size == 0 ||
        !validPixelFormat(format) || compactPixelBytes(format) == 0) {
        error = "VNC ZRLE rectangle input is invalid";
        return false;
    }
    size_t pixelCount = 0;
    size_t rgbaBytes = 0;
    if (!checkedMultiply(static_cast<size_t>(width), static_cast<size_t>(height), pixelCount) ||
        !checkedMultiply(pixelCount, 4U, rgbaBytes)) {
        error = "VNC ZRLE rectangle size overflows";
        return false;
    }
    try {
        rgba.assign(rgbaBytes, 0);
    } catch (const std::bad_alloc&) {
        error = "VNC ZRLE rectangle allocation failed";
        return false;
    }

    if (!decodeZrleTilesInto(format, width, height, data, size,
                             rgba.data(), rgba.size(),
                             static_cast<size_t>(width) * 4U, false, error)) {
        rgba.clear();
        return false;
    }
    return true;
}

bool decodeZrleTilesToBgra(const PixelFormat& format, int width, int height,
                           const uint8_t* data, size_t size,
                           uint8_t* destination, size_t destinationSize,
                           size_t destinationStride, std::string& error) {
    return decodeZrleTilesInto(format, width, height, data, size,
                               destination, destinationSize,
                               destinationStride, true, error);
}

struct ZrleInflater::Impl {
    z_stream stream {};
    bool initialized = false;

    ~Impl() {
        if (initialized) {
            inflateEnd(&stream);
        }
    }
};

ZrleInflater::ZrleInflater() : impl_(std::make_unique<Impl>()) {}

ZrleInflater::~ZrleInflater() = default;

bool ZrleInflater::inflateChunk(const uint8_t* compressed, size_t compressedSize,
                                size_t maxOutputBytes, std::vector<uint8_t>& output,
                                std::string& error) {
    output.clear();
    if (compressed == nullptr || compressedSize == 0 ||
        compressedSize > static_cast<size_t>(std::numeric_limits<uInt>::max()) ||
        maxOutputBytes == 0) {
        error = "VNC ZRLE compressed input is invalid";
        return false;
    }
    // RFC 6143 requires each rectangle to flush the connection-level stream
    // to a byte boundary. zlib's Z_SYNC_FLUSH marker is the interoperable RFB
    // representation and prevents a truncated rectangle from being mistaken
    // for a complete chunk merely because inflate consumed all available input.
    if (compressedSize < 4 ||
        compressed[compressedSize - 4] != 0 ||
        compressed[compressedSize - 3] != 0 ||
        compressed[compressedSize - 2] != 0xFF ||
        compressed[compressedSize - 1] != 0xFF) {
        error = "VNC ZRLE rectangle lacks the required zlib flush marker";
        return false;
    }
    if (!impl_->initialized) {
        if (inflateInit(&impl_->stream) != Z_OK) {
            error = "VNC ZRLE zlib initialization failed";
            return false;
        }
        impl_->initialized = true;
    }
    impl_->stream.next_in = const_cast<Bytef*>(
        reinterpret_cast<const Bytef*>(compressed));
    impl_->stream.avail_in = static_cast<uInt>(compressedSize);

    try {
        if (output.capacity() < maxOutputBytes) {
            output.reserve(maxOutputBytes);
        }
    } catch (const std::bad_alloc&) {
        error = "VNC ZRLE decompressed allocation failed";
        return false;
    }

    constexpr size_t kInflateChunkBytes = 64U * 1024U;
    std::array<uint8_t, kInflateChunkBytes> buffer = {0};
    while (true) {
        impl_->stream.next_out = reinterpret_cast<Bytef*>(buffer.data());
        impl_->stream.avail_out = static_cast<uInt>(buffer.size());
        const uInt beforeInput = impl_->stream.avail_in;
        const int result = inflate(&impl_->stream, Z_SYNC_FLUSH);
        const size_t produced = buffer.size() - impl_->stream.avail_out;
        if (produced > maxOutputBytes - output.size()) {
            output.clear();
            error = "VNC ZRLE decompressed output exceeds the safe limit";
            return false;
        }
        try {
            output.insert(output.end(), buffer.begin(),
                          buffer.begin() + static_cast<std::ptrdiff_t>(produced));
        } catch (const std::bad_alloc&) {
            output.clear();
            error = "VNC ZRLE decompressed allocation failed";
            return false;
        }
        if (result == Z_STREAM_END) {
            output.clear();
            error = "VNC ZRLE stream ended before the RFB connection";
            return false;
        }
        if (result != Z_OK && result != Z_BUF_ERROR) {
            output.clear();
            error = "VNC ZRLE compressed stream is malformed";
            return false;
        }
        const bool inputConsumed = impl_->stream.avail_in == 0;
        const bool outputRoom = impl_->stream.avail_out > 0;
        if (inputConsumed && (outputRoom || result == Z_BUF_ERROR)) {
            break;
        }
        if (beforeInput == impl_->stream.avail_in && produced == 0) {
            output.clear();
            error = "VNC ZRLE inflater made no progress";
            return false;
        }
        if (output.size() == maxOutputBytes && (!inputConsumed || !outputRoom)) {
            output.clear();
            error = "VNC ZRLE decompressed output reaches an unsafe boundary";
            return false;
        }
    }
    if (impl_->stream.avail_in != 0 || output.empty()) {
        output.clear();
        error = "VNC ZRLE compressed rectangle is truncated";
        return false;
    }
    return true;
}

} // namespace VncRfbProtocol
