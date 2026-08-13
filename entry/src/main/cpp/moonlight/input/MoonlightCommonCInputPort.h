#ifndef REMOTEDESK_MOONLIGHT_COMMON_C_INPUT_PORT_H
#define REMOTEDESK_MOONLIGHT_COMMON_C_INPUT_PORT_H

#include "moonlight/input/MoonlightInputBridge.h"

#include <memory>

namespace remotedesk::moonlight {

// Sole product projection from mapper-owned commands to official common-c.
// It owns no queue or thread; common-c remains the transport owner.
std::shared_ptr<MoonlightInputPort> createMoonlightCommonCInputPort() noexcept;
bool moonlightCommonCDirectTouchAvailable() noexcept;

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_COMMON_C_INPUT_PORT_H
