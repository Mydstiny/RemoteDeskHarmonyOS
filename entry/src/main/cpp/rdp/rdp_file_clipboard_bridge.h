#ifndef RDP_FILE_CLIPBOARD_BRIDGE_H
#define RDP_FILE_CLIPBOARD_BRIDGE_H

#include "rdp_file_clipboard_offer.h"
#include "rdp_clipboard_content.h"
#include "rdp_transfer_types.h"

#ifdef USE_REAL_FREERDP

#include <freerdp/client/client_cliprdr_file.h>
#include <freerdp/client/cliprdr.h>
#include <winpr/clipboard.h>

#include <chrono>
#include <map>
#include <mutex>
#include <vector>

class RdpFileClipboardBridge {
public:
    explicit RdpFileClipboardBridge(void* owner);
    ~RdpFileClipboardBridge();

    RdpFileClipboardBridge(const RdpFileClipboardBridge&) = delete;
    RdpFileClipboardBridge& operator=(const RdpFileClipboardBridge&) = delete;

    bool attach(CliprdrClientContext* channel);
    void detach();
    bool available() const;
    /** True only while a live cliprdr carrier is attached to this bridge. */
    bool attached() const;

    RdpFileClipboardOfferResult publishLocalFiles(const std::vector<std::string>& paths, bool* formatListAttempted = nullptr);
    void clearLocalFiles();
    /**
     * Withdraws the local file offer (new text replaced it). While the remote read the files within `activeWindow`
     * (a paste in progress) the file streams stay, so the paste completes; they are dropped with the next offer.
     */
    void releaseLocalFiles(std::chrono::milliseconds activeWindow);
    RdpFileOfferReadProgress readProgress() const;
    void setEnabled(bool enabled);
    UINT handleFileContentsRequest(CliprdrClientContext*, const CLIPRDR_FILE_CONTENTS_REQUEST*);
    UINT handleLock(CliprdrClientContext*, const CLIPRDR_LOCK_CLIPBOARD_DATA*);
    UINT handleUnlock(CliprdrClientContext*, const CLIPRDR_UNLOCK_CLIPBOARD_DATA*);
    UINT handleFileContentsResponse(CliprdrClientContext*, const CLIPRDR_FILE_CONTENTS_RESPONSE*);

    UINT updateServerCapabilities(const CLIPRDR_CAPABILITIES* capabilities);
    UINT notifyServerFormatList();
    UINT sendClientCapabilities();
    UINT sendCurrentFormatList(bool includeText);
    UINT32 registerContentFormat(const std::string& name);
    UINT sendContentFormatList(const RdpClipboardWireContent& content);
    bool isFileFormat(UINT32 formatId) const;
    UINT32 remoteFlags() const;
    UINT respondToFileFormatRequest(const CLIPRDR_FORMAT_DATA_REQUEST* request);

    static void* ownerFromContext(CliprdrClientContext* context);

private:
    bool initializeClipboardFormats();
    UINT sendCurrentFormatListLocked(bool includeText);
    void resetReadProgressLocked(uint64_t generation);
    bool readActiveLocked(std::chrono::milliseconds window) const;

    void* owner_ = nullptr;
    mutable std::mutex mutex_;
    wClipboard* clipboard_ = nullptr;
    CliprdrFileContext* fileContext_ = nullptr;
    CliprdrClientContext* channel_ = nullptr;
    UINT32 uriListFormatId_ = 0;
    UINT32 fileDescriptorFormatId_ = 0;
    RdpFileClipboardOffer offer_;
    bool enabled_ = true;
    pcCliprdrServerFileContentsRequest helperRequest_ = nullptr;
    pcCliprdrServerLockClipboardData helperLock_ = nullptr;
    pcCliprdrServerUnlockClipboardData helperUnlock_ = nullptr;
    pcCliprdrServerFileContentsResponse helperResponse_ = nullptr;
    uint64_t readGeneration_ = 0;
    std::map<UINT32, uint64_t> requestedEndByIndex_;
    /** Size of each offered regular file by list index (0 = unknown, e.g. inside an offered folder). */
    std::vector<uint64_t> offeredFileSizes_;
    uint32_t readRequests_ = 0;
    std::chrono::steady_clock::time_point lastReadRequest_ {};
};

#endif // USE_REAL_FREERDP

#endif // RDP_FILE_CLIPBOARD_BRIDGE_H
