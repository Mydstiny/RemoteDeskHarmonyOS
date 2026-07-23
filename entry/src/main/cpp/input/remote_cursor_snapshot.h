/**
 * remote_cursor_snapshot.h — protocol-neutral remote cursor state
 */

#ifndef REMOTE_CURSOR_SNAPSHOT_H
#define REMOTE_CURSOR_SNAPSHOT_H

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

constexpr int kRemoteCursorMaxDimension = 384;
constexpr size_t kRemoteCursorMaxBytes =
    static_cast<size_t>(kRemoteCursorMaxDimension) * kRemoteCursorMaxDimension * 4U;

struct RemoteCursorSnapshot {
    uint64_t sessionId = 0;
    std::string protocol;
    uint64_t shapeId = 0;
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    int hotX = 0;
    int hotY = 0;
    /** True only for the RustDesk controller-side bootstrap shape. It is not a
     * protocol cursor and must not be rendered as an authoritative arrow. */
    bool fallbackShape = false;
    bool visible = false;
    /** False until a protocol callback has supplied a coordinate. The default
     * 0,0 storage value is not itself a remote cursor position. */
    bool positionAvailable = false;
    uint64_t shapeRevision = 0;
    uint64_t positionRevision = 0;
    /** Visibility is independent from coordinates so hide/show cannot look
     * like a position event to the ArkTS ownership policy. */
    uint64_t visibilityRevision = 0;
    std::vector<uint8_t> rgba;
};

class RemoteCursorStore {
public:
    void reset(uint64_t sessionId, const std::string& protocol);

    bool setShape(uint64_t shapeId, int width, int height, int hotX, int hotY,
                  const std::vector<uint8_t>& rgba);

    /** Restore a stable local arrow for protocol SetDefault callbacks. */
    bool setDefaultShape();

    /** Keep a temporary arrow visible until RustDesk supplies cursor data. */
    bool setFallbackShape();

    void setPosition(int x, int y);
    void setVisible(bool visible);
    RemoteCursorSnapshot snapshot(bool includePixels) const;

private:
    bool setShapeInternal(uint64_t shapeId, int width, int height, int hotX, int hotY,
                          const std::vector<uint8_t>& rgba, bool fallbackShape);

    mutable std::mutex mutex_;
    RemoteCursorSnapshot state_;
};

#endif // REMOTE_CURSOR_SNAPSHOT_H
