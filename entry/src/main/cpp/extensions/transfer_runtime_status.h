// Per-session transfer facts.  Values are intentionally free of paths and peer content.
#ifndef TRANSFER_RUNTIME_STATUS_H
#define TRANSFER_RUNTIME_STATUS_H

#include <cstdint>
#include <mutex>
#include <string>

enum class TransferRuntimeState { UNAVAILABLE, READY, TRANSFERRING, CONFIRMED, FAILED };

struct SessionTransferStatus {
    bool rdpDriveMounted = false;
    TransferRuntimeState rustdeskTransfer = TransferRuntimeState::UNAVAILABLE;
    uint64_t transferId = 0;
    uint64_t transferredBytes = 0;
    uint64_t totalBytes = 0;
    std::string diagnosticCode;
};

class TransferRuntimeStatus {
public:
    SessionTransferStatus snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return status_;
    }

    void markRdpDriveMounted() {
        std::lock_guard<std::mutex> lock(mutex_);
        status_.rdpDriveMounted = true;
        status_.diagnosticCode.clear();
    }

    void markRdpDriveUnavailable(const std::string& diagnosticCode) {
        std::lock_guard<std::mutex> lock(mutex_);
        status_.rdpDriveMounted = false;
        status_.diagnosticCode = diagnosticCode;
    }

    void markRustDeskProgress(uint64_t id, uint64_t transferred, uint64_t total) {
        std::lock_guard<std::mutex> lock(mutex_);
        status_.rustdeskTransfer = TransferRuntimeState::TRANSFERRING;
        status_.transferId = id;
        status_.transferredBytes = transferred;
        status_.totalBytes = total;
        status_.diagnosticCode.clear();
    }

    void markRustDeskConfirmed(uint64_t id, uint64_t total) {
        std::lock_guard<std::mutex> lock(mutex_);
        status_.rustdeskTransfer = TransferRuntimeState::CONFIRMED;
        status_.transferId = id;
        status_.transferredBytes = total;
        status_.totalBytes = total;
        status_.diagnosticCode.clear();
    }

    void markRustDeskFailed(uint64_t id, const std::string& diagnosticCode) {
        std::lock_guard<std::mutex> lock(mutex_);
        status_.rustdeskTransfer = TransferRuntimeState::FAILED;
        status_.transferId = id;
        status_.diagnosticCode = diagnosticCode;
    }

private:
    mutable std::mutex mutex_;
    SessionTransferStatus status_;
};

#endif
