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
    bool visible = false;
    uint64_t shapeRevision = 0;
    uint64_t positionRevision = 0;
    std::vector<uint8_t> rgba;
};

class RemoteCursorStore {
public:
    void reset(uint64_t sessionId, const std::string& protocol);

    bool setShape(uint64_t shapeId, int width, int height, int hotX, int hotY,
                  const std::vector<uint8_t>& rgba);

    void setPosition(int x, int y);
    void setVisible(bool visible);
    RemoteCursorSnapshot snapshot(bool includePixels) const;

private:
    mutable std::mutex mutex_;
    RemoteCursorSnapshot state_;
};

#endif // REMOTE_CURSOR_SNAPSHOT_H
