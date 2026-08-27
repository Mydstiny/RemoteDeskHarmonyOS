/**
 * vnc_cursor_protocol.cpp - bounded RFB Cursor pseudo-encoding decoder.
 */
#include "vnc_cursor_protocol.h"

#include <algorithm>
#include <array>
#include <limits>
#include <new>

namespace {

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
    const unsigned redEnd =
        static_cast<unsigned>(format.redShift) + valueBits(format.redMax);
    const unsigned greenEnd =
        static_cast<unsigned>(format.greenShift) + valueBits(format.greenMax);
    const unsigned blueEnd =
        static_cast<unsigned>(format.blueShift) + valueBits(format.blueMax);
    return redEnd <= format.bitsPerPixel && greenEnd <= format.bitsPerPixel &&
        blueEnd <= format.bitsPerPixel;
}

bool decodePixel(const VncRfbProtocol::PixelFormat& format,
                 const uint8_t* data, size_t available,
                 std::array<uint8_t, 4>& rgba) {
    if (!validPixelFormat(format) || data == nullptr) {
        return false;
    }
    const size_t pixelBytes = static_cast<size_t>(format.bitsPerPixel / 8);
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
    const uint32_t red = (value >> format.redShift) & format.redMax;
    const uint32_t green = (value >> format.greenShift) & format.greenMax;
    const uint32_t blue = (value >> format.blueShift) & format.blueMax;
    rgba[0] = static_cast<uint8_t>(red * 255U / format.redMax);
    rgba[1] = static_cast<uint8_t>(green * 255U / format.greenMax);
    rgba[2] = static_cast<uint8_t>(blue * 255U / format.blueMax);
    rgba[3] = 255;
    return true;
}

void writePixel(std::vector<uint8_t>& rgba, size_t pixelIndex,
                const std::array<uint8_t, 4>& pixel) {
    const size_t offset = pixelIndex * 4U;
    std::copy(pixel.begin(), pixel.end(),
              rgba.begin() + static_cast<std::ptrdiff_t>(offset));
}

} // namespace

namespace VncCursorProtocol {

bool decodePayload(const VncRfbProtocol::PixelFormat& format,
                   int hotX, int hotY, int width, int height,
                   const uint8_t* payload, size_t payloadSize,
                   DecodedCursor& cursor, std::string& error) {
    cursor = DecodedCursor{};
    if (width == 0 && height == 0) {
        if (payloadSize != 0) {
            error = "VNC hidden cursor payload must be empty";
            return false;
        }
        return true;
    }
    if (width <= 0 || height <= 0 || width > kMaxDimension ||
        height > kMaxDimension || hotX < 0 || hotY < 0 ||
        hotX >= width || hotY >= height || !validPixelFormat(format)) {
        error = "VNC cursor geometry or pixel format is invalid";
        return false;
    }
    const size_t bytesPerPixel = static_cast<size_t>(format.bitsPerPixel / 8);
    size_t pixelCount = 0;
    size_t pixelBytes = 0;
    const size_t maskRowBytes = (static_cast<size_t>(width) + 7U) / 8U;
    size_t maskBytes = 0;
    size_t expectedBytes = 0;
    if (!checkedMultiply(static_cast<size_t>(width), static_cast<size_t>(height), pixelCount) ||
        !checkedMultiply(pixelCount, bytesPerPixel, pixelBytes) ||
        !checkedMultiply(maskRowBytes, static_cast<size_t>(height), maskBytes) ||
        !checkedAdd(pixelBytes, maskBytes, expectedBytes) ||
        payload == nullptr || payloadSize != expectedBytes) {
        error = "VNC cursor payload length is invalid";
        return false;
    }
    try {
        cursor.rgba.assign(pixelCount * 4U, 0);
    } catch (const std::bad_alloc&) {
        error = "VNC cursor allocation failed";
        return false;
    }

    const uint8_t* mask = payload + pixelBytes;
    uint64_t shapeId = 1469598103934665603ULL;
    bool hasVisiblePixel = false;
    const auto mix = [&shapeId](uint8_t value) {
        shapeId ^= value;
        shapeId *= 1099511628211ULL;
    };
    for (int row = 0; row < height; ++row) {
        for (int column = 0; column < width; ++column) {
            const size_t index =
                static_cast<size_t>(row) * static_cast<size_t>(width) +
                static_cast<size_t>(column);
            std::array<uint8_t, 4> pixel = {0, 0, 0, 0};
            if (!decodePixel(format, payload + index * bytesPerPixel,
                             payloadSize - index * bytesPerPixel, pixel)) {
                cursor.rgba.clear();
                error = "VNC cursor pixel is invalid";
                return false;
            }
            const uint8_t maskByte =
                mask[static_cast<size_t>(row) * maskRowBytes +
                     static_cast<size_t>(column) / 8U];
            pixel[3] =
                ((maskByte >> (7U - static_cast<unsigned>(column % 8))) & 1U) != 0 ?
                255 : 0;
            hasVisiblePixel = hasVisiblePixel || pixel[3] != 0;
            writePixel(cursor.rgba, index, pixel);
            for (uint8_t channel : pixel) {
                mix(channel);
            }
        }
    }
    const uint32_t metadata[] = {
        static_cast<uint32_t>(width), static_cast<uint32_t>(height),
        static_cast<uint32_t>(hotX), static_cast<uint32_t>(hotY)
    };
    for (uint32_t value : metadata) {
        for (unsigned shift = 0; shift < 32; shift += 8) {
            mix(static_cast<uint8_t>((value >> shift) & 0xFFU));
        }
    }
    // Some servers use a non-zero cursor rectangle with an all-zero mask to
    // hide the remote cursor. Never install that transparent bitmap as the
    // native system pointer; the UI policy can retain its safe local fallback.
    cursor.visible = hasVisiblePixel;
    cursor.shapeId = shapeId;
    cursor.width = width;
    cursor.height = height;
    cursor.hotX = hotX;
    cursor.hotY = hotY;
    return true;
}

} // namespace VncCursorProtocol
