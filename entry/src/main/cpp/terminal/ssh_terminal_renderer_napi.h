#ifndef SSH_TERMINAL_RENDERER_NAPI_H
#define SSH_TERMINAL_RENDERER_NAPI_H

#include <napi/native_api.h>

namespace SshTerminalRendererNapi {
    napi_value Init(napi_env env, napi_value exports);
}

#endif // SSH_TERMINAL_RENDERER_NAPI_H
