#ifndef RDP_FILE_CLIPBOARD_BRIDGE_H
#define RDP_FILE_CLIPBOARD_BRIDGE_H

#include "rdp_file_clipboard_offer.h"

#ifdef USE_REAL_FREERDP

#include <freerdp/client/client_cliprdr_file.h>
#include <freerdp/client/cliprdr.h>
#include <winpr/clipboard.h>

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

    RdpFileClipboardOfferResult publishLocalFiles(const std::vector<std::string>& paths);
    void clearLocalFiles();

    UINT updateServerCapabilities(const CLIPRDR_CAPABILITIES* capabilities);
    UINT notifyServerFormatList();
    UINT sendClientCapabilities();
    UINT sendCurrentFormatList(bool includeText);
    bool isFileFormat(UINT32 formatId) const;
    UINT respondToFileFormatRequest(const CLIPRDR_FORMAT_DATA_REQUEST* request);

    static void* ownerFromContext(CliprdrClientContext* context);

private:
    bool initializeClipboardFormats();
    UINT sendCurrentFormatListLocked(bool includeText);

    void* owner_ = nullptr;
    mutable std::mutex mutex_;
    wClipboard* clipboard_ = nullptr;
    CliprdrFileContext* fileContext_ = nullptr;
    CliprdrClientContext* channel_ = nullptr;
    UINT32 uriListFormatId_ = 0;
    UINT32 fileDescriptorFormatId_ = 0;
    RdpFileClipboardOffer offer_;
};

#endif // USE_REAL_FREERDP

#endif // RDP_FILE_CLIPBOARD_BRIDGE_H
