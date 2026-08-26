#ifndef REMOTEDESK_KEY_SEQUENCE_DISPATCH_H
#define REMOTEDESK_KEY_SEQUENCE_DISPATCH_H

#include <cstdint>
#include <vector>

/** Submit a chord as all key-down events followed by reverse-order key-up. */
template <typename Dispatch>
void DispatchKeySequence(const std::vector<uint32_t>& keyCodes, Dispatch&& dispatch) {
    for (uint32_t keyCode : keyCodes) {
        dispatch(keyCode, true);
    }
    for (auto it = keyCodes.rbegin(); it != keyCodes.rend(); ++it) {
        dispatch(*it, false);
    }
}

#endif // REMOTEDESK_KEY_SEQUENCE_DISPATCH_H
