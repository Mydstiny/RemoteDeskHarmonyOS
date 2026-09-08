#ifndef RDP_TRANSFER_TYPES_H
#define RDP_TRANSFER_TYPES_H
#include <cstdint>
#include <string>
#include <vector>

struct RdpDriveStatus {
    uint32_t schema = 1;
    uint64_t generation = 0;
    uint32_t deviceId = 0;
    std::string phase = "unavailable";
    uint32_t serverStatus = 0;
    bool evidenceComplete = true;
    std::string diagnosticCode;
};
struct RdpReceivedFileFact {
    std::string relativePath;
    uint64_t writeGeneration = 0;
    uint64_t writtenBytes = 0;
    uint32_t activeHandles = 0;
    bool remoteClosed = false;
    bool uncertain = false;
};
struct RemoteClipboardFileEntry {
    uint32_t index = 0;
    std::string relativeName;
    bool directory = false;
    bool sizeKnown = false;
    uint64_t size = 0;
};
struct RemoteClipboardFileOffer {
    uint32_t schema = 1;
    uint64_t sequence = 0;
    std::string state = "unavailable";
    bool streamSupported = false;
    bool lockSupported = false;
    bool hugeFileSupported = false;
    uint64_t totalBytes = 0;
    bool totalKnown = false;
    std::vector<RemoteClipboardFileEntry> entries;
    std::string diagnosticCode;
};
struct RemoteClipboardArtifact {
    uint32_t index = 0;
    std::string relativeName;
    bool directory = false;
    uint64_t size = 0;
};
struct RemoteClipboardReceiveStatus {
    uint32_t schema = 1;
    uint64_t taskId = 0;
    uint64_t sequence = 0;
    std::string phase = "unavailable";
    uint64_t transferredBytes = 0;
    uint64_t totalBytes = 0;
    bool totalKnown = false;
    uint32_t currentIndex = 0;
    std::vector<RemoteClipboardArtifact> artifacts;
    std::string diagnosticCode;
};
#endif
