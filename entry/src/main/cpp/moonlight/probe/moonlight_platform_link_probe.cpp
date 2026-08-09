// Compile/link-only probe for the API surface required by the Moonlight MVP.
//
// This executable is intentionally excluded from the product build. It proves
// that both OHOS ABIs expose the headers and link symbols before common-c is
// vendored. Runtime capability checks must execute inside the signed HAP,
// because a binary launched from /data/local/tmp does not inherit AppSpawn's
// platformsdk linker namespace.

#include <GameControllerKit/game_device.h>
#include <asset/asset_api.h>
#include <huks/native_huks_api.h>
#include <multimodalinput/oh_input_manager.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <network/netmanager/net_connection.h>
#include <ohaudio/native_audiostreambuilder.h>

#include <openssl/evp.h>
#include <openssl/ssl.h>

#include <pthread.h>
#include <sys/socket.h>
#include <time.h>

namespace {

template<typename Function>
bool IsLinked(Function* function)
{
    return function != nullptr;
}

} // namespace

int main()
{
    const bool platformSymbolsLinked =
        IsLinked(&OH_AVCodec_GetCapability) &&
        IsLinked(&OH_AudioStreamBuilder_Create) &&
        IsLinked(&OH_GameDevice_GetAllDeviceInfos) &&
        IsLinked(&OH_Huks_GenerateKeyItem) &&
        IsLinked(&OH_Asset_Add) &&
        IsLinked(&OH_Input_GetDeviceIds) &&
        IsLinked(&OH_NetConn_HasDefaultNet);

    const bool transportSymbolsLinked =
        IsLinked(&socket) && IsLinked(&clock_gettime) && IsLinked(&pthread_create);
    const bool cryptoSymbolsLinked =
        IsLinked(&TLS_method) && IsLinked(&SSL_CTX_new) && IsLinked(&EVP_sha256);

    return platformSymbolsLinked && transportSymbolsLinked && cryptoSymbolsLinked ? 0 : 1;
}
