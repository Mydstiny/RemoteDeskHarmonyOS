#ifndef REMOTEDESK_MOONLIGHT_PRODUCT_RUNTIME_H
#define REMOTEDESK_MOONLIGHT_PRODUCT_RUNTIME_H

#include "moonlight/bridge/MoonlightNativeBridge.h"

#include <memory>

namespace remotedesk::moonlight {

// Creates the product-owned Moonlight control-plane runtime. The returned
// port owns only Moonlight state and has no dependency on another protocol's
// session, transport, renderer, queue, or persistence model.
std::shared_ptr<MoonlightNativeRuntimePort>
createMoonlightProductRuntimePort() noexcept;

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_PRODUCT_RUNTIME_H
