#ifndef RDP_CLIPBOARD_FEATURES_H
#define RDP_CLIPBOARD_FEATURES_H
#ifdef USE_REAL_FREERDP
#include <freerdp/settings_types.h>

inline UINT32 rdpClipboardFeatureMask(bool enabled) {
    // FreeRDP filters FormatList before delivering it to our callback. Keep
    // remote file offers visible for source ordering; receiving their contents
    // still requires an explicit client request, which this mask never sends.
    return enabled ? CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_REMOTE_TO_LOCAL |
        CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES | CLIPRDR_FLAG_REMOTE_TO_LOCAL_FILES : 0;
}
#endif
#endif
