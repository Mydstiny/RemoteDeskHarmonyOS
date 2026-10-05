// Glue between the vendored MS-RDPEWA channel (C), libfido2 custom I/O and the session broker.
#include "rdp_security_key_provider.h"
#include "rdp_security_key_broker.h"
#include "rdpewa/remotedesk_rdpewa.h"

#include <winpr/synch.h>
#include <winpr/handle.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>

namespace {
constexpr const char* kPathPrefix = "remotedesk-usb:";

std::mutex g_eventMutex;
std::map<const void*, HANDLE> g_cancelEvents;
std::once_flag g_fidoInit;

struct IoHandle {
    std::shared_ptr<RdpSecurityKey::Broker> broker;
};

void* IoOpen(const char* path) {
    if (path == nullptr || std::strncmp(path, kPathPrefix, std::strlen(kPathPrefix)) != 0) return nullptr;
    char* end = nullptr;
    const unsigned long long sessionId = std::strtoull(path + std::strlen(kPathPrefix), &end, 10);
    if (end == nullptr || *end != '\0' || sessionId == 0) return nullptr;
    auto broker = RdpSecurityKey::ForSession(sessionId);
    if (!broker || broker->Closed()) return nullptr;
    return new IoHandle{broker};
}

void IoClose(void* handle) { delete static_cast<IoHandle*>(handle); }

int IoRead(void* handle, unsigned char* bytes, size_t length, int timeoutMs) {
    auto* io = static_cast<IoHandle*>(handle);
    if (io == nullptr || bytes == nullptr || length != 64) return -1;
    std::array<uint8_t, 64> report{};
    if (!io->broker->ReadReport(report, timeoutMs)) return -1;
    std::copy(report.begin(), report.end(), bytes);
    return 64;
}

int IoWrite(void* handle, const unsigned char* bytes, size_t length) {
    auto* io = static_cast<IoHandle*>(handle);
    // libfido2 prefixes the unnumbered report ID; USBManager only ever sends the 64-byte FIDO report.
    if (io == nullptr || bytes == nullptr || length != 65 || bytes[0] != 0) return -1;
    std::array<uint8_t, 64> report{};
    std::copy_n(bytes + 1, report.size(), report.begin());
    return io->broker->WriteReport(report) ? 65 : -1;
}

void CopyLabel(const std::string& value, char* out, size_t length) {
    if (out == nullptr || length == 0) return;
    const size_t count = std::min(value.size(), length - 1);
    std::memcpy(out, value.data(), count);
    out[count] = '\0';
}
} // namespace

namespace RdpSecurityKey {

bool AttachContext(void* context, uint64_t sessionId) {
    HANDLE event = CreateEventA(nullptr, TRUE, FALSE, nullptr);
    if (event == nullptr) return false;
    auto broker = Attach(context, sessionId);
    if (!broker) {
        CloseHandle(event);
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(g_eventMutex);
        auto& slot = g_cancelEvents[context];
        if (slot != nullptr) CloseHandle(slot);
        slot = event;
    }
    broker->OnCancelChanged([event](bool cancelled) {
        if (cancelled) SetEvent(event);
        else ResetEvent(event);
    });
    return true;
}

void CloseContext(void* context) { Close(context); }

void DetachContext(void* context) {
    // An I/O handle may still hold the broker; stop it from touching the event before the event is closed.
    const auto broker = ForContext(context);
    Detach(context);
    if (broker) broker->OnCancelChanged(nullptr);
    HANDLE event = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_eventMutex);
        const auto found = g_cancelEvents.find(context);
        if (found == g_cancelEvents.end()) return;
        event = found->second;
        g_cancelEvents.erase(found);
    }
    if (event != nullptr) CloseHandle(event);
}

} // namespace RdpSecurityKey

extern "C" {

BOOL remotedesk_rdpewa_begin(rdpContext* context) {
    const auto broker = RdpSecurityKey::ForContext(context);
    return broker && broker->Begin() ? TRUE : FALSE;
}

BOOL remotedesk_rdpewa_confirm(rdpContext* context, const char* rpId, RemoteDeskRdpewaOperation operation) {
    const auto broker = RdpSecurityKey::ForContext(context);
    return broker && broker->Confirm(rpId != nullptr ? rpId : "", static_cast<uint32_t>(operation)) ? TRUE : FALSE;
}

fido_dev_t* remotedesk_rdpewa_open(rdpContext* context, BOOL interactive, char* product, size_t productLen) {
    const auto broker = RdpSecurityKey::ForContext(context);
    if (!broker || broker->Closed()) return nullptr;
    std::string name;
    if (!broker->Authorized(name) && (!interactive || !broker->Select(name))) return nullptr;
    // FIDO2 keys only; U2F-only keys are not offered to the remote session.
    std::call_once(g_fidoInit, []() { fido_init(FIDO_DISABLE_U2F_FALLBACK); });
    static const fido_dev_io_t io = {IoOpen, IoClose, IoRead, IoWrite};
    const std::string path = std::string(kPathPrefix) + std::to_string(broker->SessionId());
    fido_dev_t* device = fido_dev_new();
    if (device == nullptr) return nullptr;
    if (fido_dev_set_io_functions(device, &io) != FIDO_OK || fido_dev_set_timeout(device, 60000) != FIDO_OK ||
        fido_dev_open(device, path.c_str()) != FIDO_OK) {
        fido_dev_free(&device);
        // A failed open usually means the key was removed: ask again next time.
        broker->Forget();
        return nullptr;
    }
    CopyLabel(name, product, productLen);
    return device;
}

BOOL remotedesk_rdpewa_authorized(rdpContext* context, char* product, size_t productLen) {
    const auto broker = RdpSecurityKey::ForContext(context);
    std::string name;
    if (!broker || !broker->Authorized(name)) return FALSE;
    CopyLabel(name, product, productLen);
    return TRUE;
}

char* remotedesk_rdpewa_pin(rdpContext* context, int retries) {
    const auto broker = RdpSecurityKey::ForContext(context);
    if (!broker) return nullptr;
    auto pin = broker->Pin(retries);
    if (!pin) return nullptr;
    char* copy = static_cast<char*>(std::calloc(pin->size() + 1, 1));
    if (copy != nullptr) std::memcpy(copy, pin->data(), pin->size());
    std::fill(pin->begin(), pin->end(), '\0');
    return copy;
}

void remotedesk_rdpewa_touch(rdpContext* context, BOOL waiting) {
    const auto broker = RdpSecurityKey::ForContext(context);
    if (broker) broker->Touch(waiting == TRUE);
}

HANDLE remotedesk_rdpewa_cancel_event(rdpContext* context) {
    std::lock_guard<std::mutex> lock(g_eventMutex);
    const auto found = g_cancelEvents.find(context);
    return found == g_cancelEvents.end() ? nullptr : found->second;
}

void remotedesk_rdpewa_cancel(rdpContext* context) {
    const auto broker = RdpSecurityKey::ForContext(context);
    if (broker) broker->Cancel();
}

} // extern "C"
