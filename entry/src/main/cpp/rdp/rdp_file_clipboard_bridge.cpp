#include "rdp_file_clipboard_bridge.h"

#ifdef USE_REAL_FREERDP

#include <freerdp/settings_types.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/shell.h>

#include <algorithm>
#include <cstdlib>
#include <sys/stat.h>

namespace {

constexpr char kMimeUriList[] = "text/uri-list";
constexpr char kFileGroupDescriptorW[] = "FileGroupDescriptorW";

} // namespace

RdpFileClipboardBridge::RdpFileClipboardBridge(void* owner) : owner_(owner) {
    clipboard_ = ClipboardCreate();
    fileContext_ = cliprdr_file_context_new(owner_);
    if (!clipboard_ || !fileContext_ || !initializeClipboardFormats()) {
        if (fileContext_) {
            cliprdr_file_context_free(fileContext_);
            fileContext_ = nullptr;
        }
        if (clipboard_) {
            ClipboardDestroy(clipboard_);
            clipboard_ = nullptr;
        }
    }
}

RdpFileClipboardBridge::~RdpFileClipboardBridge() {
    detach();
    if (fileContext_) {
        cliprdr_file_context_free(fileContext_);
    }
    if (clipboard_) {
        ClipboardDestroy(clipboard_);
    }
}

bool RdpFileClipboardBridge::initializeClipboardFormats() {
    uriListFormatId_ = ClipboardRegisterFormat(clipboard_, kMimeUriList);
    fileDescriptorFormatId_ = ClipboardRegisterFormat(clipboard_, kFileGroupDescriptorW);
    return uriListFormatId_ != 0 && fileDescriptorFormatId_ != 0 &&
           cliprdr_file_context_set_locally_available(fileContext_, TRUE) == TRUE;
}

bool RdpFileClipboardBridge::attach(CliprdrClientContext* channel) {
    if (!channel || !available()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (channel_ == channel) {
        return true;
    }
    if (channel_) {
        cliprdr_file_context_uninit(fileContext_, channel_);
        channel_->custom = nullptr;
    }
    channel_ = channel;
    if (cliprdr_file_context_init(fileContext_, channel_) != TRUE) {
        channel_->custom = nullptr;
        channel_ = nullptr;
        return false;
    }
    helperRequest_ = channel_->ServerFileContentsRequest;
    helperLock_ = channel_->ServerLockClipboardData;
    helperUnlock_ = channel_->ServerUnlockClipboardData;
    helperResponse_ = channel_->ServerFileContentsResponse;
    enabled_ = true;
    cliprdr_file_context_remote_set_flags(fileContext_, 0);
    return true;
}

void RdpFileClipboardBridge::detach() {
    std::lock_guard<std::mutex> lock(mutex_);
    offer_.clear();
    if (fileContext_) {
        cliprdr_file_context_clear(fileContext_);
    }
    if (clipboard_) {
        ClipboardEmpty(clipboard_);
    }
    if (channel_) {
        cliprdr_file_context_uninit(fileContext_, channel_);
        channel_->custom = nullptr;
        channel_ = nullptr;
    }
}

bool RdpFileClipboardBridge::available() const {
    return clipboard_ && fileContext_ && uriListFormatId_ != 0 &&
           fileDescriptorFormatId_ != 0;
}

bool RdpFileClipboardBridge::attached() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return channel_ != nullptr;
}

RdpFileClipboardOfferResult RdpFileClipboardBridge::publishLocalFiles(
    const std::vector<std::string>& paths, bool* formatListAttempted) {
    if (formatListAttempted) *formatListAttempted = false;
    std::lock_guard<std::mutex> lock(mutex_);
    if (!enabled_) return RdpFileClipboardOfferResult::InvalidPath;
    const auto result = offer_.replace(paths);
    if (result != RdpFileClipboardOfferResult::Ready) {
        return result;
    }
    resetReadProgressLocked(offer_.snapshot().generation);
    // A request may reach past a file's end; reads of plain files are counted only up to their size.
    for (const auto& path : paths) {
        struct stat info {};
        offeredFileSizes_.push_back(stat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode) ?
            static_cast<uint64_t>(info.st_size) : 0);
        if (offeredFileSizes_.back() == 0 || !S_ISREG(info.st_mode)) {
            // A folder expands into many list entries: no index-to-size mapping is reliable then.
            offeredFileSizes_.clear();
            break;
        }
    }
    if (!channel_) {
        offer_.clear();
        return RdpFileClipboardOfferResult::InvalidPath;
    }
    const auto snapshot = offer_.snapshot();
    // WinPR's URI-list converter decodes percent escapes, while FreeRDP's
    // local-stream helper takes literal filesystem paths and does not decode.
    std::string helperPaths;
    for (const auto& path : snapshot.paths) { helperPaths.append(path); helperPaths.push_back('\n'); }
    ClipboardEmpty(clipboard_);
    if (ClipboardSetData(clipboard_, uriListFormatId_, snapshot.uriList.data(),
                         static_cast<UINT32>(snapshot.uriList.size())) != TRUE ||
        cliprdr_file_context_update_client_data(fileContext_, helperPaths.data(),
                                                helperPaths.size()) != TRUE) {
        offer_.clear();
        cliprdr_file_context_clear(fileContext_);
        ClipboardEmpty(clipboard_);
        return RdpFileClipboardOfferResult::InvalidPath;
    }
    if (formatListAttempted) *formatListAttempted = true;
    if (sendCurrentFormatListLocked(false) != CHANNEL_RC_OK) {
        offer_.clear();
        cliprdr_file_context_clear(fileContext_);
        ClipboardEmpty(clipboard_);
        return RdpFileClipboardOfferResult::InvalidPath;
    }
    return RdpFileClipboardOfferResult::Ready;
}

void RdpFileClipboardBridge::resetReadProgressLocked(uint64_t generation) {
    readGeneration_ = generation;
    requestedEndByIndex_.clear();
    offeredFileSizes_.clear();
    readRequests_ = 0;
    lastReadRequest_ = {};
}

bool RdpFileClipboardBridge::readActiveLocked(std::chrono::milliseconds window) const {
    return readRequests_ > 0 && std::chrono::steady_clock::now() - lastReadRequest_ < window;
}

void RdpFileClipboardBridge::releaseLocalFiles(std::chrono::milliseconds activeWindow) {
    std::lock_guard<std::mutex> lock(mutex_);
    offer_.clear();
    if (clipboard_) ClipboardEmpty(clipboard_);
    if (fileContext_ && !readActiveLocked(activeWindow)) cliprdr_file_context_clear(fileContext_);
}

RdpFileOfferReadProgress RdpFileClipboardBridge::readProgress() const {
    std::lock_guard<std::mutex> lock(mutex_);
    RdpFileOfferReadProgress progress;
    progress.generation = readGeneration_;
    progress.requests = readRequests_;
    for (const auto& entry : requestedEndByIndex_) progress.requestedBytes += entry.second;
    if (readRequests_ > 0) {
        progress.lastRequestAgoMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - lastReadRequest_).count();
    }
    return progress;
}

void RdpFileClipboardBridge::clearLocalFiles() {
    std::lock_guard<std::mutex> lock(mutex_);
    offer_.clear();
    if (fileContext_) {
        cliprdr_file_context_clear(fileContext_);
    }
    if (clipboard_) {
        ClipboardEmpty(clipboard_);
    }
}

// This mutex is the admission/drain barrier for every helper callback. Disable
// waits for admitted synchronous I/O to finish, then destroys even locked streams.
// Keeping only cliprdr_file_context_clear() would retain locked source handles.
void RdpFileClipboardBridge::setEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(mutex_);
    enabled_ = enabled;
    if (enabled) return;
    offer_.clear();
    if (clipboard_) ClipboardEmpty(clipboard_);
    if (!fileContext_) return;
    cliprdr_file_context_clear(fileContext_);
    if (!channel_) return;
    const auto request = channel_->ServerFileContentsRequest;
    const auto lockCallback = channel_->ServerLockClipboardData;
    const auto unlockCallback = channel_->ServerUnlockClipboardData;
    const auto response = channel_->ServerFileContentsResponse;
    cliprdr_file_context_uninit(fileContext_, channel_);
    cliprdr_file_context_init(fileContext_, channel_);
    // init installs FreeRDP helpers; retain our owner-lease wrappers instead.
    channel_->ServerFileContentsRequest = request;
    channel_->ServerLockClipboardData = lockCallback;
    channel_->ServerUnlockClipboardData = unlockCallback;
    channel_->ServerFileContentsResponse = response;
}

UINT RdpFileClipboardBridge::handleFileContentsRequest(
    CliprdrClientContext* context, const CLIPRDR_FILE_CONTENTS_REQUEST* request) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (context != channel_ || !request) return ERROR_INVALID_PARAMETER;
    if (!enabled_ || !helperRequest_) {
        if (!context->ClientFileContentsResponse) return ERROR_INVALID_PARAMETER;
        CLIPRDR_FILE_CONTENTS_RESPONSE response {};
        response.common.msgType = CB_FILECONTENTS_RESPONSE;
        response.common.msgFlags = CB_RESPONSE_FAIL;
        response.streamId = request->streamId;
        return context->ClientFileContentsResponse(context, &response);
    }
    // Progress of the remote's paste: the furthest byte it asked for in each offered file.
    ++readRequests_;
    lastReadRequest_ = std::chrono::steady_clock::now();
    if ((request->dwFlags & FILECONTENTS_RANGE) != 0) {
        const uint64_t end = ((static_cast<uint64_t>(request->nPositionHigh) << 32) | request->nPositionLow) +
            request->cbRequested;
        const uint64_t bounded = request->listIndex < offeredFileSizes_.size() ?
            std::min(end, offeredFileSizes_[request->listIndex]) : end;
        uint64_t& furthest = requestedEndByIndex_[request->listIndex];
        if (bounded > furthest) furthest = bounded;
    }
    return helperRequest_(context, request);
}

UINT RdpFileClipboardBridge::handleLock(
    CliprdrClientContext* context, const CLIPRDR_LOCK_CLIPBOARD_DATA* request) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (context != channel_ || !request) return ERROR_INVALID_PARAMETER;
    return enabled_ && helperLock_ ? helperLock_(context, request) : CHANNEL_RC_OK;
}

UINT RdpFileClipboardBridge::handleUnlock(
    CliprdrClientContext* context, const CLIPRDR_UNLOCK_CLIPBOARD_DATA* request) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (context != channel_ || !request) return ERROR_INVALID_PARAMETER;
    return enabled_ && helperUnlock_ ? helperUnlock_(context, request) : CHANNEL_RC_OK;
}

UINT RdpFileClipboardBridge::handleFileContentsResponse(
    CliprdrClientContext* context, const CLIPRDR_FILE_CONTENTS_RESPONSE* response) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (context != channel_ || !response) return ERROR_INVALID_PARAMETER;
    return enabled_ && helperResponse_ ? helperResponse_(context, response) : CHANNEL_RC_OK;
}

UINT RdpFileClipboardBridge::updateServerCapabilities(
    const CLIPRDR_CAPABILITIES* capabilities) {
    if (!capabilities || !capabilities->capabilitySets || !available()) {
        return ERROR_INVALID_PARAMETER;
    }
    UINT32 flags = 0;
    const BYTE* cursor = reinterpret_cast<const BYTE*>(capabilities->capabilitySets);
    for (UINT32 index = 0; index < capabilities->cCapabilitiesSets; ++index) {
        const auto* capability = reinterpret_cast<const CLIPRDR_CAPABILITY_SET*>(cursor);
        if (capability->capabilitySetLength < sizeof(CLIPRDR_CAPABILITY_SET)) {
            return ERROR_INVALID_DATA;
        }
        if (capability->capabilitySetType == CB_CAPSTYPE_GENERAL &&
            capability->capabilitySetLength >= sizeof(CLIPRDR_GENERAL_CAPABILITY_SET)) {
            const auto* general =
                reinterpret_cast<const CLIPRDR_GENERAL_CAPABILITY_SET*>(capability);
            flags = general->generalFlags;
        }
        cursor += capability->capabilitySetLength;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    return cliprdr_file_context_remote_set_flags(fileContext_, flags) == TRUE ?
        CHANNEL_RC_OK : ERROR_INTERNAL_ERROR;
}

UINT RdpFileClipboardBridge::sendClientCapabilities() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!channel_ || !channel_->ClientCapabilities) {
        return ERROR_INVALID_PARAMETER;
    }
    CLIPRDR_GENERAL_CAPABILITY_SET general {
        CB_CAPSTYPE_GENERAL,
        sizeof(CLIPRDR_GENERAL_CAPABILITY_SET),
        CB_CAPS_VERSION_2,
        CB_USE_LONG_FORMAT_NAMES | cliprdr_file_context_current_flags(fileContext_)
    };
    CLIPRDR_CAPABILITIES capabilities {};
    capabilities.common.msgType = CB_CLIP_CAPS;
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets =
        reinterpret_cast<CLIPRDR_CAPABILITY_SET*>(&general);
    return channel_->ClientCapabilities(channel_, &capabilities);
}

UINT RdpFileClipboardBridge::notifyServerFormatList() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!channel_) {
        return ERROR_INVALID_PARAMETER;
    }
    return cliprdr_file_context_notify_new_server_format_list(fileContext_);
}

UINT32 RdpFileClipboardBridge::registerContentFormat(const std::string& name) {
    std::lock_guard<std::mutex> lock(mutex_);
    return clipboard_ ? ClipboardRegisterFormat(clipboard_, name.c_str()) : 0;
}
UINT RdpFileClipboardBridge::sendContentFormatList(const RdpClipboardWireContent& content) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!enabled_ || !channel_ || !channel_->ClientFormatList || content.items.empty()) return ERROR_INVALID_PARAMETER;
    std::vector<CLIPRDR_FORMAT> formats;
    for (const auto& item:content.items) {
        if (!item.formatId) return ERROR_INVALID_DATA;
        formats.push_back({item.formatId,item.name.empty()?nullptr:const_cast<char*>(item.name.c_str())});
    }
    const UINT notified=cliprdr_file_context_notify_new_client_format_list(fileContext_);
    if (notified!=CHANNEL_RC_OK) return notified;
    CLIPRDR_FORMAT_LIST list {}; list.common.msgType=CB_FORMAT_LIST;
    list.numFormats=static_cast<UINT32>(formats.size()); list.formats=formats.data();
    return channel_->ClientFormatList(channel_,&list);
}

UINT RdpFileClipboardBridge::sendCurrentFormatList(bool includeText) {
    std::lock_guard<std::mutex> lock(mutex_);
    return sendCurrentFormatListLocked(includeText);
}

UINT RdpFileClipboardBridge::sendCurrentFormatListLocked(bool includeText) {
    if (!enabled_ || !channel_ || !channel_->ClientFormatList) {
        return ERROR_INVALID_PARAMETER;
    }
    std::vector<CLIPRDR_FORMAT> formats;
    if (includeText) {
        formats.push_back({CF_UNICODETEXT, nullptr});
    }
    const auto snapshot = offer_.snapshot();
    const bool fileStreamingNegotiated =
        (cliprdr_file_context_current_flags(fileContext_) & CB_STREAM_FILECLIP_ENABLED) != 0;
    if (snapshot.ready() && fileStreamingNegotiated) {
        formats.push_back({fileDescriptorFormatId_, const_cast<char*>(kFileGroupDescriptorW)});
    }
    if (formats.empty()) {
        return ERROR_INVALID_DATA;
    }
    const UINT notifyResult = cliprdr_file_context_notify_new_client_format_list(fileContext_);
    if (notifyResult != CHANNEL_RC_OK) {
        return notifyResult;
    }
    CLIPRDR_FORMAT_LIST list {};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = static_cast<UINT32>(formats.size());
    list.formats = formats.data();
    return channel_->ClientFormatList(channel_, &list);
}

UINT32 RdpFileClipboardBridge::remoteFlags() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return fileContext_ ? cliprdr_file_context_remote_get_flags(fileContext_) : 0;
}

bool RdpFileClipboardBridge::isFileFormat(UINT32 formatId) const {
    return formatId != 0 && formatId == fileDescriptorFormatId_;
}

UINT RdpFileClipboardBridge::respondToFileFormatRequest(
    const CLIPRDR_FORMAT_DATA_REQUEST* request) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!enabled_ || !request || !channel_ || !channel_->ClientFormatDataResponse ||
        !isFileFormat(request->requestedFormatId) || !offer_.snapshot().ready()) {
        return ERROR_INVALID_PARAMETER;
    }
    UINT32 descriptorBytes = 0;
    auto* descriptors = static_cast<BYTE*>(
        ClipboardGetData(clipboard_, fileDescriptorFormatId_, &descriptorBytes));
    if (!descriptors || descriptorBytes == 0 ||
        descriptorBytes % sizeof(FILEDESCRIPTORW) != 0) {
        std::free(descriptors);
        return ERROR_INVALID_DATA;
    }
    BYTE* packed = nullptr;
    UINT32 packedSize = 0;
    const UINT serializeResult = cliprdr_serialize_file_list_ex(
        cliprdr_file_context_remote_get_flags(fileContext_),
        reinterpret_cast<const FILEDESCRIPTORW*>(descriptors),
        descriptorBytes / sizeof(FILEDESCRIPTORW), &packed, &packedSize);
    std::free(descriptors);
    if (serializeResult != CHANNEL_RC_OK || !packed || packedSize == 0) {
        std::free(packed);
        return serializeResult == CHANNEL_RC_OK ? ERROR_INVALID_DATA : serializeResult;
    }
    CLIPRDR_FORMAT_DATA_RESPONSE response {};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = packedSize;
    response.requestedFormatData = packed;
    const UINT result = channel_->ClientFormatDataResponse(channel_, &response);
    std::free(packed);
    return result;
}

void* RdpFileClipboardBridge::ownerFromContext(CliprdrClientContext* context) {
    if (!context || !context->custom) {
        return nullptr;
    }
    return cliprdr_file_context_get_context(
        static_cast<CliprdrFileContext*>(context->custom));
}

#endif // USE_REAL_FREERDP
