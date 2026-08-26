#ifndef REMOTEDESK_MOONLIGHT_NAPI_H
#define REMOTEDESK_MOONLIGHT_NAPI_H

#include <napi/native_api.h>

namespace MoonlightNapi {

#if defined(__GNUC__)
__attribute__((visibility("hidden")))
#endif
napi_value Init(napi_env env, napi_value exports);

} // namespace MoonlightNapi

#endif // REMOTEDESK_MOONLIGHT_NAPI_H
